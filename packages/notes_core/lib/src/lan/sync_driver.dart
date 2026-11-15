import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;

import '../local_store.dart';
import '../merge.dart';
import '../models.dart';
import '../repository.dart' show removeLocalCopy;
import 'channel.dart';

/// Fichiers des pièces jointes sur cet appareil.
class FileOps {
  FileOps(this.store, this.filesDir);
  final LocalStore store;
  final String filesDir;

  String? pathOf(String attachmentId) {
    final path = store.localFile(attachmentId);
    if (path == null) return null;
    return File(path).existsSync() ? path : null;
  }

  File tempFor(String attachmentId) {
    final dir = Directory(p.join(filesDir, '.partiel'))..createSync(recursive: true);
    return File(p.join(dir.path, '$attachmentId.part'));
  }

  /// Vérifie l'empreinte du fichier reçu puis le met à sa place définitive.
  void finalize(String attachmentId, File temp) {
    final rec = store.get(EntityType.attachments, attachmentId);
    if (rec == null) {
      if (temp.existsSync()) temp.deleteSync();
      throw RpcError('norow', 'pièce jointe inconnue');
    }
    final a = Attachment.fromRow(rec.data);
    if (a.sha256 != null && crypto.sha256.convert(temp.readAsBytesSync()).toString() != a.sha256) {
      temp.deleteSync();
      throw RpcError('checksum', 'fichier corrompu pendant le transfert');
    }
    final dir = Directory(p.join(filesDir, attachmentId))..createSync(recursive: true);
    final dest = File(p.join(dir.path, safeFileName(a.fileName)));
    if (dest.existsSync()) dest.deleteSync();
    temp.renameSync(dest.path);
    store.setLocalFile(attachmentId, dest.path);
    store.notifyFiles();
  }

  /// Supprime les fichiers des pièces jointes supprimées.
  void cleanup() {
    for (final e in store.all(EntityType.attachments)) {
      if (asBool(e.data['deleted']) && store.localFile(e.id) != null) removeLocalCopy(store, e.id);
    }
  }

  /// Pièces jointes dont le fichier manque sur cet appareil.
  List<String> missing() => [
        for (final e in store.all(EntityType.attachments))
          if (!asBool(e.data['deleted']) && pathOf(e.id) == null) e.id
      ];
}

