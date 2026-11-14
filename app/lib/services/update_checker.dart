import 'dart:convert';
import 'dart:io';

import '../state/app_controller.dart';

class UpdateInfo {
  UpdateInfo(this.version, this.url, this.newer);
  final String version;
  final String url;
  final bool newer;
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

/// Interroge la dernière version publiée sur GitHub (gratuit, sans compte).
Future<UpdateInfo> checkForUpdate() async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
  try {
    final req = await client.getUrl(Uri.parse('https://api.github.com/repos/$kGithubRepo/releases/latest'));
    req.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
    req.headers.set(HttpHeaders.userAgentHeader, 'NothingNotes/$kAppVersion');
    final res = await req.close();
    if (res.statusCode == 404) {
      return UpdateInfo(kAppVersion, 'https://github.com/$kGithubRepo/releases', false);
    }
    if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
    final body = jsonDecode(await res.transform(utf8.decoder).join()) as Map<String, dynamic>;
    final tag = (body['tag_name'] ?? '').toString();
    final url = (body['html_url'] ?? 'https://github.com/$kGithubRepo/releases').toString();
    return UpdateInfo(tag, url, isNewer(tag, kAppVersion));
  } finally {
    client.close();
  }
}
