import 'dart:async';
import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import 'models.dart';

/// Un élément tel que stocké sur l'appareil.
class LocalRecord {
  LocalRecord({
    required this.type,
    required this.id,
    required this.data,
    this.base,
    this.conflict,
    this.dirty = false,
    this.localRev = 0,
  });

  final EntityType type;
  final String id;

  /// État courant affiché à l'utilisateur.
  final Map<String, dynamic> data;

  /// Dernière version confirmée par le serveur (ancêtre commun pour la fusion).
  final Map<String, dynamic>? base;

  /// Version serveur concurrente non résolue.
  final Map<String, dynamic>? conflict;

  /// Modifications locales en attente d'envoi.
  final bool dirty;
  final int localRev;

  int get baseVersion => asInt(base?['version']);
  int get dataVersion => asInt(data['version']);
}

/// Opération en attente dans la file de synchronisation persistante.
class OutboxOp {
  OutboxOp(this.type, this.id, this.opId, this.rev, this.attempts, this.lastError);
  final EntityType type;
  final String id;
  final String opId;
  final int rev;
  final int attempts;
  final String? lastError;
}

const _priority = {
  EntityType.folders: 0,
  EntityType.tags: 1,
  EntityType.attachments: 2,
  EntityType.notes: 3,
};

/// Base de données locale SQLite (une par compte et par appareil).
///
/// Toutes les modifications sont écrites ici immédiatement, avant toute
/// tentative réseau : l'application fonctionne entièrement hors ligne.
class LocalStore {
  LocalStore._(this._db) {
    _migrate();
  }

  factory LocalStore.open(String path) => LocalStore._(sqlite3.open(path));
  factory LocalStore.inMemory() => LocalStore._(sqlite3.openInMemory());

  final Database _db;
  final _changes = StreamController<EntityType>.broadcast();
  int _txDepth = 0;
  bool _closed = false;

  /// Émis après chaque modification locale ou appliquée depuis le serveur.
  Stream<EntityType> get changes => _changes.stream;

  void _migrate() {
    _db.execute('PRAGMA journal_mode = WAL;');
    _db.execute('PRAGMA synchronous = FULL;');
    _db.execute('PRAGMA foreign_keys = OFF;');
    if (_db.userVersion < 1) {
      _db.execute('''
        CREATE TABLE IF NOT EXISTS entities (
          entity    TEXT NOT NULL,
          id        TEXT NOT NULL,
          data      TEXT NOT NULL,
          base      TEXT,
          conflict  TEXT,
          dirty     INTEGER NOT NULL DEFAULT 0,
          local_rev INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (entity, id)
        );
        CREATE TABLE IF NOT EXISTS outbox (
          entity     TEXT NOT NULL,
          id         TEXT NOT NULL,
          op_id      TEXT NOT NULL,
          rev        INTEGER NOT NULL,
          attempts   INTEGER NOT NULL DEFAULT 0,
          last_error TEXT,
          created_at TEXT NOT NULL,
          PRIMARY KEY (entity, id)
        );
        CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
        CREATE TABLE IF NOT EXISTS files (
          attachment_id TEXT PRIMARY KEY,
          local_path    TEXT NOT NULL,
          uploaded      INTEGER NOT NULL DEFAULT 0
        );
        CREATE VIRTUAL TABLE IF NOT EXISTS notes_fts USING fts5(
          id UNINDEXED, title, body, tokenize = 'unicode61 remove_diacritics 2'
        );
      ''');
      _db.userVersion = 1;
    }
  }

