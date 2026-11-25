import 'dart:async';
import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import 'merge.dart' show jsonEq;
import 'models.dart';

/// Un élément tel que stocké sur l'appareil.
class StoredEntity {
  StoredEntity({
    required this.type,
    required this.id,
    required this.data,
    required this.rev,
    required this.seq,
    this.conflict,
  });

  final EntityType type;
  final String id;

  /// État courant affiché à l'utilisateur.
  final Map<String, dynamic> data;

  /// Numéro de révision de cet élément SUR CET APPAREIL : augmente à chaque
  /// changement de contenu. Sert à détecter les modifications concurrentes
  /// quand un autre appareil veut écrire ici.
  final int rev;

  /// Position dans le journal des changements de cet appareil : un autre
  /// appareil ne demande que ce qui a changé depuis son dernier passage.
  final int seq;

  /// Conflit non résolu : `{'row': version de l'autre appareil, 'peer': id, 'rev': n}`.
  final Map<String, dynamic>? conflict;

  Map<String, dynamic>? get conflictRow =>
      conflict == null ? null : Map<String, dynamic>.from(conflict!['row'] as Map);
}

/// Ce que cet appareil sait de l'état d'un élément chez un appareil associé.
class PeerState {
  PeerState(this.base, this.peerRev, this.dirty);

  /// Dernier contenu commun connu (ancêtre pour la fusion à trois voies).
  final Map<String, dynamic>? base;

  /// Révision de l'élément chez l'autre appareil lors du dernier échange.
  final int peerRev;

  /// Le contenu local diffère de [base] : à envoyer.
  final bool dirty;
}

/// Appareil associé.
class PeerInfo {
  PeerInfo({
    required this.id,
    required this.name,
    required this.platform,
    this.address,
    this.port,
    this.lastSeen,
    this.lastSync,
    this.pullCursor = 0,
    this.ackedSeq = 0,
    this.addedAt,
  });

  final String id;
  final String name;
  final String platform;
  final String? address;
  final int? port;
  final DateTime? lastSeen;
  final DateTime? lastSync;
  final int pullCursor;
  final int ackedSeq;
  final DateTime? addedAt;
}

/// Résultat d'une écriture demandée par un autre appareil.
class PushOutcome {
  PushOutcome.ok(this.rev)
      : ok = true,
        row = null;
  PushOutcome.conflict(this.row, this.rev) : ok = false;

  final bool ok;
  final int rev;
  final Map<String, dynamic>? row;
}

/// Base de données locale SQLite de l'appareil.
///
/// Toutes les modifications sont écrites ici immédiatement : l'application
/// fonctionne entièrement sans réseau. La « file d'attente » de
/// synchronisation est déduite de la base elle-même (tables `entities` et
/// `peer_state`), elle survit donc aux redémarrages.
class LocalStore {
  LocalStore._(this._db) {
    _migrate();
    _seq = int.tryParse(getMeta('seq') ?? '') ?? 0;
  }

  factory LocalStore.open(String path) {
    final db = sqlite3.open(path);
    try {
      return LocalStore._(db);
    } catch (_) {
      db.dispose(); // libère le fichier (Windows) pour pouvoir le restaurer
      rethrow;
    }
  }
  factory LocalStore.inMemory() => LocalStore._(sqlite3.openInMemory());

  /// Version du schéma de la base. Historique :
  ///  * 2 — Nothing Notes 2.0 (synchronisation locale) ;
  ///  * 3 — Nothing Notes 3.0 : ajout de la table `links` (index des liens
  ///    internes entre pages). Migration purement additive : aucune table
  ///    existante n'est modifiée, aucune ligne n'est réécrite.
  static const schemaVersion = 3;

  final Database _db;

  /// Accès bas niveau, réservé à la sauvegarde et à la vérification des données.
  Database get database => _db;
  final _changes = StreamController<EntityType>.broadcast();
  int _txDepth = 0;
  int _seq = 0;
  bool _closed = false;

