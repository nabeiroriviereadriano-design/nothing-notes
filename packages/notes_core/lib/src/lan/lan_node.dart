import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../local_store.dart';
import '../models.dart';
import '../status.dart';
import 'channel.dart';
import 'discovery.dart';
import 'key_store.dart';
import 'speke.dart';
import 'sync_driver.dart';

/// Port TCP de synchronisation et port UDP des annonces.
const kDefaultSyncPort = 45893;
const kDefaultDiscoveryPort = 45892;
/// Version du protocole. 2 = Nothing Notes 3.x (pages, bases, tâches) :
/// un appareil resté en 2.x ne conserve pas les nouveaux champs, la
/// synchronisation avec lui est donc refusée tant qu'il n'est pas mis à jour.
/// Version du protocole de synchronisation. 2 = Nothing Notes 3.x (pages,
/// bases, tâches) : refuse les appareils 2.0, qui perdraient ces champs.
const kProtocolVersion = 2;

/// Échec d'une association par code.
class PairingError implements Exception {
  PairingError(this.code, this.message);

  /// 'format', 'badcode', 'notfound', 'unreachable'.
  final String code;
  final String message;
  @override
  String toString() => message;
}

/// Appareil associé et son état de connexion.
class PeerView {
  PeerView(this.info,
      {required this.connected, required this.syncing, required this.rejected, this.outdated = false});
  final PeerInfo info;
  final bool connected;
  final bool syncing;

  /// L'autre appareil ne reconnaît plus l'association (elle y a été supprimée).
  final bool rejected;

  /// L'autre appareil utilise une version incompatible de Nothing Notes.
  final bool outdated;
}

class _Session {
  _Session(this.node, this.peerId, this.rpc, {required this.tcpClient, required this.driver});

  final LanNode node;
  final String peerId;
  final RpcPeer rpc;

  /// Cet appareil a ouvert la connexion TCP.
  final bool tcpClient;

  /// Cet appareil pilote l'échange (identifiant le plus petit des deux).
  final bool driver;

  SyncDriver? _sync;
  Timer? _timer;
  Timer? _notifyTimer;
  bool running = false;
  bool closed = false;
  bool _again = false;
  bool _pinging = false;
  String? error;

  /// Une modification locale vient d'avoir lieu.
  void signalChange() {
    if (closed) return;
    if (driver) {
      requestRound();
    } else {
      _notifyTimer ??= Timer(node.debounce, () {
        _notifyTimer = null;
        rpc.notify('changed');
      });
    }
  }

  void requestRound({Duration? delay}) {
    if (!driver || closed) return;
    _timer?.cancel();
    _timer = Timer(delay ?? node.debounce, () => unawaited(_run()));
  }

  Future<void> _run() async {
    if (closed) return;
    if (running) {
      _again = true;
      return;
    }
    running = true;
    node._publish();
    try {
      final sync = _sync ??= SyncDriver(store: node.store, rpc: rpc, peerId: peerId, filesDir: node.filesDir);
      await sync.round();
      error = null;
    } on ChannelClosed {
      // connexion perdue : la session est nettoyée par ailleurs, on réessaiera
    } catch (e) {
      error = e.toString();
    } finally {
      running = false;
      node._publish();
      if (_again && !closed) {
        _again = false;
        requestRound();
      }
    }
  }

  /// Vérifie que l'autre appareil répond encore (connexion coupée sans prévenir).
  void keepAlive(Duration idle) {
    if (closed || running || _pinging) return;
    if (DateTime.now().difference(rpc.lastActivity) < idle) return;
    _pinging = true;
    rpc
        .call('ping', const {}, null, const Duration(seconds: 6))
        .then((_) {}, onError: (_) {})
        .whenComplete(() => _pinging = false);
  }

  void close() {
    closed = true;
    _timer?.cancel();
    _notifyTimer?.cancel();
    unawaited(rpc.close());
  }
}

