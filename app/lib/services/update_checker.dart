import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../state/app_controller.dart';

/// Fichier publié avec une version (APK, installateur…).
class ReleaseAsset {
  ReleaseAsset({required this.name, required this.url, required this.size, this.sha256});
  final String name;
  final String url;
  final int size;

  /// Empreinte publiée par GitHub (« digest »), si disponible.
  final String? sha256;

  factory ReleaseAsset.fromJson(Map<String, dynamic> j) {
    final digest = (j['digest'] ?? '').toString();
    return ReleaseAsset(
      name: (j['name'] ?? '').toString(),
      url: (j['browser_download_url'] ?? '').toString(),
      size: (j['size'] as num?)?.toInt() ?? 0,
      sha256: digest.startsWith('sha256:') ? digest.substring(7).toLowerCase() : null,
    );
  }
}

class UpdateInfo {
  UpdateInfo(this.version, this.url, this.newer, {this.notes = '', this.assets = const []});
  final String version;
  final String url;
  final bool newer;
  final String notes;
  final List<ReleaseAsset> assets;

  String get cleanVersion => version.replaceAll(RegExp(r'^[vV]'), '');

  /// Fichier à installer sur cette plateforme (null : mise à jour manuelle).
  ReleaseAsset? assetFor(String platform) {
    bool ok(ReleaseAsset a) => switch (platform) {
          'android' => a.name.toLowerCase().endsWith('.apk'),
          'windows' => RegExp(r'^NothingNotes-Setup-.*\.exe$', caseSensitive: false).hasMatch(a.name),
          _ => false,
        };
    for (final a in assets) {
      if (ok(a) && a.url.startsWith('https://github.com/$kGithubRepo/releases/download/')) return a;
    }
    return null;
  }

  factory UpdateInfo.fromRelease(Map<String, dynamic> body, String localVersion) {
    final tag = (body['tag_name'] ?? '').toString();
    return UpdateInfo(
      tag,
      (body['html_url'] ?? 'https://github.com/$kGithubRepo/releases').toString(),
      isNewer(tag, localVersion),
      notes: (body['body'] ?? '').toString(),
      assets: ((body['assets'] as List?) ?? const [])
          .whereType<Map>()
          .map((a) => ReleaseAsset.fromJson(Map<String, dynamic>.from(a)))
          .toList(),
    );
  }
}

List<int> _parse(String v) =>
    v.replaceAll(RegExp(r'^[vV]'), '').split(RegExp(r'[.+-]')).take(3).map((e) => int.tryParse(e) ?? 0).toList();

bool isNewer(String remote, String local) {
  final a = _parse(remote), b = _parse(local);
  for (var i = 0; i < 3; i++) {
    final x = i < a.length ? a[i] : 0, y = i < b.length ? b[i] : 0;
    if (x != y) return x > y;
  }
  return false;
}

/// Nouveautés de la release, sans le tableau des téléchargements.
String releaseHighlights(String notes) {
  final i = notes.indexOf('## Nouveautés');
  final s = i >= 0 ? notes.substring(i + '## Nouveautés'.length) : notes;
  return s.trim();
}

/// Interroge la dernière version publiée sur GitHub (gratuit, sans compte).
/// Seule requête réseau de l'application vers Internet ; rien n'est envoyé.
Future<UpdateInfo> checkForUpdate() async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final req = await client.getUrl(Uri.parse('https://api.github.com/repos/$kGithubRepo/releases/latest'));
    req.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
    req.headers.set(HttpHeaders.userAgentHeader, 'NothingNotes/$kAppVersion');
    final res = await req.close().timeout(const Duration(seconds: 20));
    if (res.statusCode == 404) {
      await res.drain<void>();
      return UpdateInfo(kAppVersion, 'https://github.com/$kGithubRepo/releases', false);
    }
    if (res.statusCode != 200) {
      await res.drain<void>();
      throw HttpException('HTTP ${res.statusCode}');
    }
    final body = jsonDecode(await res.transform(utf8.decoder).join()) as Map<String, dynamic>;
    return UpdateInfo.fromRelease(body, kAppVersion);
  } finally {
    client.close();
  }
}

class UpdateError implements Exception {
  UpdateError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Télécharge le fichier, vérifie sa taille et son empreinte SHA-256.
Future<File> downloadAsset(ReleaseAsset a, {void Function(int received, int total)? onProgress}) async {
  final dir = Directory(p.join((await getTemporaryDirectory()).path, 'updates'));
  if (await dir.exists()) {
    // Anciennes mises à jour téléchargées : inutiles.
    for (final f in dir.listSync().whereType<File>()) {
      try {
        f.deleteSync();
      } catch (_) {}
    }
  }
  await dir.create(recursive: true);
  final file = File(p.join(dir.path, p.basename(a.name)));
  final part = File('${file.path}.part');
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final req = await client.getUrl(Uri.parse(a.url));
    req.headers.set(HttpHeaders.userAgentHeader, 'NothingNotes/$kAppVersion');
    final res = await req.close();
    if (res.statusCode != 200) {
      await res.drain<void>();
      throw UpdateError('Téléchargement impossible (HTTP ${res.statusCode}).');
    }
    final total = a.size > 0 ? a.size : res.contentLength;
    final sink = part.openWrite();
    final hashOut = _DigestSink();
    final hasher = crypto.sha256.startChunkedConversion(hashOut);
    var received = 0;
    try {
      await for (final chunk in res.timeout(const Duration(seconds: 60))) {
        sink.add(chunk);
        hasher.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
    } finally {
      await sink.close();
      hasher.close();
    }
    if (a.size > 0 && received != a.size) {
      await part.delete();
      throw UpdateError('Fichier incomplet ($received / ${a.size} octets). Réessayez.');
    }
    final got = hashOut.value.toString();
    if (a.sha256 != null && got != a.sha256) {
      await part.delete();
      throw UpdateError('Le fichier téléchargé ne correspond pas à celui publié (empreinte SHA-256 différente). Installation annulée.');
    }
    if (await file.exists()) await file.delete();
    return await part.rename(file.path);
  } on TimeoutException {
    if (await part.exists()) await part.delete();
    throw UpdateError('Connexion trop lente ou interrompue. Réessayez.');
  } finally {
    client.close();
  }
}

class _DigestSink implements Sink<crypto.Digest> {
  late crypto.Digest value;
  @override
  void add(crypto.Digest data) => value = data;
  @override
  void close() {}
}

/// Windows : l'application est-elle installée (et non lancée depuis le .zip portable) ?
bool get windowsInstalled {
  if (!Platform.isWindows) return false;
  final dir = File(Platform.resolvedExecutable).parent.path;
  return File(p.join(dir, 'unins000.exe')).existsSync();
}

const _channel = MethodChannel('nothing_notes/share');

/// Lance l'installation. Windows : installateur silencieux qui relance
/// l'application ; l'appelant doit ensuite quitter. Android : installateur
/// du système (l'utilisateur confirme). Renvoie « permission » si Android
/// demande d'autoriser l'installation depuis Nothing Notes.
Future<String> launchInstaller(File f) async {
  if (Platform.isWindows) {
    await Process.start(
      f.path,
      ['/SILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/NOCANCEL', '/RELAUNCH=1'],
      mode: ProcessStartMode.detached,
    );
    return 'started';
  }
  if (Platform.isAndroid) {
    final r = await _channel.invokeMethod<String>('installApk', {'path': f.path});
    return r ?? 'started';
  }
  throw UpdateError('Plateforme non prise en charge.');
}