/// Côté « répondeur » : expose la base locale à l'appareil associé [peerId],
/// qui pilote l'échange. Toute écriture est conditionnelle (révision
/// attendue) : une modification locale concurrente n'est jamais écrasée.
void registerResponder(RpcPeer rpc, LocalStore store, String peerId, String filesDir, {void Function()? onProgress}) {
  final files = FileOps(store, filesDir);

  rpc.handlers['ping'] = (_, __) => RpcReply();

  rpc.handlers['pull'] = (params, _) {
    final limit = asInt(params['limit'], 200).clamp(1, 1000);
    final rows = store.changedSince(asInt(params['after']), limit);
    return RpcReply({
      'rows': [
        for (final e in rows) {'e': e.type.name, 'row': e.data, 'rev': e.rev, 'seq': e.seq}
      ],
      'more': rows.length == limit,
    });
  };

  rpc.handlers['push'] = (params, _) {
    final EntityType type;
    try {
      type = entityFromName(params['e'].toString());
    } catch (_) {
      throw RpcError('badentity', 'type inconnu');
    }
    final row = params['row'];
    if (row is! Map || row['id'] is! String) throw RpcError('badrow', 'élément invalide');
    final out = store.applyFromPeer(type, Map<String, dynamic>.from(row), asInt(params['exp']));
    if (out.ok && type == EntityType.attachments) files.cleanup();
    return RpcReply(out.ok ? {'status': 'ok', 'rev': out.rev} : {'status': 'conflict', 'row': out.row, 'rev': out.rev});
  };

  rpc.handlers['ack'] = (params, _) {
    store.setAckedSeq(peerId, asInt(params['seq']));
    onProgress?.call();
    return RpcReply();
  };

  rpc.handlers['files'] = (_, __) => RpcReply({'missing': files.missing()});

  rpc.handlers['getFile'] = (params, _) async {
    final path = files.pathOf(params['id'].toString());
    if (path == null) throw RpcError('nofile', 'fichier absent');
    final f = File(path);
    final size = await f.length();
    final offset = asInt(params['offset']);
    final len = asInt(params['len'], 256 * 1024).clamp(1, 1024 * 1024);
    final raf = await f.open();
    try {
      await raf.setPosition(offset);
      final chunk = await raf.read(len);
      return RpcReply({'size': size, 'eof': offset + chunk.length >= size}, chunk);
    } finally {
      await raf.close();
    }
  };

  rpc.handlers['putFile'] = (params, payload) async {
    final id = params['id'].toString();
    if (!RegExp(r'^[A-Za-z0-9-]{1,64}$').hasMatch(id)) throw RpcError('badid', 'identifiant invalide');
    final offset = asInt(params['offset']);
    final temp = files.tempFor(id);
    if (offset == 0) {
      await temp.writeAsBytes(payload ?? Uint8List(0), flush: true);
    } else {
      if (!temp.existsSync() || temp.lengthSync() != offset) throw RpcError('offset', 'reprise impossible');
      await temp.writeAsBytes(payload ?? Uint8List(0), mode: FileMode.append, flush: true);
    }
    if (temp.lengthSync() > 64 * 1024 * 1024) {
      temp.deleteSync();
      throw RpcError('toobig', 'fichier trop volumineux');
    }
    if (params['last'] == true) {
      files.finalize(id, temp);
      onProgress?.call();
    }
    return RpcReply();
  };
}

/// Côté « pilote » : mène un échange complet avec l'appareil associé.
///
/// 1. reçoit ce qui a changé chez l'autre depuis le dernier passage (par
///    pages, en mémorisant la position après chaque page) ;
/// 2. fusionne avec les modifications locales : automatiquement quand c'est
///    sans risque, sinon le conflit est présenté à l'utilisateur ;
/// 3. envoie les modifications locales (écriture conditionnelle) ;
/// 4. échange les fichiers manquants de part et d'autre.
class SyncDriver {
  SyncDriver({
    required this.store,
    required this.rpc,
    required this.peerId,
    required this.filesDir,
    this.pageSize = 200,
    this.chunkSize = 256 * 1024,
  }) : _files = FileOps(store, filesDir);

  final LocalStore store;
  final RpcPeer rpc;
  final String peerId;
  final String filesDir;
  final int pageSize;
  final int chunkSize;
  final FileOps _files;

  Future<void> round() async {
    await _pull();
    await _push();
    await _pull();
    await rpc.call('ack', {'seq': store.pullCursor(peerId)});
    await _syncFiles();
    store.markSynced(peerId);
  }

  // ------------------------------------------------------------------ réception
  Future<void> _pull() async {
    while (true) {
      final after = store.pullCursor(peerId);
      final res = (await rpc.call('pull', {'after': after, 'limit': pageSize})).result;
      final rows = (res['rows'] as List?) ?? const [];
      if (rows.isEmpty) return;
      store.transaction(() {
        var max = after;
        for (final item in rows) {
          final m = Map<String, dynamic>.from(item as Map);
          max = math.max(max, asInt(m['seq']));
          final EntityType type;
          try {
            type = entityFromName(m['e'].toString());
          } catch (_) {
            continue; // type inconnu (version plus récente de l'application)
          }
          _incoming(type, Map<String, dynamic>.from(m['row'] as Map), asInt(m['rev']));
        }
        store.setPullCursor(peerId, max);
      });
      _files.cleanup();
      if (res['more'] != true) return;
    }
  }

