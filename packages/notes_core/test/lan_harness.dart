import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:notes_core/notes_core.dart';
import 'package:path/path.dart' as p;

/// Un « appareil » de test : sa propre base SQLite sur disque, son propre
/// dossier de fichiers, ses propres clés, et un vrai nœud réseau (TCP +
/// UDP sur la boucle locale). C'est exactement le code des applications.
class Device {
  Device._(this.name, this.dir, this.keys, this.udpPort, this.udpTargets);

  final String name;
  final Directory dir;
  final MemoryKeyStore keys;
  final int udpPort;
  final List<(String, int)> udpTargets;
  late LocalStore store;
  late NotesRepository repo;
  late LanNode node;
  int _port = 0;

  static Future<Device> create(String name, {int udpPort = 0, List<(String, int)> udpTargets = const []}) async {
    final dir = await Directory.systemTemp.createTemp('nn_${name}_');
    final d = Device._(name, dir, MemoryKeyStore(), udpPort, udpTargets);
    d._open();
    await d.node.start();
    d._port = d.node.port;
    return d;
  }

  void _open() {
    final files = p.join(dir.path, 'files');
    store = LocalStore.open(p.join(dir.path, 'notes.db'));
    store.deviceName = name;
    store.historyInterval = Duration.zero;
    repo = NotesRepository(store: store, filesDir: files);
    node = _makeNode();
  }

  String get _files => p.join(dir.path, 'files');

  // Le port est conservé d'un démarrage à l'autre, comme le port fixe de l'application.
  LanNode _makeNode() => LanNode(
      store: store,
      filesDir: _files,
      keys: keys,
      platform: 'test',
      tcpPort: _port,
      discoveryPort: udpPort,
      enableDiscovery: udpPort != 0,
      discoveryBroadcast: false,
      discoveryTargets: udpTargets,
      enableScan: false,
      retryInterval: const Duration(milliseconds: 300),
      debounce: const Duration(milliseconds: 40),
    );

  String get address => '127.0.0.1:${node.port}';

  /// Coupe le réseau de cet appareil (comme le mode avion).
  Future<void> goOffline() => node.dispose();

  /// Rétablit le réseau.
  Future<void> goOnline() async {
    node = _makeNode();
    await node.start();
  }

  /// Ferme complètement l'application puis la rouvre (base conservée sur disque).
  Future<void> restart() async {
    await node.dispose();
    store.close();
    _open();
    await node.start();
  }

  Future<void> close() async {
    await node.dispose();
    store.close();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  }

  Note byTitle(String title) => repo.allNotes().firstWhere((n) => n.title == title);
  Note? maybeByTitle(String title) => repo.allNotes().where((n) => n.title == title).firstOrNull;

  /// Associe cet appareil à [other] avec le code affiché par [other].
  Future<void> pairWith(Device other, {bool viaDiscovery = false}) async {
    final code = other.node.startPairing();
    await node.joinWithCode(code, address: viaDiscovery ? null : other.address);
    await waitFor(() => node.connectedCount > 0 && other.node.connectedCount > 0, 'connexion après association');
  }

  bool isDriverFor(Device other) => store.isDriverFor(other.store.deviceId);

  String snapshot() {
    final notes = repo.allNotes()..sort((a, b) => a.title.compareTo(b.title));
    return notes
        .map((n) => '${n.title}|${n.favorite}|${n.trashed}|${n.archived}|${n.tags.length}|'
            '${n.blocks.map((b) => '${b.type}:${b.text}:${b.checked}').join(',')}')
        .join('\n');
  }
}

/// Attend qu'une condition devienne vraie (synchronisation asynchrone).
Future<void> waitFor(bool Function() condition, String what, {Duration timeout = const Duration(seconds: 20)}) async {
  final end = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(end)) throw TimeoutException('Délai dépassé : $what');
    await Future<void>.delayed(const Duration(milliseconds: 40));
  }
}

/// Attend que tous les appareils aient le même contenu, sans rien en attente.
Future<void> waitConverged(List<Device> devices, {Duration timeout = const Duration(seconds: 25)}) =>
    waitFor(() {
      final s = devices.first.snapshot();
      return devices.every((d) => d.snapshot() == s && d.store.pendingCount() == 0);
    }, 'convergence de ${devices.map((d) => d.name).join(', ')}', timeout: timeout);

Uint8List fakePng(int size, [int seed = 7]) {
  final r = Random(seed);
  final b = Uint8List(size);
  const header = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];
  for (var i = 0; i < size; i++) {
    b[i] = i < header.length ? header[i] : r.nextInt(256);
  }
  return b;
}

int freeUdpPort() => 46000 + Random().nextInt(15000);
