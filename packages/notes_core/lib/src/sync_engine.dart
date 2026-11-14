import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import 'local_store.dart';
import 'merge.dart';
import 'models.dart';
import 'remote.dart';

enum SyncState { synced, syncing, offline, pending, error }

class SyncStatus {
  const SyncStatus(this.state, {this.pending = 0, this.conflicts = 0, this.message, this.lastSync});

  final SyncState state;
  final int pending;
  final int conflicts;
  final String? message;
  final DateTime? lastSync;

  String get label {
    switch (state) {
      case SyncState.synced:
        return 'Synchronisé';
      case SyncState.syncing:
        return 'Synchronisation…';
      case SyncState.offline:
        return pending > 0 ? 'Hors ligne · $pending en attente' : 'Hors ligne';
      case SyncState.pending:
        return '$pending modification${pending > 1 ? 's' : ''} en attente';
      case SyncState.error:
        return 'Erreur de synchronisation';
    }
  }
}

/// Moteur de synchronisation bidirectionnelle.
///
/// 1. chaque modification est d'abord écrite dans la base locale et ajoutée à
///    la file persistante (voir [LocalStore]) ;
/// 2. le moteur envoie la file au serveur (avec la version de base pour
///    détecter les conflits et un identifiant d'opération anti-doublon) ;
/// 3. il récupère uniquement ce qui a changé depuis son dernier curseur,
///    page par page, en sauvegardant le curseur après chaque page (reprise
///    après interruption) ;
/// 4. les conflits sont fusionnés automatiquement quand c'est sans risque,
///    sinon ils sont présentés à l'utilisateur ;
/// 5. il se relance automatiquement : après une modification locale, sur
///    notification temps réel du serveur, périodiquement, et avec un délai
///    croissant quand le réseau est absent.
class SyncEngine {
  SyncEngine({
    required this.store,
    required this.remote,
    required this.filesDir,
    this.pollInterval = const Duration(seconds: 60),
    this.debounce = const Duration(milliseconds: 800),
    this.pageSize = 500,
    this.autoDownloadMaxBytes = 25 * 1024 * 1024,
  });

  final LocalStore store;
  final RemoteApi remote;
  final String filesDir;
  final Duration pollInterval;
  final Duration debounce;
  final int pageSize;

  /// Taille maximale des images téléchargées automatiquement ; les autres
  /// fichiers sont téléchargés à la demande (économie de données mobiles).
  final int autoDownloadMaxBytes;

  final _status = StreamController<SyncStatus>.broadcast();
  SyncStatus _current = const SyncStatus(SyncState.pending);
  DateTime? _lastSync;
  Future<void>? _running;
  bool _again = false;
  bool _stopped = true;
  int _failures = 0;
  Timer? _poll, _retry, _debounce;
  StreamSubscription<void>? _remoteSub;

  Stream<SyncStatus> get statusStream => _status.stream;
  SyncStatus get status => _current;

  void _set(SyncState s, {String? message}) {
    _current = SyncStatus(s,
        pending: store.isClosed ? 0 : store.pendingCount,
        conflicts: store.isClosed ? 0 : store.conflictCount,
        message: message,
        lastSync: _lastSync);
    if (!_status.isClosed) _status.add(_current);
  }

  void start() {
    if (!_stopped) return;
    _stopped = false;
    _remoteSub = remote.changes.listen((_) => requestSync(delay: const Duration(milliseconds: 250)));
    _poll = Timer.periodic(pollInterval, (_) => syncNow());
    syncNow();
  }

  Future<void> stop() async {
    _stopped = true;
    _poll?.cancel();
    _retry?.cancel();
    _debounce?.cancel();
    await _remoteSub?.cancel();
    _remoteSub = null;
    final r = _running;
    if (r != null) await r;
  }

  Future<void> dispose() async {
    await stop();
    await _status.close();
  }

  /// À appeler après chaque modification locale.
  void notifyLocalChange() {
    if (!store.isClosed) _set(_current.state == SyncState.syncing ? SyncState.syncing : _idleState());
    requestSync();
  }

  SyncState _idleState() {
    if (_current.state == SyncState.offline) return SyncState.offline;
    return store.pendingCount > 0 ? SyncState.pending : SyncState.synced;
  }

