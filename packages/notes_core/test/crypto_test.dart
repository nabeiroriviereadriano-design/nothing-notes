import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

// ignore: implementation_imports
import 'package:notes_core/src/lan/channel.dart';
// ignore: implementation_imports
import 'package:notes_core/src/lan/speke.dart';
import 'package:test/test.dart';

bool _probablePrime(BigInt n, {int rounds = 24}) {
  if (n < BigInt.two) return false;
  if (n.isEven) return n == BigInt.two;
  var d = n - BigInt.one;
  var s = 0;
  while (d.isEven) {
    d >>= 1;
    s++;
  }
  final rnd = Random(42);
  for (var i = 0; i < rounds; i++) {
    final a = BigInt.from(rnd.nextInt(1 << 30) + 2);
    var x = a.modPow(d, n);
    if (x == BigInt.one || x == n - BigInt.one) continue;
    var witness = true;
    for (var r = 1; r < s; r++) {
      x = x.modPow(BigInt.two, n);
      if (x == n - BigInt.one) {
        witness = false;
        break;
      }
    }
    if (witness) return false;
  }
  return true;
}

Future<(Wire, Wire, ServerSocket)> _wirePair() async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final accepted = Completer<Socket>();
  server.listen(accepted.complete);
  final client = await Socket.connect(InternetAddress.loopbackIPv4, server.port);
  return (Wire(client), Wire(await accepted.future), server);
}

