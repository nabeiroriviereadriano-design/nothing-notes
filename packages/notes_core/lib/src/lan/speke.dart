import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Échange de clés authentifié par un secret partagé (SPEKE).
///
/// Sert à deux moments :
///  * à l'association : le secret est le code à 6 chiffres affiché sur un
///    appareil et saisi sur l'autre. Un tiers sur le réseau qui ne connaît
///    pas le code ne peut tester qu'UN code par tentative de connexion (et
///    l'appareil annule le code après 3 échecs) ; il ne peut pas le
///    retrouver hors ligne à partir des messages échangés ;
///  * à chaque connexion ensuite : le secret est la clé de 256 bits créée
///    lors de l'association. Chaque session a ses propres clés éphémères.
///
/// Groupe : MODP 2048 bits de la RFC 3526 (groupe 14), nombre premier sûr
/// p = 2q + 1. Le générateur est dérivé du secret : g = H(secret)² mod p.

/// Nombre premier du groupe 14 (RFC 3526). Sa primalité et celle de
/// (p − 1) / 2 sont vérifiées par les tests.
final BigInt modpP = BigInt.parse(
    'FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74'
    '020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F1437'
    '4FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED'
    'EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE45B3DC2007CB8A163BF05'
    '98DA48361C55D39A69163FA8FD24CF5F83655D23DCA3AD961C62F356208552BB'
    '9ED529077096966D670C354E4ABC9804F1746C08CA18217C32905E462E36CE3B'
    'E39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF695581718'
    '3995497CEA956AE515D2261898FA051015728E5A8AACAA68FFFFFFFFFFFFFFFF',
    radix: 16);

final BigInt _two = BigInt.two;

class HandshakeError implements Exception {
  HandshakeError(this.code, [this.message]);

  /// 'badsecret' (code ou clé incorrects), 'invalid', 'unknown', 'nopairing', 'version'.
  final String code;
  final String? message;
  @override
  String toString() => message ?? code;
}

final _rnd = Random.secure();

Uint8List randomBytes(int n) {
  final b = Uint8List(n);
  for (var i = 0; i < n; i++) {
    b[i] = _rnd.nextInt(256);
  }
  return b;
}

String hexOf(List<int> bytes) {
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

Uint8List bytesOfHex(String s) {
  if (s.length.isOdd) s = '0$s';
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

BigInt _toBig(List<int> bytes) => BigInt.parse(hexOf(bytes), radix: 16);

Uint8List _fixed(BigInt v, int length) => bytesOfHex(v.toRadixString(16).padLeft(length * 2, '0'));

/// Générateur du sous-groupe d'ordre q dérivé du secret.
BigInt generatorFor(List<int> secret) {
  final wide = BytesBuilder();
  for (var i = 0; i < 9; i++) {
    wide.add(sha256.convert([...utf8.encode('nothing-notes/speke/h2g/v1'), i, ...secret]).bytes);
  }
  final g = (_toBig(wide.toBytes()) % modpP).modPow(_two, modpP);
  if (g <= BigInt.one) throw HandshakeError('invalid', 'générateur invalide');
  return g;
}

/// Un côté de l'échange.
class SpekeSide {
  SpekeSide(List<int> secret) {
    final g = generatorFor(secret);
    _x = _toBig(randomBytes(32)) + _two;
    public = g.modPow(_x, modpP);
  }

  late final BigInt _x;
  late final BigInt public;

  String get publicHex => public.toRadixString(16);

  /// Secret commun, calculé à partir de la valeur publique de l'autre côté.
  Uint8List shared(Object? peerPublicHex) {
    final y = peerPublicHex is String ? BigInt.tryParse(peerPublicHex, radix: 16) : null;
    if (y == null || y < _two || y > modpP - _two) {
      throw HandshakeError('invalid', 'valeur publique invalide');
    }
    // L'exposant doublé ramène le résultat dans le sous-groupe d'ordre q.
    final k = y.modPow(_x << 1, modpP);
    if (k <= BigInt.one) throw HandshakeError('invalid', 'secret commun invalide');
    return _fixed(k, 256);
  }
}

/// Clés dérivées d'un échange réussi.
class SessionKeys {
  SessionKeys(this.clientToServer, this.serverToClient, this.confirm, this.pairKey);

  /// Chiffrement des trames dans chaque sens.
  final List<int> clientToServer;
  final List<int> serverToClient;

  /// Preuve mutuelle que les deux côtés ont obtenu le même secret.
  final List<int> confirm;

  /// Clé durable entre les deux appareils (utilisée seulement à l'association).
  final List<int> pairKey;
}

/// Dérivation de type HKDF (extraction puis expansion par HMAC-SHA-256).
SessionKeys deriveKeys(List<int> shared, String transcript) {
  final salt = sha256.convert(utf8.encode('nothing-notes/lan/v1|$transcript')).bytes;
  final master = Hmac(sha256, salt).convert(shared).bytes;
  List<int> expand(String label) => Hmac(sha256, master).convert(utf8.encode(label)).bytes;
  return SessionKeys(expand('c2s'), expand('s2c'), expand('confirm'), expand('pairkey'));
}

String confirmTag(List<int> confirmKey, String who, String transcript) =>
    hexOf(Hmac(sha256, confirmKey).convert(utf8.encode('$who|$transcript')).bytes);

/// Comparaison à temps constant.
bool sameTag(Object? a, String b) {
  if (a is! String || a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return diff == 0;
}

/// Code d'association à 6 chiffres.
String newPairingCode() => List.generate(6, (_) => _rnd.nextInt(10)).join();