  void requestSync({Duration? delay}) {
    if (_stopped) return;
    _debounce?.cancel();
    _debounce = Timer(delay ?? debounce, () => syncNow());
  }

  /// Lance une synchronisation complète (ou attend celle en cours puis en
  /// relance une).
  Future<void> syncNow() {
    if (store.isClosed) return Future.value();
    final r = _running;
    if (r != null) {
      _again = true;
      return r;
    }
    final f = _run();
    _running = f;
    return f.whenComplete(() {
      _running = null;
      if (_again && !_stopped && !store.isClosed) {
        _again = false;
        syncNow();
      }
    });
  }

  Future<void> _run() async {
    _retry?.cancel();
    _set(SyncState.syncing);
    try {
      await remote.prepare();
      await _push();
      await _pull();
      if (store.pendingCount > 0) await _push();
      await _downloadFiles();
      _failures = 0;
      _lastSync = DateTime.now();
      _set(store.pendingCount > 0 ? SyncState.pending : SyncState.synced);
    } on RemoteUnavailable catch (e) {
      _failures++;
      _set(SyncState.offline, message: e.message);
      _scheduleRetry();
    } on RemoteError catch (e) {
      _failures++;
      _set(SyncState.error, message: e.message);
      _scheduleRetry();
    } catch (e) {
      if (store.isClosed) return;
      _failures++;
      _set(SyncState.error, message: e.toString());
      _scheduleRetry();
    }
  }

  void _scheduleRetry() {
    if (_stopped) return;
    final secs = math.min(300, 5 * math.pow(2, math.min(_failures - 1, 6)).toInt());
    _retry?.cancel();
    _retry = Timer(Duration(seconds: secs), () => syncNow());
  }

  // ------------------------------------------------------------------ envoi
  Future<void> _push() async {
    for (var round = 0; round < 6; round++) {
      final ops = store.pendingOps();
      if (ops.isEmpty) return;
      for (final op in ops) {
        if (store.isClosed) return;
        final rec = store.get(op.type, op.id);
        if (rec == null || rec.conflict != null) {
          store.dropOp(op.type, op.id);
          continue;
        }
        try {
          if (op.type == EntityType.attachments) await _prepareAttachment(rec);
          final res = await remote.push(op.type, rec.data, rec.baseVersion, op.opId);
          _handlePushResult(op, res);
        } on RemoteError catch (e) {
          if (e.authProblem) rethrow;
          // Erreur propre à cet élément : on la note et on continue les autres.
          store.recordFailure(op.type, op.id, e.message);
        }
      }
      _set(SyncState.syncing);
    }
  }

  void _handlePushResult(OutboxOp op, PushResult res) {
    final server = res.row;
    switch (res.status) {
      case 'ok':
        store.ackPush(op.type, op.id, server!, op.rev);
        break;
      case 'duplicate':
        // Le serveur avait déjà appliqué cette opération (réponse perdue).
        // L'identifiant d'opération change à chaque modification locale :
        // même identifiant = même contenu, donc l'envoi est simplement acquitté.
        if (server == null) {
          store.renewOp(op.type, op.id);
        } else {
          store.ackPush(op.type, op.id, server, op.rev);
        }
        break;
      case 'conflict':
        _resolveIncoming(op.type, server!);
        break;
      default:
        store.recordFailure(op.type, op.id, 'Réponse inattendue : ${res.status}');
    }
  }

  /// Prépare une pièce jointe : envoie le fichier avant sa fiche, supprime
  /// le fichier distant d'une pièce jointe supprimée.
  Future<void> _prepareAttachment(LocalRecord rec) async {
    final a = Attachment.fromRow(rec.data);
    final path = a.storagePath;
    if (path == null) return;
    if (a.deleted) {
      if (rec.baseVersion > 0 || store.localFile(a.id)?.uploaded == true) {
        await remote.removeFiles([path]);
      }
      final lf = store.localFile(a.id);
      if (lf != null) {
        try {
          final f = File(lf.path);
          if (f.existsSync()) f.deleteSync();
        } catch (_) {}
        store.removeLocalFile(a.id);
      }
      return;
    }
    final lf = store.localFile(a.id);
    if (lf != null && !lf.uploaded) {
      final f = File(lf.path);
      if (f.existsSync()) {
        await remote.uploadFile(path, await f.readAsBytes(), a.mime);
        store.setLocalFile(a.id, lf.path, uploaded: true);
      }
    }
  }