  /// Durée minimale entre deux instantanés d'historique pour des frappes successives.
  Duration historyInterval = const Duration(minutes: 2);

  /// Émis après chaque modification (locale ou reçue d'un autre appareil).
  Stream<EntityType> get changes => _changes.stream;

  void _migrate() {
    _db.execute('PRAGMA journal_mode = WAL;');
    _db.execute('PRAGMA synchronous = FULL;');
    if (_db.userVersion < 2) {
      _db.execute('''
        CREATE TABLE IF NOT EXISTS entities (
          entity   TEXT NOT NULL,
          id       TEXT NOT NULL,
          data     TEXT NOT NULL,
          rev      INTEGER NOT NULL,
          seq      INTEGER NOT NULL,
          conflict TEXT,
          PRIMARY KEY (entity, id)
        );
        CREATE INDEX IF NOT EXISTS entities_seq ON entities (seq);
        CREATE TABLE IF NOT EXISTS peers (
          id          TEXT PRIMARY KEY,
          name        TEXT NOT NULL DEFAULT '',
          platform    TEXT NOT NULL DEFAULT '',
          address     TEXT,
          port        INTEGER,
          last_seen   TEXT,
          last_sync   TEXT,
          pull_cursor INTEGER NOT NULL DEFAULT 0,
          acked_seq   INTEGER NOT NULL DEFAULT 0,
          added_at    TEXT
        );
        CREATE TABLE IF NOT EXISTS peer_state (
          peer_id  TEXT NOT NULL,
          entity   TEXT NOT NULL,
          id       TEXT NOT NULL,
          base     TEXT,
          peer_rev INTEGER NOT NULL DEFAULT 0,
          dirty    INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (peer_id, entity, id)
        );
        CREATE TABLE IF NOT EXISTS history (
          hid      INTEGER PRIMARY KEY AUTOINCREMENT,
          note_id  TEXT NOT NULL,
          title    TEXT NOT NULL,
          content  TEXT NOT NULL,
          reason   TEXT NOT NULL,
          saved_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS history_note ON history (note_id, hid);
        CREATE TABLE IF NOT EXISTS files (
          attachment_id TEXT PRIMARY KEY,
          local_path    TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
        CREATE VIRTUAL TABLE IF NOT EXISTS notes_fts USING fts5(
          id UNINDEXED, title, body, tokenize = 'unicode61 remove_diacritics 2'
        );
      ''');
      _db.userVersion = 2;
    }
    if (_db.userVersion < 3) {
      _db.execute('BEGIN IMMEDIATE');
      try {
        _db.execute('''
          CREATE TABLE IF NOT EXISTS links (
            src TEXT NOT NULL,
            dst TEXT NOT NULL,
            PRIMARY KEY (src, dst)
          );
          CREATE INDEX IF NOT EXISTS links_dst ON links (dst);
        ''');
        // Index dérivé, calculé à partir des notes (lues, jamais réécrites).
        for (final r in _db.select("SELECT id, data FROM entities WHERE entity = 'notes'")) {
          _indexLinks(r['id'] as String, _decode(r['data'])!);
        }
        _db.userVersion = 3;
        _db.execute('COMMIT');
      } catch (_) {
        _db.execute('ROLLBACK');
        rethrow;
      }
    }
  }

