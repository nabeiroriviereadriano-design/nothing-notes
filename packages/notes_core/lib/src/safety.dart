import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'local_store.dart';

/// La migration a été arrêtée pour protéger les données. La base d'origine
/// est intacte (ou restaurée depuis la sauvegarde).
class MigrationAborted implements Exception {
  MigrationAborted(this.message, {this.backupPath});
  final String message;
  final String? backupPath;
  @override
  String toString() => message;
}

/// Empreinte complète des données de l'utilisateur : chaque note, dossier,
/// étiquette et pièce jointe (contenu exact), les fichiers, l'historique, les
/// appareils associés et l'identité de l'appareil. Deux empreintes égales
/// garantissent qu'aucune donnée n'a été perdue ni modifiée.
class DataFingerprint {
  DataFingerprint._(this.counts, this.digest);

  /// Nombre d'éléments par catégorie (pour les messages et les tests).
  final Map<String, int> counts;

  /// SHA-256 de l'ensemble des données, dans un ordre stable.
  final String digest;

  static bool _hasTable(Database db, String name) =>
      db.select("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", [name]).isNotEmpty;

  factory DataFingerprint.of(Database db) {
    final counts = <String, int>{};
    final sink = <List<int>>[];
    void add(String s) => sink.add(utf8.encode('$s\u0000'));

    void table(String label, String sql) {
      final name = sql.split(' FROM ')[1].split(' ').first;
      if (!_hasTable(db, name)) {
        counts[label] = 0;
        add('$label:absent');
        return;
      }
      var n = 0;
      for (final r in db.select(sql)) {
        n++;
        add([label, ...r.values.map((v) => v?.toString() ?? '∅')].join('|'));
      }
      counts[label] = n;
    }

    for (final t in ['notes', 'folders', 'tags', 'attachments']) {
      table(t, "SELECT id, data, rev, seq, conflict FROM entities WHERE entity = '$t' ORDER BY id");
    }
    table('fichiers', 'SELECT attachment_id, local_path FROM files ORDER BY attachment_id');
    table('historique', 'SELECT hid, note_id, title, content, reason, saved_at FROM history ORDER BY hid');
    table('appareils', 'SELECT id, name, platform, pull_cursor, acked_seq FROM peers ORDER BY id');
    table('etat_synchro', 'SELECT peer_id, entity, id, base, peer_rev, dirty FROM peer_state ORDER BY peer_id, entity, id');
    table('meta', "SELECT key, value FROM meta WHERE key IN ('device_id', 'device_name', 'seq') ORDER BY key");

    final out = crypto.sha256.convert(sink.expand((b) => b).toList()).toString();
    return DataFingerprint._(counts, out);
  }

  @override
  bool operator ==(Object other) => other is DataFingerprint && other.digest == digest;

  @override
  int get hashCode => digest.hashCode;

  String describe() => [
        '${counts['notes']} notes',
        '${counts['folders']} dossiers',
        '${counts['tags']} étiquettes',
        '${counts['attachments']} pièces jointes',
        '${counts['historique']} versions d\'historique',
      ].join(', ');
}

/// Une sauvegarde de la base.
class BackupInfo {
  BackupInfo(this.path, this.createdAt, this.sizeBytes, this.label);
  final String path;
  final DateTime createdAt;
  final int sizeBytes;

  /// 'migration', 'manuelle', 'avant-restauration'
  final String label;
}

/// Sauvegardes et migrations sûres de la base de l'application.
class DataSafety {
  DataSafety(this.backupsDir, {this.keepAutomatic = 5});

  final String backupsDir;

  /// Nombre de sauvegardes automatiques conservées (les plus récentes).
  final int keepAutomatic;

  static String _stamp(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}-${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }

  static bool _integrityOk(Database db) {
    final rs = db.select('PRAGMA integrity_check');
    return rs.length == 1 && rs.first.values.first == 'ok';
  }

  /// Copie cohérente de la base (inclut les écritures encore dans le
  /// journal WAL), vérifiée : intégrité SQLite et empreinte identique.
  String _backup(Database db, String label, {DataFingerprint? expected}) {
    Directory(backupsDir).createSync(recursive: true);
    var path = p.join(backupsDir, 'notes-$label-${_stamp(DateTime.now())}.db');
    var i = 2;
    while (File(path).existsSync()) {
      path = p.join(backupsDir, 'notes-$label-${_stamp(DateTime.now())}-${i++}.db');
    }
    db.execute('VACUUM INTO ?', [path]);
    final copy = sqlite3.open(path, mode: OpenMode.readOnly);
    try {
      if (!_integrityOk(copy)) throw MigrationAborted('La sauvegarde créée est illisible.');
      final fp = expected ?? DataFingerprint.of(db);
      if (DataFingerprint.of(copy) != fp) {
        throw MigrationAborted('La sauvegarde ne correspond pas exactement aux données.');
      }
    } catch (_) {
      copy.dispose();
      try {
        File(path).deleteSync();
      } catch (_) {}
      rethrow;
    }
    copy.dispose();
    return path;
  }