  // ------------------------------------------------------------------ réception
  static const _pullOrder = [EntityType.folders, EntityType.tags, EntityType.notes, EntityType.attachments];

  Future<void> _pull() async {
    for (final type in _pullOrder) {
      while (true) {
        if (store.isClosed) return;
        final cursor = store.cursor(type);
        final rows = await remote.pull(type, cursor, pageSize);
        if (rows.isEmpty) break;
        store.transaction(() {
          var max = cursor;
          for (final row in rows) {
            _resolveIncoming(type, row);
            max = math.max(max, asInt(row['server_seq']));
          }
          store.setCursor(type, max);
        });
        if (rows.length < pageSize) break;
      }
    }
  }

  /// Intègre une version serveur, en fusionnant si l'appareil a des
  /// modifications en attente.
  void _resolveIncoming(EntityType type, Map<String, dynamic> server) {
    final id = server['id'].toString();
    final rec = store.get(type, id);
    final v = asInt(server['version']);
    if (rec == null) {
      store.applyServerRow(type, server);
      return;
    }
    if (rec.conflict != null) {
      if (v <= asInt(rec.conflict!['version'])) return;
      final out = mergeRows(type, rec.base, rec.data, server);
      if (out.isClean) {
        store.saveMerged(type, out.merged..['version'] = v, server);
      } else {
        store.setConflict(type, id, server);
      }
      return;
    }
    if (!rec.dirty) {
      if (v > rec.dataVersion) store.applyServerRow(type, server);
      return;
    }
    if (v <= rec.baseVersion) return; // écho d'une version déjà connue
    final out = mergeRows(type, rec.base, rec.data, server);
    if (out.isClean) {
      store.saveMerged(type, out.merged..['version'] = v, server);
    } else {
      store.setConflict(type, id, server);
    }
  }

  // ------------------------------------------------------------------ fichiers
  Future<void> _downloadFiles() async {
    for (final rec in store.all(EntityType.attachments)) {
      final a = Attachment.fromRow(rec.data);
      if (a.deleted) {
        // supprimée sur un autre appareil : on libère la place localement
        final lf = store.localFile(a.id);
        if (lf != null && !rec.dirty) {
          try {
            final f = File(lf.path);
            if (f.existsSync()) f.deleteSync();
          } catch (_) {}
          store.removeLocalFile(a.id);
        }
        continue;
      }
      if (a.storagePath == null || !a.isImage || a.sizeBytes > autoDownloadMaxBytes) continue;
      if (localPath(a.id) != null) continue;
      try {
        await ensureFile(a.id);
      } on RemoteError {
        // fichier pas encore envoyé par l'autre appareil : on réessaiera
      }
    }
  }

  /// Chemin local du fichier s'il est présent sur l'appareil.
  String? localPath(String attachmentId) {
    final lf = store.localFile(attachmentId);
    if (lf == null) return null;
    return File(lf.path).existsSync() ? lf.path : null;
  }

  /// Télécharge le fichier si nécessaire et retourne son chemin local.
  Future<String?> ensureFile(String attachmentId) async {
    final existing = localPath(attachmentId);
    if (existing != null) return existing;
    final rec = store.get(EntityType.attachments, attachmentId);
    if (rec == null) return null;
    final a = Attachment.fromRow(rec.data);
    if (a.storagePath == null || a.deleted) return null;
    final bytes = await remote.downloadFile(a.storagePath!);
    final dir = Directory(p.join(filesDir, a.id));
    await dir.create(recursive: true);
    final file = File(p.join(dir.path, safeFileName(a.fileName)));
    await file.writeAsBytes(bytes, flush: true);
    store.setLocalFile(a.id, file.path, uploaded: true);
    return file.path;
  }
}

/// Nom de fichier sans caractères problématiques (stockage et Windows).
String safeFileName(String name) {
  final cleaned = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_').replaceAll(RegExp(r'_+'), '_');
  final trimmed = cleaned.replaceAll(RegExp(r'^[._]+'), '');
  if (trimmed.isEmpty) return 'fichier';
  return trimmed.length > 100 ? trimmed.substring(trimmed.length - 100) : trimmed;
}