  // ------------------------------------------------------------ utilitaires
  T transaction<T>(T Function() body) {
    if (_txDepth > 0) return body();
    _db.execute('BEGIN IMMEDIATE');
    _txDepth++;
    try {
      final r = body();
      _txDepth--;
      _db.execute('COMMIT');
      return r;
    } catch (_) {
      _txDepth--;
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  void _emit(EntityType t) {
    if (!_changes.isClosed) _changes.add(t);
  }

  static Map<String, dynamic>? _decode(Object? v) =>
      v == null ? null : Map<String, dynamic>.from(jsonDecode(v as String) as Map);

  String? getMeta(String key) {
    final rs = _db.select('SELECT value FROM meta WHERE key = ?', [key]);
    return rs.isEmpty ? null : rs.first['value'] as String?;
  }

  void setMeta(String key, String? value) {
    if (value == null) {
      _db.execute('DELETE FROM meta WHERE key = ?', [key]);
    } else {
      _db.execute('INSERT INTO meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value',
          [key, value]);
    }
  }

  /// Identifiant stable de cet appareil.
  String get deviceId {
    var id = getMeta('device_id');
    if (id == null) {
      id = newId();
      setMeta('device_id', id);
    }
    return id;
  }

  int cursor(EntityType t) => int.tryParse(getMeta('cursor_${t.name}') ?? '') ?? 0;
  void setCursor(EntityType t, int seq) => setMeta('cursor_${t.name}', '$seq');

  // ------------------------------------------------------------ lecture
  LocalRecord _toRecord(Row r) => LocalRecord(
        type: entityFromName(r['entity'] as String),
        id: r['id'] as String,
        data: _decode(r['data'])!,
        base: _decode(r['base']),
        conflict: _decode(r['conflict']),
        dirty: (r['dirty'] as int) != 0,
        localRev: r['local_rev'] as int,
      );

  LocalRecord? get(EntityType t, String id) {
    final rs = _db.select('SELECT * FROM entities WHERE entity = ? AND id = ?', [t.name, id]);
    return rs.isEmpty ? null : _toRecord(rs.first);
  }

  List<LocalRecord> all(EntityType t) =>
      _db.select('SELECT * FROM entities WHERE entity = ?', [t.name]).map(_toRecord).toList();

  int get pendingCount => _db.select('SELECT COUNT(*) AS c FROM outbox').first['c'] as int;

  int get conflictCount =>
      _db.select('SELECT COUNT(*) AS c FROM entities WHERE conflict IS NOT NULL').first['c'] as int;

  List<OutboxOp> pendingOps() {
    final ops = _db
        .select('SELECT * FROM outbox ORDER BY created_at')
        .map((r) => OutboxOp(entityFromName(r['entity'] as String), r['id'] as String, r['op_id'] as String,
            r['rev'] as int, r['attempts'] as int, r['last_error'] as String?))
        .toList();
    ops.sort((a, b) => _priority[a.type]!.compareTo(_priority[b.type]!));
    return ops;
  }

  OutboxOp? opFor(EntityType t, String id) {
    final rs = _db.select('SELECT * FROM outbox WHERE entity = ? AND id = ?', [t.name, id]);
    if (rs.isEmpty) return null;
    final r = rs.first;
    return OutboxOp(t, id, r['op_id'] as String, r['rev'] as int, r['attempts'] as int, r['last_error'] as String?);
  }

  // ------------------------------------------------------------ écriture
  void _write(EntityType t, String id, Map<String, dynamic> data,
      {required Map<String, dynamic>? base,
      required Map<String, dynamic>? conflict,
      required bool dirty,
      required int rev}) {
    _db.execute('''
      INSERT INTO entities(entity, id, data, base, conflict, dirty, local_rev)
      VALUES (?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(entity, id) DO UPDATE SET data = excluded.data, base = excluded.base,
        conflict = excluded.conflict, dirty = excluded.dirty, local_rev = excluded.local_rev
    ''', [
      t.name,
      id,
      jsonEncode(data),
      base == null ? null : jsonEncode(base),
      conflict == null ? null : jsonEncode(conflict),
      dirty ? 1 : 0,
      rev,
    ]);
    if (t == EntityType.notes) _indexNote(id, data);
  }

  void _enqueue(EntityType t, String id, int rev) {
    _db.execute('''
      INSERT INTO outbox(entity, id, op_id, rev, attempts, last_error, created_at)
      VALUES (?, ?, ?, ?, 0, NULL, ?)
      ON CONFLICT(entity, id) DO UPDATE SET op_id = excluded.op_id, rev = excluded.rev,
        attempts = 0, last_error = NULL
    ''', [t.name, id, newId(), rev, nowIso()]);
  }

  void dropOp(EntityType t, String id) =>
      _db.execute('DELETE FROM outbox WHERE entity = ? AND id = ?', [t.name, id]);

  void recordFailure(EntityType t, String id, String error) => _db.execute(
      'UPDATE outbox SET attempts = attempts + 1, last_error = ? WHERE entity = ? AND id = ?',
      [error, t.name, id]);

  /// Nouvel identifiant d'opération (le contenu envoyé va changer).
  void renewOp(EntityType t, String id) =>
      _db.execute('UPDATE outbox SET op_id = ? WHERE entity = ? AND id = ?', [newId(), t.name, id]);

  /// Modification faite par l'utilisateur sur cet appareil.
  void saveLocal(EntityType t, Map<String, dynamic> row) {
    final id = row['id'].toString();
    transaction(() {
      final cur = get(t, id);
      final rev = (cur?.localRev ?? 0) + 1;
      _write(t, id, row, base: cur?.base, conflict: cur?.conflict, dirty: true, rev: rev);
      if (cur?.conflict == null) _enqueue(t, id, rev);
    });
    _emit(t);
  }

  /// Applique une ligne reçue du serveur (aucune modification locale en attente).
  void applyServerRow(EntityType t, Map<String, dynamic> row) {
    final id = row['id'].toString();
    transaction(() {
      final cur = get(t, id);
      _write(t, id, row, base: row, conflict: null, dirty: false, rev: cur?.localRev ?? 0);
      dropOp(t, id);
    });
    _emit(t);
  }

  /// Résultat d'une fusion automatique : à renvoyer au serveur.
  void saveMerged(EntityType t, Map<String, dynamic> merged, Map<String, dynamic> newBase) {
    final id = merged['id'].toString();
    transaction(() {
      final cur = get(t, id);
      final rev = (cur?.localRev ?? 0) + 1;
      _write(t, id, merged, base: newBase, conflict: null, dirty: true, rev: rev);
      _enqueue(t, id, rev);
    });
    _emit(t);
  }

  /// Conflit à arbitrer par l'utilisateur. La version locale est conservée
  /// telle quelle, la version serveur est mise de côté ; rien n'est envoyé
  /// tant que le conflit n'est pas résolu.
  void setConflict(EntityType t, String id, Map<String, dynamic> serverRow) {
    transaction(() {
      final cur = get(t, id)!;
      _write(t, id, cur.data, base: cur.base, conflict: serverRow, dirty: true, rev: cur.localRev);
      dropOp(t, id);
    });
    _emit(t);
  }

  /// Le serveur a accepté l'envoi correspondant à la révision [pushedRev].
  void ackPush(EntityType t, String id, Map<String, dynamic> serverRow, int pushedRev) {
    transaction(() {
      final cur = get(t, id);
      if (cur == null) return;
      final op = opFor(t, id);
      final unchanged = op == null || op.rev == pushedRev;
      if (unchanged) {
        _write(t, id, serverRow, base: serverRow, conflict: null, dirty: false, rev: cur.localRev);
        dropOp(t, id);
      } else {
        // L'utilisateur a encore modifié pendant l'envoi : on garde ses
        // modifications et on se base désormais sur la version acceptée.
        _write(t, id, cur.data, base: serverRow, conflict: cur.conflict, dirty: true, rev: cur.localRev);
      }
    });
    _emit(t);
  }

  /// Résolution de conflit : garder la version de cet appareil.
  void resolveKeepLocal(EntityType t, String id) {
    transaction(() {
      final cur = get(t, id)!;
      final server = cur.conflict ?? cur.base;
      final data = Map<String, dynamic>.from(cur.data)..['version'] = server?['version'];
      final rev = cur.localRev + 1;
      _write(t, id, data, base: server, conflict: null, dirty: true, rev: rev);
      _enqueue(t, id, rev);
    });
    _emit(t);
  }

  /// Résolution de conflit : garder la version du serveur.
  void resolveKeepServer(EntityType t, String id) {
    transaction(() {
      final cur = get(t, id)!;
      final server = cur.conflict ?? cur.base ?? cur.data;
      _write(t, id, server, base: server, conflict: null, dirty: false, rev: cur.localRev);
      dropOp(t, id);
    });
    _emit(t);
  }

  // ------------------------------------------------------------ fichiers
  void setLocalFile(String attachmentId, String path, {required bool uploaded}) => _db.execute('''
      INSERT INTO files(attachment_id, local_path, uploaded) VALUES (?, ?, ?)
      ON CONFLICT(attachment_id) DO UPDATE SET local_path = excluded.local_path, uploaded = excluded.uploaded
    ''', [attachmentId, path, uploaded ? 1 : 0]);

  ({String path, bool uploaded})? localFile(String attachmentId) {
    final rs = _db.select('SELECT * FROM files WHERE attachment_id = ?', [attachmentId]);
    if (rs.isEmpty) return null;
    return (path: rs.first['local_path'] as String, uploaded: (rs.first['uploaded'] as int) != 0);
  }

  void removeLocalFile(String attachmentId) =>
      _db.execute('DELETE FROM files WHERE attachment_id = ?', [attachmentId]);

  // ------------------------------------------------------------ recherche
  void _indexNote(String id, Map<String, dynamic> data) {
    _db.execute('DELETE FROM notes_fts WHERE id = ?', [id]);
    if (asBool(data['purged'])) return;
    _db.execute('INSERT INTO notes_fts(id, title, body) VALUES (?, ?, ?)',
        [id, (data['title'] ?? '').toString(), plainText(blocksFromContent(data['content']))]);
  }

  /// Recherche plein texte instantanée (titre et contenu, sans accents,
  /// préfixes acceptés : « élec » trouve « Électrotechnique »).
  List<String> search(String query) {
    final tokens = query
        .toLowerCase()
        .split(RegExp(r'[\s"\x27(){}\[\]^*:+\-]+'))
        .where((t) => t.isNotEmpty)
        .map((t) => '"$t"*')
        .toList();
    if (tokens.isEmpty) return [];
    try {
      return _db
          .select('SELECT id FROM notes_fts WHERE notes_fts MATCH ? ORDER BY bm25(notes_fts, 0, 4.0, 1.0)',
              [tokens.join(' ')])
          .map((r) => r['id'] as String)
          .toList();
    } on SqliteException {
      return [];
    }
  }

  // ------------------------------------------------------------ cycle de vie
  void close() {
    if (_closed) return;
    _closed = true;
    _changes.close();
    _db.dispose();
  }

  bool get isClosed => _closed;
}