  // ------------------------------------------------------------ utilitaires
  T transaction<T>(T Function() body) {
    if (_txDepth > 0) return body();
    _db.execute('BEGIN IMMEDIATE');
    _txDepth++;
    final seqBefore = _seq;
    try {
      final r = body();
      _txDepth--;
      _db.execute('COMMIT');
      return r;
    } catch (_) {
      _txDepth--;
      _seq = seqBefore;
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

  /// Nom affiché sur les autres appareils.
  String get deviceName => getMeta('device_name') ?? 'Appareil';
  set deviceName(String name) => setMeta('device_name', name.trim().isEmpty ? 'Appareil' : name.trim());

  int _nextSeq() {
    _seq++;
    setMeta('seq', '$_seq');
    return _seq;
  }

  /// Position courante du journal des changements.
  int get currentSeq => _seq;

  /// Entre deux appareils associés, celui dont l'identifiant est le plus
  /// petit pilote la synchronisation (l'autre répond).
  bool isDriverFor(String peerId) => deviceId.compareTo(peerId) < 0;

  // ------------------------------------------------------------ lecture
  StoredEntity _toEntity(Row r) => StoredEntity(
        type: entityFromName(r['entity'] as String),
        id: r['id'] as String,
        data: _decode(r['data'])!,
        rev: r['rev'] as int,
        seq: r['seq'] as int,
        conflict: _decode(r['conflict']),
      );

  StoredEntity? get(EntityType t, String id) {
    final rs = _db.select('SELECT * FROM entities WHERE entity = ? AND id = ?', [t.name, id]);
    return rs.isEmpty ? null : _toEntity(rs.first);
  }

  List<StoredEntity> all(EntityType t) =>
      _db.select('SELECT * FROM entities WHERE entity = ?', [t.name]).map(_toEntity).toList();

  /// Éléments modifiés après la position [afterSeq] du journal (toutes
  /// catégories confondues), dans l'ordre.
  List<StoredEntity> changedSince(int afterSeq, int limit) => _db
      .select('SELECT * FROM entities WHERE seq > ? ORDER BY seq LIMIT ?', [afterSeq, limit])
      .map(_toEntity)
      .toList();

  int conflictCount() =>
      _db.select('SELECT COUNT(*) AS c FROM entities WHERE conflict IS NOT NULL').first['c'] as int;

  // ------------------------------------------------------------ écriture
  void _write(EntityType t, String id, Map<String, dynamic> data, int rev, int seq, Map<String, dynamic>? conflict) {
    _db.execute('''
      INSERT INTO entities(entity, id, data, rev, seq, conflict) VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(entity, id) DO UPDATE SET data = excluded.data, rev = excluded.rev,
        seq = excluded.seq, conflict = excluded.conflict
    ''', [t.name, id, jsonEncode(data), rev, seq, conflict == null ? null : jsonEncode(conflict)]);
    if (t == EntityType.notes) _indexNote(id, data);
  }

  /// Enregistre un nouveau contenu : nouvelle révision, nouvelle position
  /// dans le journal, élément marqué « à transmettre » pour chaque appareil.
  StoredEntity _put(EntityType t, Map<String, dynamic> row,
      {required String reason, bool clearConflict = false, String? clearConflictFromPeer}) {
    final id = row['id'].toString();
    final cur = get(t, id);
    var conflict = cur?.conflict;
    if (clearConflict || (clearConflictFromPeer != null && conflict?['peer'] == clearConflictFromPeer)) {
      conflict = null;
    }
    final rev = (cur?.rev ?? 0) + 1;
    final seq = _nextSeq();
    _write(t, id, row, rev, seq, conflict);
    _db.execute('UPDATE peer_state SET dirty = 1 WHERE entity = ? AND id = ?', [t.name, id]);
    if (t == EntityType.notes && cur != null) _snapshot(cur.data, row, reason);
    return StoredEntity(type: t, id: id, data: row, rev: rev, seq: seq, conflict: conflict);
  }

  /// Modification faite par l'utilisateur sur cet appareil.
  void saveLocal(EntityType t, Map<String, dynamic> row, {String reason = 'edit'}) {
    transaction(() => _put(t, row, reason: reason));
    _emit(t);
  }

  // ------------------------------------------------------------ côté « répondeur »
  /// Un appareil associé demande à écrire [row]. L'écriture n'est acceptée
  /// que si elle se base sur la révision actuelle ([expectedRev]) : sinon la
  /// version locale est renvoyée et rien n'est écrasé.
  PushOutcome applyFromPeer(EntityType t, Map<String, dynamic> row, int expectedRev) {
    final out = transaction(() {
      final cur = get(t, row['id'].toString());
      final curRev = cur?.rev ?? 0;
      // Même contenu (par exemple un renvoi après une réponse perdue) : rien à faire.
      if (cur != null && jsonEq(cur.data, row)) return PushOutcome.ok(curRev);
      if (curRev != expectedRev) return PushOutcome.conflict(cur?.data, curRev);
      return PushOutcome.ok(_put(t, row, reason: 'sync').rev);
    });
    if (out.ok) _emit(t);
    return out;
  }

  // ------------------------------------------------------------ côté « pilote »
  PeerState? peerState(String peerId, EntityType t, String id) {
    final rs = _db.select(
        'SELECT base, peer_rev, dirty FROM peer_state WHERE peer_id = ? AND entity = ? AND id = ?',
        [peerId, t.name, id]);
    if (rs.isEmpty) return null;
    final r = rs.first;
    return PeerState(_decode(r['base']), r['peer_rev'] as int, (r['dirty'] as int) != 0);
  }

  void _setPeerState(String peerId, EntityType t, String id,
      {required Map<String, dynamic>? base, required int peerRev, required bool dirty}) {
    _db.execute('''
      INSERT INTO peer_state(peer_id, entity, id, base, peer_rev, dirty) VALUES (?, ?, ?, ?, ?, ?)
      ON CONFLICT(peer_id, entity, id) DO UPDATE SET base = excluded.base,
        peer_rev = excluded.peer_rev, dirty = excluded.dirty
    ''', [peerId, t.name, id, base == null ? null : jsonEncode(base), peerRev, dirty ? 1 : 0]);
  }

  /// Version reçue d'un appareil alors que rien n'a changé ici : on l'adopte.
  void applyPulled(String peerId, EntityType t, Map<String, dynamic> row, int peerRev) {
    final id = row['id'].toString();
    transaction(() {
      _put(t, row, reason: 'sync');
      _setPeerState(peerId, t, id, base: row, peerRev: peerRev, dirty: false);
    });
    _emit(t);
  }

  /// Les deux appareils ont déjà le même contenu.
  void markEqual(String peerId, EntityType t, String id, Map<String, dynamic> row, int peerRev) {
    var cleared = false;
    transaction(() {
      _setPeerState(peerId, t, id, base: row, peerRev: peerRev, dirty: false);
      final cur = get(t, id);
      if (cur?.conflict != null && cur!.conflict!['peer'] == peerId) {
        _db.execute('UPDATE entities SET conflict = NULL WHERE entity = ? AND id = ?', [t.name, id]);
        cleared = true;
      }
    });
    if (cleared) _emit(t);
  }

  /// Résultat d'une fusion automatique : enregistré ici, puis renvoyé à l'autre appareil.
  void saveMerged(String peerId, EntityType t, Map<String, dynamic> merged, Map<String, dynamic> remoteRow,
      int peerRev) {
    final id = merged['id'].toString();
    transaction(() {
      _put(t, merged, reason: 'merge', clearConflictFromPeer: peerId);
      _setPeerState(peerId, t, id, base: remoteRow, peerRev: peerRev, dirty: !jsonEq(merged, remoteRow));
    });
    _emit(t);
  }

  /// Conflit à arbitrer par l'utilisateur. La version locale reste intacte,
  /// celle de l'autre appareil est mise de côté ; rien n'est envoyé pour cet
  /// élément tant que le conflit n'est pas résolu.
  void setConflict(String peerId, EntityType t, String id, Map<String, dynamic> remoteRow, int peerRev) {
    _db.execute('UPDATE entities SET conflict = ? WHERE entity = ? AND id = ?', [
      jsonEncode({'row': remoteRow, 'peer': peerId, 'rev': peerRev}),
      t.name,
      id,
    ]);
    _emit(t);
  }

  /// L'autre appareil a accepté l'envoi de [sentData] (révision locale [sentRev]).
  void ackPush(String peerId, EntityType t, String id, Map<String, dynamic> sentData, int peerRev, int sentRev) {
    final cur = get(t, id);
    // Si l'utilisateur a encore modifié pendant l'envoi, l'élément reste à transmettre.
    _setPeerState(peerId, t, id, base: sentData, peerRev: peerRev, dirty: cur != null && cur.rev != sentRev);
  }

  /// Oublie ce que l'on savait de l'élément chez [peerId] (il ne l'a plus).
  void resetPeerState(String peerId, EntityType t, String id) =>
      _db.execute('DELETE FROM peer_state WHERE peer_id = ? AND entity = ? AND id = ?', [peerId, t.name, id]);

  /// Éléments à envoyer à [peerId] : jamais échangés avec lui, ou modifiés depuis.
  List<StoredEntity> pushCandidates(String peerId, int limit) => _db.select('''
      SELECT e.* FROM entities e
      LEFT JOIN peer_state ps ON ps.peer_id = ? AND ps.entity = e.entity AND ps.id = e.id
      WHERE (ps.id IS NULL OR ps.dirty = 1) AND e.conflict IS NULL
      ORDER BY CASE e.entity WHEN 'folders' THEN 0 WHEN 'tags' THEN 1 WHEN 'attachments' THEN 2 ELSE 3 END, e.seq
      LIMIT ?
    ''', [peerId, limit]).map(_toEntity).toList();

  /// Résolution de conflit : garder la version de cet appareil.
  void resolveKeepLocal(EntityType t, String id) {
    transaction(() {
      final cur = get(t, id);
      final c = cur?.conflict;
      if (c == null) return;
      _setPeerState(c['peer'].toString(), t, id,
          base: Map<String, dynamic>.from(c['row'] as Map), peerRev: asInt(c['rev']), dirty: true);
      _db.execute('UPDATE entities SET conflict = NULL WHERE entity = ? AND id = ?', [t.name, id]);
    });
    _emit(t);
  }

  /// Résolution de conflit : garder la version de l'autre appareil. La
  /// version locale écartée reste dans l'historique.
  void resolveKeepRemote(EntityType t, String id) {
    transaction(() {
      final cur = get(t, id);
      final c = cur?.conflict;
      if (c == null) return;
      final row = Map<String, dynamic>.from(c['row'] as Map);
      _put(t, row, reason: 'conflict', clearConflict: true);
      _setPeerState(c['peer'].toString(), t, id, base: row, peerRev: asInt(c['rev']), dirty: false);
    });
    _emit(t);
  }

  // ------------------------------------------------------------ en attente
  int _pendingFor(PeerInfo p) {
    if (isDriverFor(p.id)) {
      return _db.select('''
        SELECT COUNT(*) AS c FROM entities e
        LEFT JOIN peer_state ps ON ps.peer_id = ? AND ps.entity = e.entity AND ps.id = e.id
        WHERE (ps.id IS NULL OR ps.dirty = 1) AND e.conflict IS NULL
      ''', [p.id]).first['c'] as int;
    }
    return _db.select('SELECT COUNT(*) AS c FROM entities WHERE seq > ?', [p.ackedSeq]).first['c'] as int;
  }

  /// Nombre de modifications pas encore transmises (à l'appareil le plus en retard).
  int pendingCount() {
    var max = 0;
    for (final p in peers()) {
      final n = _pendingFor(p);
      if (n > max) max = n;
    }
    return max;
  }

  /// Identifiants des éléments pas encore transmis à au moins un appareil associé.
  Set<String> unsyncedIds(EntityType t) {
    final out = <String>{};
    for (final p in peers()) {
      final rs = isDriverFor(p.id)
          ? _db.select('''
              SELECT e.id FROM entities e
              LEFT JOIN peer_state ps ON ps.peer_id = ? AND ps.entity = e.entity AND ps.id = e.id
              WHERE e.entity = ? AND (ps.id IS NULL OR ps.dirty = 1)
            ''', [p.id, t.name])
          : _db.select('SELECT id FROM entities WHERE entity = ? AND seq > ?', [t.name, p.ackedSeq]);
      for (final r in rs) {
        out.add(r['id'] as String);
      }
    }
    return out;
  }

  bool isUnsynced(EntityType t, String id) {
    final e = get(t, id);
    if (e == null) return false;
    for (final p in peers()) {
      if (isDriverFor(p.id)) {
        final ps = peerState(p.id, t, id);
        if (ps == null || ps.dirty) return true;
      } else if (e.seq > p.ackedSeq) {
        return true;
      }
    }
    return false;
  }

  // ------------------------------------------------------------ appareils associés
  PeerInfo _toPeer(Row r) => PeerInfo(
        id: r['id'] as String,
        name: (r['name'] ?? '') as String,
        platform: (r['platform'] ?? '') as String,
        address: r['address'] as String?,
        port: r['port'] as int?,
        lastSeen: parseDate(r['last_seen']),
        lastSync: parseDate(r['last_sync']),
        pullCursor: r['pull_cursor'] as int,
        ackedSeq: r['acked_seq'] as int,
        addedAt: parseDate(r['added_at']),
      );

  List<PeerInfo> peers() => _db.select('SELECT * FROM peers ORDER BY added_at').map(_toPeer).toList();

  PeerInfo? peer(String id) {
    final rs = _db.select('SELECT * FROM peers WHERE id = ?', [id]);
    return rs.isEmpty ? null : _toPeer(rs.first);
  }

  /// Enregistre un appareil nouvellement associé (ou réassocié : on repart de zéro avec lui).
  void addPeer(String id, {required String name, required String platform, String? address, int? port}) {
    transaction(() {
      _db.execute('DELETE FROM peer_state WHERE peer_id = ?', [id]);
      _db.execute('''
        INSERT INTO peers(id, name, platform, address, port, last_seen, pull_cursor, acked_seq, added_at)
        VALUES (?, ?, ?, ?, ?, ?, 0, 0, ?)
        ON CONFLICT(id) DO UPDATE SET name = excluded.name, platform = excluded.platform,
          address = excluded.address, port = excluded.port, last_seen = excluded.last_seen,
          pull_cursor = 0, acked_seq = 0
      ''', [id, name, platform, address, port, nowIso(), nowIso()]);
    });
    _emit(EntityType.notes);
  }

  void removePeer(String id) {
    transaction(() {
      _db.execute('DELETE FROM peers WHERE id = ?', [id]);
      _db.execute('DELETE FROM peer_state WHERE peer_id = ?', [id]);
    });
    _emit(EntityType.notes);
  }

  void touchPeer(String id, {String? address, int? port, String? name, String? platform}) {
    _db.execute('''
      UPDATE peers SET last_seen = ?, address = COALESCE(?, address), port = COALESCE(?, port),
        name = COALESCE(?, name), platform = COALESCE(?, platform) WHERE id = ?
    ''', [nowIso(), address, port, name, platform, id]);
  }

  int pullCursor(String peerId) => peer(peerId)?.pullCursor ?? 0;

  void setPullCursor(String peerId, int seq) =>
      _db.execute('UPDATE peers SET pull_cursor = ? WHERE id = ?', [seq, peerId]);

  /// L'appareil [peerId] confirme avoir reçu notre journal jusqu'à [seq].
  void setAckedSeq(String peerId, int seq) =>
      _db.execute('UPDATE peers SET acked_seq = MAX(acked_seq, ?), last_sync = ? WHERE id = ?', [seq, nowIso(), peerId]);

  void markSynced(String peerId) =>
      _db.execute('UPDATE peers SET last_sync = ? WHERE id = ?', [nowIso(), peerId]);

  // ------------------------------------------------------------ historique des versions
  void _snapshot(Map<String, dynamic> old, Map<String, dynamic> next, String reason) {
    final noteId = old['id'].toString();
    if (asBool(next['purged'])) {
      _db.execute('DELETE FROM history WHERE note_id = ?', [noteId]);
      return;
    }
    if (asBool(old['purged'])) return;
    if (jsonEq(old['title'], next['title']) && jsonEq(old['content'], next['content'])) return;
    if (reason == 'edit') {
      // Frappe continue : un seul instantané par intervalle, pris avant la série de modifications.
      final last = _db.select('SELECT saved_at FROM history WHERE note_id = ? ORDER BY hid DESC LIMIT 1', [noteId]);
      if (last.isNotEmpty) {
        final at = parseDate(last.first['saved_at']);
        if (at != null && DateTime.now().toUtc().difference(at) < historyInterval) return;
      }
    }
    _db.execute('INSERT INTO history(note_id, title, content, reason, saved_at) VALUES (?, ?, ?, ?, ?)', [
      noteId,
      (old['title'] ?? '').toString(),
      jsonEncode(old['content'] ?? {'blocks': []}),
      reason,
      nowIso(),
    ]);
    _db.execute('''
      DELETE FROM history WHERE note_id = ? AND hid NOT IN
        (SELECT hid FROM history WHERE note_id = ? ORDER BY hid DESC LIMIT 50)
    ''', [noteId, noteId]);
  }

  /// Versions précédentes d'une note, de la plus récente à la plus ancienne.
  List<Map<String, dynamic>> history(String noteId) => _db
      .select('SELECT * FROM history WHERE note_id = ? ORDER BY hid DESC', [noteId])
      .map((r) => <String, dynamic>{
            'title': r['title'],
            'content': jsonDecode(r['content'] as String),
            'reason': r['reason'],
            'saved_at': r['saved_at'],
          })
      .toList();

  // ------------------------------------------------------------ fichiers
  void setLocalFile(String attachmentId, String path) => _db.execute('''
      INSERT INTO files(attachment_id, local_path) VALUES (?, ?)
      ON CONFLICT(attachment_id) DO UPDATE SET local_path = excluded.local_path
    ''', [attachmentId, path]);

  String? localFile(String attachmentId) {
    final rs = _db.select('SELECT local_path FROM files WHERE attachment_id = ?', [attachmentId]);
    return rs.isEmpty ? null : rs.first['local_path'] as String;
  }

  void removeLocalFile(String attachmentId) =>
      _db.execute('DELETE FROM files WHERE attachment_id = ?', [attachmentId]);

  /// Un fichier vient d'arriver : l'interface doit se rafraîchir.
  void notifyFiles() => _emit(EntityType.attachments);

  // ------------------------------------------------------------ recherche
  void _indexNote(String id, Map<String, dynamic> data) {
    _db.execute('DELETE FROM notes_fts WHERE id = ?', [id]);
    _indexLinks(id, data);
    if (asBool(data['purged'])) return;
    final body = StringBuffer(plainText(blocksFromContent(data['content'])));
    // Valeurs des propriétés (entrées de base de données) : trouvables par la recherche.
    final props = data['props'];
    if (props is Map) {
      for (final v in props.values) {
        if (v == null || v is bool) continue;
        body.write('\n${v is List ? v.join(' ') : v}');
      }
    }
    _db.execute('INSERT INTO notes_fts(id, title, body) VALUES (?, ?, ?)',
        [id, (data['title'] ?? '').toString(), body.toString()]);
  }

  void _indexLinks(String id, Map<String, dynamic> data) {
    _db.execute('DELETE FROM links WHERE src = ?', [id]);
    if (asBool(data['purged'])) return;
    for (final dst in linkedPageIds(blocksFromContent(data['content']))) {
      if (dst != id) _db.execute('INSERT OR IGNORE INTO links(src, dst) VALUES (?, ?)', [id, dst]);
    }
  }

  /// Pages qui contiennent un lien vers [id] (rétroliens).
  List<String> backlinks(String id) =>
      _db.select('SELECT src FROM links WHERE dst = ?', [id]).map((r) => r['src'] as String).toList();

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