  /// Intègre la version [remote] (révision [rev] chez l'autre appareil).
  void _incoming(EntityType type, Map<String, dynamic> remote, int rev, {bool fromPush = false}) {
    final id = remote['id'].toString();
    final local = store.get(type, id);
    final ps = store.peerState(peerId, type, id);
    if (!fromPush && ps != null && rev <= ps.peerRev) return; // déjà connu (écho de notre envoi)
    if (local == null) {
      store.applyPulled(peerId, type, remote, rev);
      return;
    }
    if (jsonEq(local.data, remote)) {
      store.markEqual(peerId, type, id, remote, rev);
      return;
    }
    final localChanged = ps == null || ps.dirty;
    if (!localChanged) {
      store.applyPulled(peerId, type, remote, rev);
      return;
    }
    // Modifié des deux côtés depuis le dernier échange : fusion à trois voies.
    final out = mergeRows(type, ps?.base, local.data, remote);
    if (out.isClean) {
      store.saveMerged(peerId, type, out.merged, remote, rev);
    } else {
      store.setConflict(peerId, type, id, remote, rev);
    }
  }

  // ------------------------------------------------------------------ envoi
  Future<void> _push() async {
    for (var pass = 0; pass < 8; pass++) {
      final candidates = store.pushCandidates(peerId, pageSize);
      if (candidates.isEmpty) return;
      var progressed = false;
      for (final c in candidates) {
        final cur = store.get(c.type, c.id);
        if (cur == null || cur.conflict != null) continue;
        final ps = store.peerState(peerId, c.type, c.id);
        final res = (await rpc.call('push', {'e': c.type.name, 'row': cur.data, 'exp': ps?.peerRev ?? 0})).result;
        if (res['status'] == 'ok') {
          store.ackPush(peerId, c.type, c.id, cur.data, asInt(res['rev']), cur.rev);
          progressed = true;
        } else if (res['status'] == 'conflict') {
          if (res['row'] is Map) {
            // L'autre appareil a changé entre-temps : on fusionne avec sa version.
            _incoming(c.type, Map<String, dynamic>.from(res['row'] as Map), asInt(res['rev']), fromPush: true);
          } else {
            // L'autre appareil n'a plus cet élément : on le lui renverra en entier.
            store.resetPeerState(peerId, c.type, c.id);
          }
          progressed = true;
        }
      }
      if (!progressed) return;
    }
  }

  // ------------------------------------------------------------------ fichiers
  Future<void> _syncFiles() async {
    _files.cleanup();
    for (final id in _files.missing()) {
      try {
        await _fetch(id);
      } on RpcError catch (e) {
        if (e.code != 'nofile') rethrow; // l'autre appareil ne l'a pas (encore) non plus
      }
    }
    final wanted = ((await rpc.call('files')).result['missing'] as List?) ?? const [];
    for (final id in wanted) {
      final path = _files.pathOf(id.toString());
      if (path != null) await _send(id.toString(), path);
    }
  }

  Future<void> _fetch(String id) async {
    final temp = _files.tempFor(id);
    if (temp.existsSync()) temp.deleteSync();
    final sink = temp.openSync(mode: FileMode.write);
    try {
      var offset = 0;
      while (true) {
        final reply = await rpc.call('getFile', {'id': id, 'offset': offset, 'len': chunkSize});
        final chunk = reply.payload ?? Uint8List(0);
        sink.writeFromSync(chunk);
        offset += chunk.length;
        if (reply.result['eof'] == true || chunk.isEmpty) break;
      }
    } finally {
      sink.closeSync();
    }
    _files.finalize(id, temp);
  }

  Future<void> _send(String id, String path) async {
    final raf = await File(path).open();
    try {
      final size = await raf.length();
      var offset = 0;
      do {
        final chunk = await raf.read(chunkSize);
        final last = offset + chunk.length >= size;
        await rpc.call('putFile', {'id': id, 'offset': offset, 'last': last}, chunk);
        offset += chunk.length;
      } while (offset < size);
    } finally {
      await raf.close();
    }
  }
}
