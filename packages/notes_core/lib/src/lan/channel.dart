import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// La connexion est fermée (appareil parti, réseau coupé, trame invalide…).
class ChannelClosed implements Exception {
  ChannelClosed([this.reason = 'connexion fermée']);
  final String reason;
  @override
  String toString() => reason;
}

/// Reconstitue des trames `[longueur sur 4 octets][contenu]` à partir d'un
/// flux TCP découpé arbitrairement.
class FrameReader {
  FrameReader({this.maxFrame = 8 * 1024 * 1024});
  final int maxFrame;
  Uint8List _buf = Uint8List(0);

  List<Uint8List> add(List<int> data) {
    final joined = Uint8List(_buf.length + data.length)
      ..setRange(0, _buf.length, _buf)
      ..setRange(_buf.length, _buf.length + data.length, data);
    final out = <Uint8List>[];
    var off = 0;
    while (joined.length - off >= 4) {
      final n = ByteData.sublistView(joined, off, off + 4).getUint32(0);
      if (n > maxFrame) throw ChannelClosed('trame trop grande');
      if (joined.length - off - 4 < n) break;
      out.add(Uint8List.fromList(Uint8List.sublistView(joined, off + 4, off + 4 + n)));
      off += 4 + n;
    }
    _buf = off == 0 ? joined : Uint8List.fromList(Uint8List.sublistView(joined, off));
    return out;
  }
}

/// Connexion TCP découpée en trames.
class Wire {
  Wire(this.socket) {
    socket.done.then((_) {}, onError: (_) {});
    _sub = socket.listen(
      (data) {
        try {
          _frames.addAll(_reader.add(data));
        } catch (e) {
          _fail(e);
          return;
        }
        _wake();
      },
      onError: (Object e) => _fail(e),
      onDone: () => _fail(ChannelClosed()),
      cancelOnError: true,
    );
  }

  final Socket socket;
  final _reader = FrameReader();
  final _frames = Queue<Uint8List>();
  late final StreamSubscription<Uint8List> _sub;
  Completer<void>? _waiter;
  Object? _error;

  bool get isClosed => _error != null;
  String get remoteAddress {
    try {
      return socket.remoteAddress.address;
    } catch (_) {
      return '';
    }
  }

  void _wake() {
    final w = _waiter;
    _waiter = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  void _fail(Object e) {
    _error ??= e;
    _wake();
    try {
      socket.destroy();
    } catch (_) {}
  }

  /// Prochaine trame reçue (un seul lecteur à la fois).
  Future<Uint8List> read({Duration? timeout}) async {
    final deadline = timeout == null ? null : DateTime.now().add(timeout);
    while (true) {
      if (_frames.isNotEmpty) return _frames.removeFirst();
      final err = _error;
      if (err != null) throw err is ChannelClosed ? err : ChannelClosed('$err');
      final w = _waiter ??= Completer<void>();
      if (deadline == null) {
        await w.future;
      } else {
        final left = deadline.difference(DateTime.now());
        if (left <= Duration.zero) throw ChannelClosed('délai dépassé');
        await w.future.timeout(left, onTimeout: () {});
      }
    }
  }

  void send(List<int> payload) {
    if (_error != null) throw ChannelClosed();
    final head = ByteData(4)..setUint32(0, payload.length);
    try {
      socket.add(head.buffer.asUint8List());
      socket.add(payload);
    } catch (e) {
      _fail(e);
      throw ChannelClosed('$e');
    }
  }

  void sendJson(Map<String, dynamic> message) => send(utf8.encode(jsonEncode(message)));

  Future<Map<String, dynamic>> readJson({Duration? timeout}) async {
    final frame = await read(timeout: timeout);
    try {
      return Map<String, dynamic>.from(jsonDecode(utf8.decode(frame)) as Map);
    } catch (_) {
      throw ChannelClosed('message invalide');
    }
  }

  Future<void> close() async {
    _fail(ChannelClosed());
    try {
      await _sub.cancel();
    } catch (_) {}
  }
}

/// Canal chiffré et authentifié (ChaCha20-Poly1305) au-dessus d'un [Wire].
/// Chaque sens a sa clé et un compteur : une trame modifiée, rejouée ou
/// déplacée est refusée et ferme la connexion.
class SecureChannel {
  SecureChannel(this.wire, {required List<int> sendKey, required List<int> receiveKey})
      : _sendKey = SecretKey(sendKey),
        _receiveKey = SecretKey(receiveKey);