/// Synchronisation directe entre appareils sur le réseau local.
///
/// Chaque appareil écoute sur un port TCP et s'annonce en UDP. Deux
/// appareils associés (par un code à 6 chiffres) qui se voient ouvrent une
/// connexion chiffrée et échangent leurs modifications ; la connexion reste
/// ouverte tant que les deux applications tournent, pour une
/// synchronisation quasi instantanée. Aucun serveur, aucun compte.
class LanNode {
  LanNode({
    required this.store,
    required this.filesDir,
    required this.keys,
    this.platform = 'inconnu',
    this.tcpPort = kDefaultSyncPort,
    this.discoveryPort = kDefaultDiscoveryPort,
    this.enableDiscovery = true,
    this.discoveryBroadcast = true,
    this.discoveryTargets = const [],
    this.enableScan = true,
    this.retryInterval = const Duration(seconds: 5),
    this.debounce = const Duration(milliseconds: 400),
    this.protocolVersion = kProtocolVersion,
  });

  /// Version du protocole annoncée (modifiable uniquement pour les tests).
  final int protocolVersion;

  final LocalStore store;
  final String filesDir;
  final KeyStore keys;
  final String platform;
  final int tcpPort;
  final int discoveryPort;
  final bool enableDiscovery;
  final bool discoveryBroadcast;
  final List<(String, int)> discoveryTargets;

  /// Recherche active des appareils associés sur le sous-réseau quand les
  /// annonces ne passent pas.
  final bool enableScan;
  final Duration retryInterval;
  final Duration debounce;

  ServerSocket? _server;
  Discovery? _discovery;
  StreamSubscription<SeenDevice>? _seenSub;
  StreamSubscription<EntityType>? _storeSub;
  Timer? _tick;
  bool _running = false;
  bool _scanning = false;
  DateTime _lastScan = DateTime.fromMillisecondsSinceEpoch(0);

  final _sessions = <String, _Session>{};
  final _dialing = <String>{};
  final _rejected = <String>{};
  final _outdated = <String>{};
  final _status = StreamController<SyncStatus>.broadcast();
  final _paired = StreamController<PeerInfo>.broadcast();
  final _pairingEvents = StreamController<void>.broadcast();
  SyncStatus _current = const SyncStatus(SyncState.unpaired);

  // Association : côté qui affiche le code.
  String? _pairCode;
  DateTime? _pairUntil;
  int _pairFailures = 0;

  // Association : côté qui saisit le code.
  bool _joining = false;
  final _joinCandidates = <String, SeenDevice>{};

  Stream<SyncStatus> get statusStream => _status.stream;
  SyncStatus get status => _current;

  /// Émis quand un appareil vient d'être associé.
  Stream<PeerInfo> get onPaired => _paired.stream;

  /// Émis quand le code affiché n'est plus valable (expiré ou trop d'essais).
  Stream<void> get onPairingEnded => _pairingEvents.stream;

  bool get isRunning => _running;
  int get port => _server?.port ?? 0;
  int get connectedCount => _sessions.length;

  List<PeerView> get peers => [
        for (final p in store.peers())
          PeerView(p,
              connected: _sessions.containsKey(p.id),
              syncing: _sessions[p.id]?.running ?? false,
              rejected: _rejected.contains(p.id),
              outdated: _outdated.contains(p.id))
      ];