  /// Ouvre la base de l'application. Si une migration est nécessaire :
  ///
  /// 1. vérifie l'intégrité de la base ;
  /// 2. calcule l'empreinte complète des données ;
  /// 3. crée une sauvegarde et vérifie qu'elle est lisible et identique ;
  /// 4. migre ;
  /// 5. vérifie que l'empreinte des données est restée identique.
  ///
  /// Au moindre écart, la base d'origine est remise en place depuis la
  /// sauvegarde et [MigrationAborted] est levée : l'application ne démarre
  /// pas sur des données douteuses.
  LocalStore openStore(String dbPath) {
    if (!File(dbPath).existsSync()) return LocalStore.open(dbPath); // première installation

    final raw = sqlite3.open(dbPath);
    final int version;
    final DataFingerprint before;
    final String backup;
    try {
      version = raw.userVersion;
      if (version >= LocalStore.schemaVersion) {
        raw.dispose();
        return LocalStore.open(dbPath);
      }
      if (version > 0 && !_integrityOk(raw)) {
        throw MigrationAborted('La base de notes est endommagée : aucune migration n\'a été tentée.');
      }
      before = DataFingerprint.of(raw);
      backup = _backup(raw, 'v$version-avant-migration', expected: before);
    } finally {
      try {
        raw.dispose();
      } catch (_) {}
    }

    LocalStore? store;
    try {
      store = LocalStore.open(dbPath);
      final after = DataFingerprint.of(store.database);
      if (after != before) {
        throw MigrationAborted('Vérification après migration : les données ne sont pas identiques.', backupPath: backup);
      }
      _prune();
      return store;
    } catch (e) {
      store?.close();
      restoreFile(backup, dbPath);
      if (e is MigrationAborted) {
        throw MigrationAborted('${e.message} La base d\'origine a été remise en place.', backupPath: backup);
      }
      throw MigrationAborted('Migration impossible ($e). La base d\'origine a été remise en place.', backupPath: backup);
    }
  }

  /// Sauvegarde manuelle de la base ouverte.
  BackupInfo backupNow(LocalStore store, {String label = 'manuelle'}) {
    final path = _backup(store.database, label);
    _prune();
    return info(path)!;
  }

  BackupInfo? info(String path) {
    final f = File(path);
    if (!f.existsSync()) return null;
    final name = p.basenameWithoutExtension(path);
    final m = RegExp(r'^notes-(.+)-(\d{8})-(\d{6})').firstMatch(name);
    final label = m?.group(1) ?? 'sauvegarde';
    return BackupInfo(path, f.lastModifiedSync(), f.lengthSync(), label);
  }

  /// Sauvegardes disponibles, de la plus récente à la plus ancienne.
  List<BackupInfo> list() {
    final dir = Directory(backupsDir);
    if (!dir.existsSync()) return [];
    final out = [
      for (final f in dir.listSync().whereType<File>())
        if (f.path.endsWith('.db')) info(f.path)
    ].whereType<BackupInfo>().toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return out;
  }

  /// Contenu d'une sauvegarde (pour l'afficher avant de la restaurer).
  DataFingerprint inspect(String path) {
    final db = sqlite3.open(path, mode: OpenMode.readOnly);
    try {
      return DataFingerprint.of(db);
    } finally {
      db.dispose();
    }
  }

  /// Remplace la base par une sauvegarde. La base doit être FERMÉE. La base
  /// actuelle est d'abord elle-même sauvegardée (« avant-restauration »).
  void restore(String backupPath, String dbPath) {
    final check = sqlite3.open(backupPath, mode: OpenMode.readOnly);
    try {
      if (!_integrityOk(check)) throw MigrationAborted('Cette sauvegarde est illisible.');
    } finally {
      check.dispose();
    }
    var previousSeq = 0;
    if (File(dbPath).existsSync()) {
      final current = sqlite3.open(dbPath);
      try {
        _backup(current, 'avant-restauration');
        previousSeq = _seqOf(current);
      } finally {
        current.dispose();
      }
    }
    restoreFile(backupPath, dbPath);
    // Le compteur du journal des changements ne doit jamais reculer : sinon les
    // appareils associés, qui ont déjà lu jusqu'à ce numéro, ignoreraient les
    // prochaines modifications faites ici.
    final db = sqlite3.open(dbPath);
    try {
      if (_seqOf(db) < previousSeq) {
        db.execute("INSERT INTO meta(key, value) VALUES ('seq', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            ['$previousSeq']);
      }
    } finally {
      db.dispose();
    }
    _prune();
  }

  static int _seqOf(Database db) {
    try {
      final rs = db.select("SELECT value FROM meta WHERE key = 'seq'");
      return rs.isEmpty ? 0 : int.tryParse('${rs.first.values.first}') ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// Copie brute d'une sauvegarde à la place de la base (journal WAL compris).
  static void restoreFile(String backupPath, String dbPath) {
    for (final suffix in ['-wal', '-shm']) {
      final f = File('$dbPath$suffix');
      if (f.existsSync()) f.deleteSync();
    }
    final tmp = File('$dbPath.restauration');
    File(backupPath).copySync(tmp.path);
    tmp.renameSync(dbPath);
  }

  void _prune() {
    // Les sauvegardes d'avant migration et les sauvegardes manuelles ne sont
    // jamais supprimées automatiquement.
    final auto = list().where((b) => b.label == 'avant-restauration').toList();
    for (final b in auto.skip(keepAutomatic)) {
      try {
        File(b.path).deleteSync();
      } catch (_) {}
    }
  }
}