  final Wire wire;
  final SecretKey _sendKey;
  final SecretKey _receiveKey;
  final _aead = Chacha20.poly1305Aead();
  int _sendCounter = 0;
  int _receiveCounter = 0;
  Future<void> _sendChain = Future<void>.value();

  static List<int> _nonce(int counter) {
    final n = ByteData(12)..setUint64(4, counter);
    return n.buffer.asUint8List();
  }

  /// Chiffre puis envoie ; les trames partent dans l'ordre des appels.
  Future<void> send(List<int> plain) {
    final counter = _sendCounter++;
    final done = _sendChain.then((_) async {
      final box = await _aead.encrypt(plain, secretKey: _sendKey, nonce: _nonce(counter));
      final mac = box.mac.bytes;
      final frame = Uint8List(box.cipherText.length + mac.length)
        ..setRange(0, box.cipherText.length, box.cipherText)
        ..setRange(box.cipherText.length, box.cipherText.length + mac.length, mac);
      wire.send(frame);
    });
    _sendChain = done.then((_) {}, onError: (_) {});
    return done;
  }

  Future<Uint8List> receive({Duration? timeout}) async {
    final frame = await wire.read(timeout: timeout);
    if (frame.length < 16) {
      await wire.close();
      throw ChannelClosed('trame invalide');
    }
    final cut = frame.length - 16;
    try {
      final plain = await _aead.decrypt(
        SecretBox(Uint8List.sublistView(frame, 0, cut),
            nonce: _nonce(_receiveCounter++), mac: Mac(Uint8List.sublistView(frame, cut))),
        secretKey: _receiveKey,
      );
      return plain is Uint8List ? plain : Uint8List.fromList(plain);
    } catch (_) {
      await wire.close();
      throw ChannelClosed('trame non authentifiée');
    }
  }

  Future<void> close() => wire.close();
}

/// Erreur renvoyée par l'autre appareil en réponse à une requête.
class RpcError implements Exception {
  RpcError(this.code, [this.message]);
  final String code;
  final String? message;
  @override
  String toString() => message ?? code;
}

class RpcReply {
  RpcReply([this.result = const {}, this.payload]);
  final Map<String, dynamic> result;
  final Uint8List? payload;
}

typedef RpcHandler = FutureOr<RpcReply> Function(Map<String, dynamic> params, Uint8List? payload);

/// Requêtes / réponses / événements au-dessus du canal chiffré.
///
/// Message : `[0][JSON]` ou `[1][longueur de l'en-tête][en-tête JSON][octets]`
/// (pour les morceaux de fichiers).
class RpcPeer {
  RpcPeer(this.channel);

  final SecureChannel channel;
  final handlers = <String, RpcHandler>{};
  void Function(String event, Map<String, dynamic> data)? onEvent;

  final _pending = <int, Completer<RpcReply>>{};
  final _done = Completer<void>();
  int _nextId = 1;
  bool _closed = false;
  DateTime lastActivity = DateTime.now();

  bool get isClosed => _closed;
  Future<void> get done => _done.future;

  void start() {
    unawaited(_loop());
  }

  Future<void> _loop() async {
    try {
      while (!_closed) {
        final plain = await channel.receive();
        lastActivity = DateTime.now();
        final (msg, payload) = _decode(plain);
        switch (msg['t']) {
          case 'req':
            unawaited(_serve(msg, payload));
            break;
          case 'res':
            final c = _pending.remove(msg['id']);
            if (c == null || c.isCompleted) break;
            if (msg['ok'] == true) {
              c.complete(RpcReply(Map<String, dynamic>.from((msg['r'] as Map?) ?? const {}), payload));
            } else {
              c.completeError(RpcError((msg['code'] ?? 'error').toString(), msg['msg']?.toString()));
            }
            break;
          case 'evt':
            onEvent?.call((msg['m'] ?? '').toString(), Map<String, dynamic>.from((msg['p'] as Map?) ?? const {}));
            break;
        }
      }
    } catch (e) {
      _shutdown(e);
    }
  }