  // ------------------------------------------------------------------ cycle de vie
  Future<void> start() async {
    if (_running) return;
    _running = true;
    try {
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, tcpPort);
    } on SocketException {
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    }
    _server!.listen((s) => unawaited(_onAccept(s)), onError: (_) {});
    if (enableDiscovery) {
      final d = Discovery(
          port: discoveryPort, describe: _describe, broadcast: discoveryBroadcast, extraTargets: discoveryTargets);
      await d.start();
      _seenSub = d.seen.listen(_onSeen);
      _discovery = d;
    }
    _storeSub = store.changes.listen((_) => _onLocalChange());
    _tick = Timer.periodic(retryInterval, (_) => unawaited(_maintain()));
    _publish();
    unawaited(_maintain());
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _tick?.cancel();
    await _storeSub?.cancel();
    await _seenSub?.cancel();
    _discovery?.stop();
    _discovery = null;
    for (final s in _sessions.values.toList()) {
      s.close();
    }
    _sessions.clear();
    try {
      await _server?.close();
    } catch (_) {}
    _server = null;
    stopPairing();
    _publish();
  }

  Future<void> dispose() async {
    await stop();
    await _status.close();
    await _paired.close();
    await _pairingEvents.close();
  }

  Map<String, dynamic> _describe() => {
        'id': store.deviceId,
        'name': store.deviceName,
        'plat': platform,
        'port': port,
        'pairing': isPairing,
      };

  // ------------------------------------------------------------------ état
  void _publish() {
    if (store.isClosed) return;
    final all = store.peers();
    final SyncStatus next;
    if (all.isEmpty) {
      next = SyncStatus(SyncState.unpaired, conflicts: store.conflictCount());
    } else {
      final pending = store.pendingCount();
      final connected = _sessions.length;
      final syncing = _sessions.values.any((s) => s.running);
      String? error;
      for (final s in _sessions.values) {
        error ??= s.error;
      }
      final outdated = [
        for (final p in all)
          if (_outdated.contains(p.id) && !_sessions.containsKey(p.id)) p.name
      ];
      if (outdated.isNotEmpty) {
        error ??= 'Mettez à jour Nothing Notes sur « ${outdated.join(' », « ')} » pour reprendre la synchronisation.';
      }
      DateTime? last;
      for (final p in all) {
        final at = p.lastSync;
        if (at != null && (last == null || at.isAfter(last))) last = at;
      }
      final state = syncing
          ? SyncState.syncing
          : connected == 0
              ? (outdated.isNotEmpty ? SyncState.error : SyncState.offline)
              : error != null
                  ? SyncState.error
                  : pending > 0
                      ? SyncState.pending
                      : SyncState.synced;
      next = SyncStatus(state,
          pending: pending,
          conflicts: store.conflictCount(),
          peers: all.length,
          connected: connected,
          message: error,
          lastSync: last);
    }
    _current = next;
    if (!_status.isClosed) _status.add(next);
  }

  void _onLocalChange() {
    for (final s in _sessions.values) {
      s.signalChange();
    }
    _publish();
  }

  /// Entretien périodique : reconnexion, annonces, surveillance des sessions.
  Future<void> _maintain() async {
    if (!_running || store.isClosed) return;
    if (_pairCode != null && !isPairing && !_pairingEvents.isClosed) _pairingEvents.add(null);
    final missing = store.peers().where((p) => !_sessions.containsKey(p.id)).toList();
    for (final s in _sessions.values.toList()) {
      s.keepAlive(retryInterval * 3);
      // Filet de sécurité : relancer un échange s'il reste quelque chose à envoyer.
      if (s.driver && !s.running && (s.error != null || store.pushCandidates(s.peerId, 1).isNotEmpty)) {
        s.requestRound();
      }
    }
    if (missing.isNotEmpty || isPairing || _joining) {
      unawaited(_discovery?.announce(unicast: [
        for (final p in missing)
          if (p.address != null) p.address!
      ]));
    }
    for (final p in missing) {
      if (p.address != null && p.port != null) unawaited(_connect(p.address!, p.port!, expectId: p.id));
    }
    if (enableScan &&
        missing.isNotEmpty &&
        !_scanning &&
        DateTime.now().difference(_lastScan) > const Duration(seconds: 20)) {
      unawaited(_scanForPeers());
    }
    _publish();
  }

  /// Relance immédiatement connexions et échanges (retour au premier plan,
  /// bouton « Synchroniser maintenant »).
  Future<void> syncNow() async {
    _lastScan = DateTime.fromMillisecondsSinceEpoch(0);
    for (final s in _sessions.values.toList()) {
      s.keepAlive(Duration.zero);
    }
    await _maintain();
    for (final s in _sessions.values) {
      if (s.driver) {
        s.requestRound(delay: Duration.zero);
      } else {
        s.rpc.notify('changed');
      }
    }
  }

  // ------------------------------------------------------------------ découverte
  void _onSeen(SeenDevice d) {
    if (!_running || d.id == store.deviceId) return;
    if (_joining && d.pairing) _joinCandidates['${d.address}:${d.port}'] = d;
    if (store.peer(d.id) == null) return;
    store.touchPeer(d.id, address: d.address, port: d.port, name: d.name.isEmpty ? null : d.name);
    if (_sessions.containsKey(d.id)) return;
    if (store.isDriverFor(d.id)) {
      unawaited(_connect(d.address, d.port, expectId: d.id));
    } else {
      // On laisse l'autre appareil se connecter ; s'il n'y arrive pas
      // (pare-feu de son côté), on prend l'initiative.
      Timer(const Duration(milliseconds: 1500), () {
        if (_running && !_sessions.containsKey(d.id)) unawaited(_connect(d.address, d.port, expectId: d.id));
      });
    }
  }

  Future<Map<String, dynamic>?> _probe(String host, int port) async {
    Socket? socket;
    try {
      socket = await Socket.connect(host, port, timeout: const Duration(milliseconds: 450));
      final wire = Wire(socket);
      try {
        return await wire.readJson(timeout: const Duration(seconds: 2));
      } finally {
        await wire.close();
      }
    } catch (_) {
      socket?.destroy();
      return null;
    }
  }

  /// Cherche les appareils Nothing Notes sur les sous-réseaux locaux.
  Future<List<(String, Map<String, dynamic>)>> _scanHosts() async {
    final found = <(String, Map<String, dynamic>)>[];
    final mine = await localIPv4Addresses();
    final targets = <String>{};
    for (final a in mine) {
      final parts = a.split('.');
      for (var i = 1; i < 255; i++) {
        final host = '${parts[0]}.${parts[1]}.${parts[2]}.$i';
        if (!mine.contains(host)) targets.add(host);
      }
    }
    final list = targets.toList();
    for (var i = 0; i < list.length && _running; i += 64) {
      await Future.wait(list.skip(i).take(64).map((host) async {
        final hello = await _probe(host, kDefaultSyncPort);
        if (hello != null) found.add((host, hello));
      }));
    }
    return found;
  }

  Future<void> _scanForPeers() async {
    _scanning = true;
    _lastScan = DateTime.now();
    try {
      for (final (host, hello) in await _scanHosts()) {
        final id = hello['id'];
        if (id is String && store.peer(id) != null && !_sessions.containsKey(id)) {
          await _connect(host, kDefaultSyncPort, expectId: id);
        }
      }
    } catch (_) {
      // réseau indisponible : on réessaiera
    } finally {
      _scanning = false;
    }
  }

  // ------------------------------------------------------------------ connexion
  static String _transcript(Object? mode, String serverId, String clientId, Object? serverNonce,
          Object? clientNonce, Object? clientPublic, Object? serverPublic) =>
      [mode, serverId, clientId, serverNonce, clientNonce, clientPublic, serverPublic].join('|');

  /// Connexion entrante.
  Future<void> _onAccept(Socket socket) async {
    Wire? wire;
    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
      wire = Wire(socket);
      final serverNonce = hexOf(randomBytes(16));
      wire.sendJson({
        'v': protocolVersion,
        'id': store.deviceId,
        'name': store.deviceName,
        'plat': platform,
        'pairing': isPairing,
        'ns': serverNonce,
      });
      final m = await wire.readJson(timeout: const Duration(seconds: 12));
      final mode = m['mode'];
      final clientId = m['id'];
      if (clientId is! String || clientId.isEmpty || clientId == store.deviceId) throw HandshakeError('invalid');
      if (m['v'] != protocolVersion) {
        wire.sendJson({'error': 'version', 'v': protocolVersion});
        if (store.peer(clientId) != null && _outdated.add(clientId)) _publish();
        throw HandshakeError('version');
      }
      final List<int> secret;
      if (mode == 'pair') {
        final code = pairingCode;
        if (code == null) {
          wire.sendJson({'error': 'nopairing'});
          throw HandshakeError('nopairing');
        }
        secret = utf8.encode(code);
        // Chaque tentative compte dès qu'elle commence : à la 3e, le code est
        // retiré immédiatement (il reste utilisable pour cette seule tentative).
        _pairFailures++;
        if (_pairFailures >= 3) {
          stopPairing();
          if (!_pairingEvents.isClosed) _pairingEvents.add(null);
        }
      } else if (mode == 'session') {
        final key = store.peer(clientId) == null ? null : await keys.read(clientId);
        if (key == null) {
          wire.sendJson({'error': 'unknown'});
          throw HandshakeError('unknown');
        }
        secret = key;
      } else {
        throw HandshakeError('invalid');
      }
      final side = SpekeSide(secret);
      final transcript =
          _transcript(mode, store.deviceId, clientId, serverNonce, m['nc'], m['pub'], side.publicHex);
      final sk = deriveKeys(side.shared(m['pub']), transcript);
      wire.sendJson({'pub': side.publicHex, 'tag': confirmTag(sk.confirm, 'server', transcript)});
      final c = await wire.readJson(timeout: const Duration(seconds: 12));
      if (!sameTag(c['tag'], confirmTag(sk.confirm, 'client', transcript))) throw HandshakeError('badsecret');

      final name = (m['name'] ?? '').toString();
      final plat = (m['plat'] ?? '').toString();
      final clientPort = m['port'] is int ? m['port'] as int : null;
      if (mode == 'pair') {
        await keys.write(clientId, sk.pairKey);
        _dropSession(clientId);
        store.addPeer(clientId, name: name, platform: plat, address: wire.remoteAddress, port: clientPort);
        _rejected.remove(clientId);
        stopPairing();
        final info = store.peer(clientId);
        if (info != null && !_paired.isClosed) _paired.add(info);
      }
      _attach(clientId, SecureChannel(wire, sendKey: sk.serverToClient, receiveKey: sk.clientToServer),
          tcpClient: false, address: wire.remoteAddress, port: clientPort, name: name, platform: plat);
    } catch (_) {
      if (wire != null) {
        await wire.close();
      } else {
        socket.destroy();
      }
    }
  }

  /// Connexion sortante. Avec [pairCode] : association ; sinon session avec
  /// un appareil déjà associé. Retourne l'identifiant de l'appareil.
  Future<String> _dial(String host, int port, {String? expectId, String? pairCode}) async {
    final target = '$host:$port';
    if (!_running) throw ChannelClosed('synchronisation arrêtée');
    if (!_dialing.add(target)) throw ChannelClosed('connexion déjà en cours');
    Wire? wire;
    try {
      final socket = await Socket.connect(host, port, timeout: const Duration(seconds: 3));
      socket.setOption(SocketOption.tcpNoDelay, true);
      wire = Wire(socket);
      final hello = await wire.readJson(timeout: const Duration(seconds: 6));
      final serverId = hello['id'];
      if (serverId is! String || serverId.isEmpty || serverId == store.deviceId) throw HandshakeError('invalid');
      if (hello['v'] != protocolVersion) {
        if (store.peer(serverId) != null && _outdated.add(serverId)) _publish();
        throw HandshakeError('version', 'versions de Nothing Notes incompatibles');
      }
      if (expectId != null && serverId != expectId) throw HandshakeError('invalid');
      final String mode;
      final List<int> secret;
      if (pairCode != null) {
        if (hello['pairing'] != true) throw HandshakeError('nopairing');
        mode = 'pair';
        secret = utf8.encode(pairCode);
      } else {
        if (_sessions.containsKey(serverId)) throw ChannelClosed('déjà connecté');
        final key = store.peer(serverId) == null ? null : await keys.read(serverId);
        if (key == null) throw HandshakeError('unknown');
        mode = 'session';
        secret = key;
      }
      final side = SpekeSide(secret);
      final clientNonce = hexOf(randomBytes(16));
      wire.sendJson({
        'v': protocolVersion,
        'mode': mode,
        'id': store.deviceId,
        'name': store.deviceName,
        'plat': platform,
        'port': this.port,
        'nc': clientNonce,
        'pub': side.publicHex,
      });
      final r = await wire.readJson(timeout: const Duration(seconds: 12));
      if (r['error'] != null) {
        final code = r['error'].toString();
        if (code == 'unknown' && mode == 'session') {
          _rejected.add(serverId);
          _publish();
        }
        if (code == 'version' && store.peer(serverId) != null && _outdated.add(serverId)) _publish();
        throw HandshakeError(code);
      }
      final transcript =
          _transcript(mode, serverId, store.deviceId, hello['ns'], clientNonce, side.publicHex, r['pub']);
      final sk = deriveKeys(side.shared(r['pub']), transcript);
      if (!sameTag(r['tag'], confirmTag(sk.confirm, 'server', transcript))) throw HandshakeError('badsecret');
      wire.sendJson({'tag': confirmTag(sk.confirm, 'client', transcript)});

      final name = (hello['name'] ?? '').toString();
      final plat = (hello['plat'] ?? '').toString();
      if (mode == 'pair') {
        await keys.write(serverId, sk.pairKey);
        _dropSession(serverId);
        store.addPeer(serverId, name: name, platform: plat, address: host, port: port);
        final info = store.peer(serverId);
        if (info != null && !_paired.isClosed) _paired.add(info);
      }
      _rejected.remove(serverId);
      _outdated.remove(serverId);
      _attach(serverId, SecureChannel(wire, sendKey: sk.clientToServer, receiveKey: sk.serverToClient),
          tcpClient: true, address: host, port: port, name: name, platform: plat);
      return serverId;
    } catch (_) {
      await wire?.close();
      rethrow;
    } finally {
      _dialing.remove(target);
    }
  }

  Future<bool> _connect(String host, int port, {String? expectId}) async {
    try {
      await _dial(host, port, expectId: expectId);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Tente une connexion directe à un appareil déjà associé.
  Future<bool> connectTo(String host, int port) => _connect(host, port);

  void _attach(String peerId, SecureChannel channel,
      {required bool tcpClient, String? address, int? port, String? name, String? platform}) {
    _outdated.remove(peerId);
    final driver = store.isDriverFor(peerId);
    final rpc = RpcPeer(channel);
    final existing = _sessions[peerId];
    if (existing != null) {
      // Deux connexions simultanées (chacun a appelé l'autre) : les deux
      // appareils gardent celle ouverte par le pilote.
      final preferNew = tcpClient == driver;
      final preferOld = existing.tcpClient == driver;
      if (preferOld || !preferNew) {
        unawaited(rpc.close());
        return;
      }
      _sessions.remove(peerId);
      existing.close();
    }
    final session = _Session(this, peerId, rpc, tcpClient: tcpClient, driver: driver);
    _sessions[peerId] = session;
    store.touchPeer(peerId,
        address: address,
        port: port,
        name: (name == null || name.isEmpty) ? null : name,
        platform: (platform == null || platform.isEmpty) ? null : platform);
    registerResponder(rpc, store, peerId, filesDir, onProgress: _publish);
    rpc.onEvent = (event, _) {
      if (event == 'changed') {
        session.requestRound();
      } else if (event == 'unpair') {
        unawaited(_forget(peerId, notify: false));
      }
    };
    rpc.start();
    unawaited(rpc.done.then((_) => _onSessionClosed(session)));
    if (driver) session.requestRound(delay: Duration.zero);
    _publish();
  }

  void _onSessionClosed(_Session session) {
    session.closed = true;
    if (_sessions[session.peerId] == session) _sessions.remove(session.peerId);
    _publish();
  }

  void _dropSession(String peerId) => _sessions.remove(peerId)?.close();

  // ------------------------------------------------------------------ association
  bool get isPairing {
    final until = _pairUntil;
    return _pairCode != null && until != null && DateTime.now().isBefore(until);
  }

  /// Code actuellement affiché, s'il est encore valable.
  String? get pairingCode => isPairing ? _pairCode : null;
  DateTime? get pairingExpires => isPairing ? _pairUntil : null;

  /// Affiche un nouveau code d'association à 6 chiffres (valable 5 minutes,
  /// annulé après 3 essais erronés).
  String startPairing({Duration validity = const Duration(minutes: 5)}) {
    final code = newPairingCode();
    _pairCode = code;
    _pairUntil = DateTime.now().add(validity);
    _pairFailures = 0;
    unawaited(_discovery?.announce());
    return code;
  }

  void stopPairing() {
    _pairCode = null;
    _pairUntil = null;
  }

  static (String, int) _parseAddress(String input) {
    final s = input.trim();
    final i = s.lastIndexOf(':');
    if (i > 0) {
      final port = int.tryParse(s.substring(i + 1));
      if (port != null && port > 0 && port < 65536) return (s.substring(0, i), port);
    }
    return (s, kDefaultSyncPort);
  }

  /// Associe cet appareil à celui qui affiche [code]. L'appareil est cherché
  /// sur le réseau local (annonces puis balayage), ou à l'adresse [address]
  /// si elle est fournie.
  Future<PeerInfo> joinWithCode(String code, {String? address, Duration timeout = const Duration(seconds: 20)}) async {
    final digits = code.replaceAll(RegExp(r'\D'), '');
    if (digits.length != 6) throw PairingError('format', 'Le code comporte 6 chiffres.');
    if (!_running) throw PairingError('unreachable', 'La synchronisation est arrêtée.');
    _joining = true;
    _joinCandidates.clear();
    final tried = <String>{};
    var blocked = false;

    Future<PeerInfo?> attempt(String host, int port) async {
      if (!tried.add('$host:$port')) return null;
      try {
        return store.peer(await _dial(host, port, pairCode: digits));
      } on HandshakeError catch (e) {
        if (e.code == 'badsecret') throw PairingError('badcode', 'Code incorrect.');
        if (e.code == 'version') {
          throw PairingError('version',
              'L\'autre appareil utilise une autre version de Nothing Notes. Installez la même version sur les deux appareils.');
        }
        return null; // cet appareil n'attend pas d'association
      } catch (_) {
        blocked = true; // vu sur le réseau mais connexion impossible
        return null;
      }
    }

    try {
      if (address != null && address.trim().isNotEmpty) {
        final (host, port) = _parseAddress(address);
        final peer = await attempt(host, port);
        if (peer != null) return peer;
        throw PairingError('unreachable', 'Aucun appareil en attente d\'association à cette adresse.');
      }
      final started = DateTime.now();
      var scanned = false;
      while (DateTime.now().difference(started) < timeout) {
        await _discovery?.announce();
        for (final d in _joinCandidates.values.toList()) {
          final peer = await attempt(d.address, d.port);
          if (peer != null) return peer;
        }
        if (enableScan && !scanned && DateTime.now().difference(started) > const Duration(milliseconds: 1500)) {
          scanned = true;
          for (final (host, hello) in await _scanHosts()) {
            if (hello['pairing'] != true) continue;
            final peer = await attempt(host, kDefaultSyncPort);
            if (peer != null) return peer;
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
      if (blocked) {
        throw PairingError(
            'unreachable',
            'L\'autre appareil a été détecté mais la connexion est bloquée (pare-feu ?). '
                'Faites l\'association dans l\'autre sens : affichez le code sur cet appareil et saisissez-le sur l\'autre.');
      }
      throw PairingError(
          'notfound',
          'Aucun appareil en attente d\'association n\'a été trouvé. Vérifiez que l\'autre appareil affiche '
              'son code et que les deux sont sur le même réseau.');
    } finally {
      _joining = false;
      _joinCandidates.clear();
    }
  }

  /// Supprime l'association avec un appareil : il ne pourra plus se
  /// synchroniser avec celui-ci (les notes déjà reçues restent de chaque côté).
  Future<void> removePeer(String peerId) => _forget(peerId, notify: true);

  Future<void> _forget(String peerId, {required bool notify}) async {
    final session = _sessions.remove(peerId);
    if (session != null) {
      if (notify) {
        session.rpc.notify('unpair');
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      session.close();
    }
    if (store.isClosed) return;
    store.removePeer(peerId);
    _rejected.remove(peerId);
    try {
      await keys.delete(peerId);
    } catch (_) {}
    _publish();
  }
}
