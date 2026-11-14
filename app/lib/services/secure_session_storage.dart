import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:supabase_flutter/supabase_flutter.dart';

/// Stockage chiffré de la session (jetons d'accès) sur l'appareil.
///
/// Une clé aléatoire de 256 bits est conservée dans le coffre du système
/// (Android Keystore / protection des données Windows) via
/// flutter_secure_storage. La session elle-même est chiffrée avec cette clé
/// (HMAC-SHA256 en mode compteur + étiquette d'authentification) dans un
/// fichier : on évite ainsi la limite de taille du Gestionnaire
/// d'identifiants Windows.
class SecureSessionStorage extends LocalStorage {
  SecureSessionStorage(this.dir);

  final Directory dir;
  static const _keyName = 'nothing_notes_session_key_v1';
  static const _secure = FlutterSecureStorage(aOptions: AndroidOptions(encryptedSharedPreferences: true));

  File get _file => File(p.join(dir.path, 'session.bin'));
  Uint8List? _key;

  @override
  Future<void> initialize() async {
    try {
      final stored = await _secure.read(key: _keyName);
      if (stored != null) {
        _key = base64Decode(stored);
      } else {
        final rnd = Random.secure();
        _key = Uint8List.fromList(List.generate(32, (_) => rnd.nextInt(256)));
        await _secure.write(key: _keyName, value: base64Encode(_key!));
        if (await _file.exists()) await _file.delete(); // ancienne session illisible
      }
    } catch (_) {
      _key = null;
    }
  }

  Uint8List _stream(Uint8List nonce, int length) {
    final out = BytesBuilder();
    var counter = 0;
    final mac = Hmac(sha256, _key!);
    while (out.length < length) {
      final block = mac.convert([...nonce, ...[(counter >> 24) & 255, (counter >> 16) & 255, (counter >> 8) & 255, counter & 255]]);
      out.add(block.bytes);
      counter++;
    }
    return Uint8List.sublistView(out.toBytes(), 0, length);
  }

  List<int> _tag(Uint8List nonce, Uint8List ct) => Hmac(sha256, _key!).convert([...utf8.encode('tag'), ...nonce, ...ct]).bytes;

  @override
  Future<bool> hasAccessToken() async => (await accessToken()) != null;

  @override
  Future<String?> accessToken() async {
    if (_key == null) return null;
    try {
      if (!await _file.exists()) return null;
      final all = await _file.readAsBytes();
      if (all.length < 16 + 32) return null;
      final nonce = Uint8List.sublistView(all, 0, 16);
      final ct = Uint8List.sublistView(all, 16, all.length - 32);
      final tag = all.sublist(all.length - 32);
      final expected = _tag(nonce, ct);
      var diff = 0;
      for (var i = 0; i < 32; i++) {
        diff |= expected[i] ^ tag[i];
      }
      if (diff != 0) return null;
      final ks = _stream(nonce, ct.length);
      final plain = Uint8List(ct.length);
      for (var i = 0; i < ct.length; i++) {
        plain[i] = ct[i] ^ ks[i];
      }
      return utf8.decode(plain);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> persistSession(String persistSessionString) async {
    if (_key == null) return;
    final rnd = Random.secure();
    final nonce = Uint8List.fromList(List.generate(16, (_) => rnd.nextInt(256)));
    final plain = utf8.encode(persistSessionString);
    final ks = _stream(nonce, plain.length);
    final ct = Uint8List(plain.length);
    for (var i = 0; i < plain.length; i++) {
      ct[i] = plain[i] ^ ks[i];
    }
    final tmp = File('${_file.path}.tmp');
    await tmp.writeAsBytes([...nonce, ...ct, ..._tag(nonce, ct)], flush: true);
    await tmp.rename(_file.path);
  }

  @override
  Future<void> removePersistedSession() async {
    try {
      if (await _file.exists()) await _file.delete();
    } catch (_) {}
  }
}