  Future<void> _serve(Map<String, dynamic> msg, Uint8List? payload) async {
    final id = msg['id'];
    try {
      final handler = handlers[msg['m']];
      if (handler == null) throw RpcError('nomethod', 'méthode inconnue : ${msg['m']}');
      final reply = await handler(Map<String, dynamic>.from((msg['p'] as Map?) ?? const {}), payload);
      await _send({'t': 'res', 'id': id, 'ok': true, 'r': reply.result}, reply.payload);
    } on RpcError catch (e) {
      await _send({'t': 'res', 'id': id, 'ok': false, 'code': e.code, 'msg': e.message}).catchError((_) {});
    } on ChannelClosed {
      // rien à répondre
    } catch (e) {
      await _send({'t': 'res', 'id': id, 'ok': false, 'code': 'internal', 'msg': '$e'}).catchError((_) {});
    }
  }

  Future<void> _send(Map<String, dynamic> msg, [Uint8List? payload]) {
    final head = utf8.encode(jsonEncode(msg));
    final Uint8List out;
    if (payload == null) {
      out = Uint8List(1 + head.length)..setRange(1, 1 + head.length, head);
    } else {
      out = Uint8List(5 + head.length + payload.length);
      out[0] = 1;
      ByteData.sublistView(out, 1, 5).setUint32(0, head.length);
      out.setRange(5, 5 + head.length, head);
      out.setRange(5 + head.length, out.length, payload);
    }
    return channel.send(out);
  }

  (Map<String, dynamic>, Uint8List?) _decode(Uint8List b) {
    if (b.isEmpty) throw ChannelClosed('message vide');
    if (b[0] == 0) {
      return (Map<String, dynamic>.from(jsonDecode(utf8.decode(Uint8List.sublistView(b, 1))) as Map), null);
    }
    if (b.length < 5) throw ChannelClosed('message invalide');
    final n = ByteData.sublistView(b, 1, 5).getUint32(0);
    if (5 + n > b.length) throw ChannelClosed('message invalide');
    final head = Map<String, dynamic>.from(jsonDecode(utf8.decode(Uint8List.sublistView(b, 5, 5 + n))) as Map);
    return (head, Uint8List.sublistView(b, 5 + n));
  }

  /// Appelle une méthode de l'autre appareil.
  Future<RpcReply> call(String method,
      [Map<String, dynamic> params = const {}, Uint8List? payload, Duration timeout = const Duration(seconds: 45)]) {
    if (_closed) return Future.error(ChannelClosed());
    final id = _nextId++;
    final c = Completer<RpcReply>();
    _pending[id] = c;
    _send({'t': 'req', 'id': id, 'm': method, 'p': params}, payload).catchError((Object e) {
      final p = _pending.remove(id);
      if (p != null && !p.isCompleted) p.completeError(e is ChannelClosed ? e : ChannelClosed('$e'));
    });
    return c.future.timeout(timeout, onTimeout: () {
      _pending.remove(id);
      _shutdown(ChannelClosed('délai dépassé'));
      throw ChannelClosed('délai dépassé');
    });
  }

  /// Envoie un événement sans attendre de réponse.
  void notify(String event, [Map<String, dynamic> data = const {}]) {
    if (_closed) return;
    _send({'t': 'evt', 'm': event, 'p': data}).catchError((_) {});
  }

  void _shutdown(Object reason) {
    if (_closed) return;
    _closed = true;
    final err = reason is ChannelClosed ? reason : ChannelClosed('$reason');
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(err);
    }
    _pending.clear();
    unawaited(channel.close());
    if (!_done.isCompleted) _done.complete();
  }

  Future<void> close() async {
    _shutdown(ChannelClosed());
  }
}
