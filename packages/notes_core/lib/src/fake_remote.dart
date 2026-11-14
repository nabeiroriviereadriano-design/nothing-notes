import 'dart:async';
import 'dart:typed_data';

import 'merge.dart' show jsonEq;
import 'models.dart';
import 'remote.dart';

/// Serveur en mémoire qui reproduit exactement la logique de `sync_push`
/// (contrôle de version, idempotence, séquence, isolation par compte).
/// Sert aux tests rapides du moteur de synchronisation.
class FakeServer {
  final _tables = {for (final t in EntityType.values) t: <String, Map<String, dynamic>>{}};
  final _ops = <String, String>{}; // op_id -> user
  final _files = <String, Uint8List>{};
  final _history = <Map<String, dynamic>>[];
  final _changes = StreamController<void>.broadcast();
  int _seq = 0;

  FakeRemote client(String userId) => FakeRemote(this, userId);

  int rowCount(EntityType t) => _tables[t]!.length;
  Map<String, dynamic>? row(EntityType t, String id) => _tables[t]![id];
  bool hasFile(String path) => _files.containsKey(path);
}

class FakeRemote implements RemoteApi {
  FakeRemote(this.server, this.userId);

  final FakeServer server;
  @override
  final String userId;

  /// Simule une coupure réseau.
  bool online = true;

  /// Simule une réponse perdue : le serveur applique mais le client ne reçoit rien.
  bool dropNextResponse = false;

  void _check() {
    if (!online) throw RemoteUnavailable('hors ligne (simulé)');
  }

  @override
  Future<void> prepare() async => _check();

  @override
  Future<PushResult> push(EntityType type, Map<String, dynamic> row, int baseVersion, String opId) async {
    _check();
    final table = server._tables[type]!;
    final id = row['id'].toString();
    if (server._ops.containsKey(opId)) {
      if (server._ops[opId] != userId) throw RemoteError('Accès refusé');
      return PushResult('duplicate', jsonClone(table[id]));
    }
    final cur = table[id];
    if (cur != null && cur['user_id'] != userId) throw RemoteError('Accès refusé');
    if (cur != null && asInt(cur['version']) != baseVersion) {
      return PushResult('conflict', jsonClone(cur));
    }
    if (type == EntityType.notes && cur != null) {
      final changed = !jsonEq(cur['title'], row['title']) || !jsonEq(cur['content'], row['content']);
      if (changed && !asBool(cur['purged'])) {
        server._history.add({...jsonClone(cur), 'note_id': id, 'saved_at': nowIso()});
      }
    }
    final next = <String, dynamic>{
      ...?cur,
      ...jsonClone(row),
      'user_id': userId,
      'version': asInt(cur?['version']) + 1,
      'server_seq': ++server._seq,
      if (cur != null) 'created_at': cur['created_at'],
    };
    table[id] = next;
    server._ops[opId] = userId;
    server._changes.add(null);
    if (dropNextResponse) {
      dropNextResponse = false;
      throw RemoteUnavailable('réponse perdue (simulé)');
    }
    return PushResult('ok', jsonClone(next));
  }

  @override
  Future<List<Map<String, dynamic>>> pull(EntityType type, int afterSeq, int limit) async {
    _check();
    final rows = server._tables[type]!.values
        .where((r) => r['user_id'] == userId && asInt(r['server_seq']) > afterSeq)
        .toList()
      ..sort((a, b) => asInt(a['server_seq']).compareTo(asInt(b['server_seq'])));
    return rows.take(limit).map((r) => jsonClone<Map<String, dynamic>>(r)).toList();
  }

  void _checkPath(String p) {
    if (!p.startsWith('$userId/')) throw RemoteError('Accès refusé au fichier');
  }

  @override
  Future<void> uploadFile(String storagePath, Uint8List bytes, String mime) async {
    _check();
    _checkPath(storagePath);
    server._files[storagePath] = Uint8List.fromList(bytes);
  }

  @override
  Future<Uint8List> downloadFile(String storagePath) async {
    _check();
    _checkPath(storagePath);
    final f = server._files[storagePath];
    if (f == null) throw RemoteError('Fichier introuvable');
    return f;
  }

  @override
  Future<void> removeFiles(List<String> storagePaths) async {
    _check();
    for (final p in storagePaths) {
      _checkPath(p);
      server._files.remove(p);
    }
  }

  @override
  Future<void> saveNoteVersion(String noteId, String title, Map<String, dynamic> content, String deviceId) async {
    _check();
    server._history.add({'note_id': noteId, 'user_id': userId, 'title': title, 'content': content, 'saved_at': nowIso()});
  }

  @override
  Future<List<Map<String, dynamic>>> noteHistory(String noteId) async {
    _check();
    return server._history.where((h) => h['note_id'] == noteId && h['user_id'] == userId).toList().reversed.toList();
  }

  @override
  Stream<void> get changes => server._changes.stream;

  @override
  Future<void> dispose() async {}
}