void main() {
  group('Échange de clés (SPEKE)', () {
    test('groupe RFC 3526 : p et (p−1)/2 sont premiers (nombre premier sûr)', () {
      expect(modpP.bitLength, 2048);
      expect(_probablePrime(modpP), isTrue);
      expect(_probablePrime((modpP - BigInt.one) >> 1), isTrue);
    });

    test('même secret : même clé de session des deux côtés', () {
      final a = SpekeSide(utf8.encode('483920')), b = SpekeSide(utf8.encode('483920'));
      expect(a.shared(b.publicHex), b.shared(a.publicHex));
      final ka = deriveKeys(a.shared(b.publicHex), 't'), kb = deriveKeys(b.shared(a.publicHex), 't');
      expect(ka.clientToServer, kb.clientToServer);
      expect(ka.pairKey, kb.pairKey);
      expect(ka.clientToServer, isNot(ka.serverToClient));
    });

    test('secret différent : clés différentes (un code faux est détecté)', () {
      final a = SpekeSide(utf8.encode('483920')), b = SpekeSide(utf8.encode('483921'));
      expect(a.shared(b.publicHex), isNot(b.shared(a.publicHex)));
    });

    test('chaque session a des clés nouvelles (clés éphémères)', () {
      final key = List<int>.filled(32, 3);
      final s1 = SpekeSide(key).shared(SpekeSide(key).publicHex);
      final s2 = SpekeSide(key).shared(SpekeSide(key).publicHex);
      expect(s1, isNot(s2));
    });

    test('valeurs publiques piégées refusées (0, 1, p−1, hors bornes, texte)', () {
      final a = SpekeSide(utf8.encode('123456'));
      for (final bad in ['0', '1', (modpP - BigInt.one).toRadixString(16), modpP.toRadixString(16), 'zz', null, 42]) {
        expect(() => a.shared(bad), throwsA(isA<HandshakeError>()), reason: '$bad');
      }
    });

    test('codes à 6 chiffres', () {
      final codes = List.generate(200, (_) => newPairingCode());
      expect(codes.every((c) => RegExp(r'^\d{6}$').hasMatch(c)), isTrue);
      expect(codes.toSet().length, greaterThan(190));
    });
  });

  group('Canal chiffré', () {
    test('trames reconstituées quel que soit le découpage TCP', () {
      final r = FrameReader();
      final frames = [utf8.encode('bonjour'), <int>[], List<int>.generate(70000, (i) => i % 251)];
      final bytes = <int>[];
      for (final f in frames) {
        bytes.addAll([(f.length >> 24) & 255, (f.length >> 16) & 255, (f.length >> 8) & 255, f.length & 255, ...f]);
      }
      final out = <List<int>>[];
      for (var i = 0; i < bytes.length; i += 7) {
        out.addAll(r.add(bytes.sublist(i, min(i + 7, bytes.length))));
      }
      expect(out.length, 3);
      expect(out[0], frames[0]);
      expect(out[1], isEmpty);
      expect(out[2], frames[2]);
    });

    test('trame trop grande refusée', () {
      final r = FrameReader(maxFrame: 10);
      expect(() => r.add([0, 0, 0, 11]), throwsA(isA<ChannelClosed>()));
    });

    test('aller-retour chiffré, ordre conservé', () async {
      final (a, b, server) = await _wirePair();
      final k1 = List<int>.filled(32, 1), k2 = List<int>.filled(32, 2);
      final ca = SecureChannel(a, sendKey: k1, receiveKey: k2);
      final cb = SecureChannel(b, sendKey: k2, receiveKey: k1);
      for (var i = 0; i < 20; i++) {
        unawaited(ca.send(utf8.encode('message $i')));
      }
      for (var i = 0; i < 20; i++) {
        expect(utf8.decode(await cb.receive()), 'message $i');
      }
      await cb.send(utf8.encode('réponse'));
      expect(utf8.decode(await ca.receive()), 'réponse');
      await ca.close();
      await cb.close();
      await server.close();
    });

    test('mauvaise clé : trame refusée et connexion fermée', () async {
      final (a, b, server) = await _wirePair();
      final ca = SecureChannel(a, sendKey: List.filled(32, 1), receiveKey: List.filled(32, 2));
      final cb = SecureChannel(b, sendKey: List.filled(32, 2), receiveKey: List.filled(32, 9));
      await ca.send(utf8.encode('secret'));
      await expectLater(cb.receive(), throwsA(isA<ChannelClosed>()));
      await ca.close();
      await server.close();
    });

    test('trame modifiée en route : refusée', () async {
      final (a, b, server) = await _wirePair();
      final key = List<int>.filled(32, 5);
      final cb = SecureChannel(b, sendKey: List.filled(32, 6), receiveKey: key);
      // Chiffrement légitime, puis un octet modifié avant l'envoi.
      final (x, y, server2) = await _wirePair();
      final sender = SecureChannel(x, sendKey: key, receiveKey: List.filled(32, 6));
      await sender.send(utf8.encode('virement de 10 €'));
      final frame = await y.read();
      frame[3] ^= 1;
      a.send(frame);
      await expectLater(cb.receive(), throwsA(isA<ChannelClosed>()));
      for (final w in [a, x, y]) {
        await w.close();
      }
      await server.close();
      await server2.close();
    });

    test('trame rejouée : refusée', () async {
      final (a, b, server) = await _wirePair();
      final key = List<int>.filled(32, 5);
      final cb = SecureChannel(b, sendKey: List.filled(32, 6), receiveKey: key);
      final (x, y, server2) = await _wirePair();
      final sender = SecureChannel(x, sendKey: key, receiveKey: List.filled(32, 6));
      await sender.send(utf8.encode('une fois'));
      final frame = await y.read();
      a.send(frame);
      a.send(Uint8List.fromList(frame));
      expect(utf8.decode(await cb.receive()), 'une fois');
      await expectLater(cb.receive(), throwsA(isA<ChannelClosed>()));
      for (final w in [a, x, y]) {
        await w.close();
      }
      await server.close();
      await server2.close();
    });

    test('requêtes, réponses, erreurs et fichiers binaires', () async {
      final (a, b, server) = await _wirePair();
      final k1 = List<int>.filled(32, 1), k2 = List<int>.filled(32, 2);
      final ra = RpcPeer(SecureChannel(a, sendKey: k1, receiveKey: k2));
      final rb = RpcPeer(SecureChannel(b, sendKey: k2, receiveKey: k1));
      rb.handlers['add'] = (p, _) => RpcReply({'sum': (p['a'] as int) + (p['b'] as int)});
      rb.handlers['echo'] = (_, payload) => RpcReply({'n': payload?.length ?? 0}, payload);
      rb.handlers['fail'] = (_, __) => throw RpcError('nope', 'refusé');
      ra.start();
      rb.start();
      expect((await ra.call('add', {'a': 2, 'b': 40})).result['sum'], 42);
      final blob = Uint8List.fromList(List.generate(300000, (i) => i % 256));
      final echo = await ra.call('echo', const {}, blob);
      expect(echo.result['n'], blob.length);
      expect(echo.payload, blob);
      await expectLater(ra.call('fail'), throwsA(isA<RpcError>().having((e) => e.code, 'code', 'nope')));
      await expectLater(ra.call('inconnue'), throwsA(isA<RpcError>()));
      await ra.close();
      await rb.close();
      await server.close();
    });
  });
}
