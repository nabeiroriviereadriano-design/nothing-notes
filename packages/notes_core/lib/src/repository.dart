import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;

import 'local_store.dart';
import 'merge.dart';
import 'models.dart';

enum ConflictChoice { keepMine, keepOther, keepBoth }

class NoteVersion {
  NoteVersion({required this.title, required this.blocks, required this.savedAt, this.reason = 'edit'});
  final String title;
  final List<Block> blocks;
  final DateTime savedAt;

  /// 'edit' (modification ici), 'sync' / 'merge' (reçue d'un autre appareil),
  /// 'conflict' (version écartée lors d'un conflit), 'restore'.
  final String reason;
}

/// Règles métier communes à Android et Windows : tout ce que l'interface
/// peut faire sur les notes passe par cette classe.
class NotesRepository {
  NotesRepository({required this.store, required this.filesDir});

  final LocalStore store;
  final String filesDir;

  String get deviceId => store.deviceId;
  Stream<EntityType> get changes => store.changes;

  // ---------------------------------------------------------------- notes
  /// Toutes les notes non supprimées définitivement (corbeille comprise).
  List<Note> allNotes() {
    final unsynced = store.unsyncedIds(EntityType.notes);
    return store
        .all(EntityType.notes)
        .map((r) => Note.fromRow(r.data, dirty: unsynced.contains(r.id), conflict: r.conflictRow))
        .where((n) => !n.purged)
        .toList();
  }

  Note? note(String id) {
    final r = store.get(EntityType.notes, id);
    if (r == null) return null;
    final n = Note.fromRow(r.data, dirty: store.isUnsynced(EntityType.notes, id), conflict: r.conflictRow);
    return n.purged ? null : n;
  }

  Note createNote({String title = '', List<Block>? blocks, String? folderId, List<String>? tags}) {
    final n = Note(
      id: newId(),
      title: title,
      blocks: blocks ?? [Block()],
      folderId: folderId,
      tags: tags,
      deviceId: deviceId,
    );
    store.saveLocal(EntityType.notes, n.toRow());
    return n;
  }

  /// Enregistre la note sur cet appareil (immédiat) ; elle sera transmise
  /// aux appareils associés. Retourne `false` si rien n'a changé.
  bool saveNote(Note n, {bool touch = true, String reason = 'edit'}) {
    final cur = store.get(EntityType.notes, n.id);
    final row = n.toRow();
    if (cur != null) {
      const fields = ['title', 'content', 'folder_id', 'tags', 'favorite', 'archived', 'trashed_at', 'purged'];
      if (fields.every((f) => jsonEq(row[f], cur.data[f]))) return false;
    }
    if (touch) {
      n.updatedAt = DateTime.now().toUtc();
      row['updated_at'] = n.updatedAt.toIso8601String();
    }
    n.deviceId = deviceId;
    row['device_id'] = deviceId;
    store.saveLocal(EntityType.notes, row, reason: reason);
    return true;
  }

  void _update(String id, void Function(Note n) change, {bool touch = false}) {
    final n = note(id);
    if (n == null) return;
    change(n);
    saveNote(n, touch: touch);
  }

  void setFavorite(String id, bool v) => _update(id, (n) => n.favorite = v);
  void setArchived(String id, bool v) => _update(id, (n) => n.archived = v);
  void moveToFolder(String id, String? folderId) => _update(id, (n) => n.folderId = folderId);
  void setTags(String id, List<String> tags) => _update(id, (n) => n.tags = [...tags]);
  void trashNote(String id) => _update(id, (n) => n.trashedAt = DateTime.now().toUtc());
  void restoreNote(String id) => _update(id, (n) => n.trashedAt = null);

  List<Block> _copyBlocks(List<Block> blocks) =>
      blocks.map((b) => Block.fromJson({...jsonClone(b.toJson()), 'id': newId()})).toList();

  Note duplicateNote(String id, {String suffix = ' (copie)'}) {
    final src = note(id)!;
    return createNote(
      title: '${src.title}$suffix',
      blocks: _copyBlocks(src.blocks),
      folderId: src.folderId,
      tags: [...src.tags],
    );
  }

  /// Suppression définitive : la note devient une pierre tombale vide,
  /// propagée à tous les appareils ; ses pièces jointes sont supprimées.
  void purgeNote(String id) {
    final n = note(id);
    if (n == null) return;
    store.transaction(() {
      for (final a in attachmentsOf(id)) {
        deleteAttachment(a.id);
      }
      n
        ..purged = true
        ..title = ''
        ..blocks = []
        ..tags = []
        ..trashedAt ??= DateTime.now().toUtc();
      saveNote(n);
    });
  }

  void emptyTrash() {
    for (final n in allNotes().where((n) => n.trashed)) {
      purgeNote(n.id);
    }
  }

  /// Supprime définitivement les notes restées plus de [days] jours dans la corbeille.
  int purgeExpiredTrash({int days = 30}) {
    final limit = DateTime.now().toUtc().subtract(Duration(days: days));
    final old = allNotes().where((n) => n.trashedAt != null && n.trashedAt!.isBefore(limit)).toList();
    for (final n in old) {
      purgeNote(n.id);
    }
    return old.length;
  }

  // ---------------------------------------------------------------- dossiers
  List<Folder> folders() => store
      .all(EntityType.folders)
      .map((r) => Folder.fromRow(r.data))
      .where((f) => !f.deleted)
      .toList()
    ..sort((a, b) {
      final c = a.position.compareTo(b.position);
      return c != 0 ? c : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });

  Folder createFolder(String name, {String? parentId, String? color}) {
    final siblings = folders().where((f) => f.parentId == parentId);
    final pos = siblings.isEmpty ? 0.0 : siblings.map((f) => f.position).reduce((a, b) => a > b ? a : b) + 1;
    final f = Folder(id: newId(), name: name.trim(), parentId: parentId, color: color, position: pos);
    _saveRow(EntityType.folders, f.toRow());
    return f;
  }

  void updateFolder(Folder f) {
    f.updatedAt = DateTime.now().toUtc();
    _saveRow(EntityType.folders, f.toRow());
  }

  /// Identifiants du dossier et de tous ses descendants.
  Set<String> folderSubtree(String id) {
    final all = folders();
    final ids = <String>{id};
    var grew = true;
    while (grew) {
      grew = false;
      for (final f in all) {
        if (f.parentId != null && ids.contains(f.parentId) && ids.add(f.id)) grew = true;
      }
    }
    return ids;
  }

  /// Supprime le dossier et ses sous-dossiers ; leurs notes reviennent à la racine.
  void deleteFolder(String id) {
    store.transaction(() {
      final toDelete = folderSubtree(id);
      for (final f in folders().where((f) => toDelete.contains(f.id))) {
        f.deleted = true;
        updateFolder(f);
      }
      for (final n in allNotes().where((n) => toDelete.contains(n.folderId))) {
        n.folderId = null;
        saveNote(n, touch: false);
      }
    });
  }

  // ---------------------------------------------------------------- étiquettes
  List<Tag> tags() => store.all(EntityType.tags).map((r) => Tag.fromRow(r.data)).where((t) => !t.deleted).toList()
    ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  Tag createTag(String name, {String? color}) {
    final existing = tags().where((t) => t.name.toLowerCase() == name.trim().toLowerCase());
    if (existing.isNotEmpty) return existing.first;
    final t = Tag(id: newId(), name: name.trim(), color: color);
    _saveRow(EntityType.tags, t.toRow());
    return t;
  }

  void updateTag(Tag t) {
    t.updatedAt = DateTime.now().toUtc();
    _saveRow(EntityType.tags, t.toRow());
  }

  void deleteTag(String id) {
    store.transaction(() {
      final t = tags().where((t) => t.id == id).firstOrNull;
      if (t == null) return;
      t.deleted = true;
      updateTag(t);
      for (final n in allNotes().where((n) => n.tags.contains(id))) {
        n.tags = n.tags.where((x) => x != id).toList();
        saveNote(n, touch: false);
      }
    });
  }

  void _saveRow(EntityType type, Map<String, dynamic> row) {
    row['device_id'] = deviceId;
    store.saveLocal(type, row);
  }

  // ---------------------------------------------------------------- pièces jointes
  List<Attachment> attachmentsOf(String noteId) => store
      .all(EntityType.attachments)
      .map((r) => Attachment.fromRow(r.data))
      .where((a) => a.noteId == noteId && !a.deleted)
      .toList()
    ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

  Attachment? attachment(String id) {
    final r = store.get(EntityType.attachments, id);
    return r == null ? null : Attachment.fromRow(r.data);
  }

  /// Ajoute un fichier ou une image à une note. Le fichier est copié dans
  /// le stockage de l'application ; il sera transmis aux appareils associés.
  Attachment addAttachment(String noteId, {required String fileName, required Uint8List bytes, String? mime}) {
    final id = newId();
    final dir = Directory(p.join(filesDir, id))..createSync(recursive: true);
    final file = File(p.join(dir.path, safeFileName(fileName)))..writeAsBytesSync(bytes, flush: true);
    final a = Attachment(
      id: id,
      noteId: noteId,
      fileName: fileName,
      mime: mime ?? guessMime(fileName),
      sizeBytes: bytes.length,
      sha256: crypto.sha256.convert(bytes).toString(),
    );
    store.transaction(() {
      store.setLocalFile(id, file.path);
      _saveRow(EntityType.attachments, a.toRow());
    });
    return a;
  }

  void deleteAttachment(String id) {
    final a = attachment(id);
    if (a == null || a.deleted) return;
    a
      ..deleted = true
      ..updatedAt = DateTime.now().toUtc();
    _saveRow(EntityType.attachments, a.toRow());
    removeLocalCopy(store, id);
  }

  /// Chemin du fichier s'il est présent sur cet appareil.
  String? localPath(String attachmentId) {
    final path = store.localFile(attachmentId);
    if (path == null) return null;
    return File(path).existsSync() ? path : null;
  }

  // ---------------------------------------------------------------- recherche
  /// Recherche par titre, contenu, étiquette ou dossier.
  List<Note> search(String query) {
    final q = foldText(query.trim());
    if (q.isEmpty) return [];
    final byId = {for (final n in allNotes()) n.id: n};
    final result = <String>[];
    for (final id in store.search(query)) {
      if (byId.containsKey(id)) result.add(id);
    }
    final tagIds = tags().where((t) => foldText(t.name).contains(q)).map((t) => t.id).toSet();
    final folderIds = folders().where((f) => foldText(f.name).contains(q)).map((f) => f.id).toSet();
    for (final n in byId.values) {
      if (result.contains(n.id)) continue;
      if (n.tags.any(tagIds.contains) || (n.folderId != null && folderIds.contains(n.folderId))) {
        result.add(n.id);
      } else if (foldText(n.title).contains(q)) {
        result.add(n.id);
      }
    }
    return [for (final id in result) byId[id]!];
  }

  // ---------------------------------------------------------------- conflits
  /// Résout un conflit de modification simultanée sur deux appareils.
  Future<void> resolveConflict(String noteId, ConflictChoice choice) async {
    final rec = store.get(EntityType.notes, noteId);
    if (rec == null || rec.conflict == null) return;
    final mine = Note.fromRow(rec.data);
    switch (choice) {
      case ConflictChoice.keepMine:
        store.resolveKeepLocal(EntityType.notes, noteId);
        break;
      case ConflictChoice.keepOther:
        // La version locale écartée reste restaurable depuis l'historique.
        store.resolveKeepRemote(EntityType.notes, noteId);
        break;
      case ConflictChoice.keepBoth:
        store.resolveKeepRemote(EntityType.notes, noteId);
        if (!mine.purged) {
          createNote(
            title: '${mine.title.isEmpty ? 'Sans titre' : mine.title} (ma version)',
            blocks: _copyBlocks(mine.blocks),
            folderId: mine.folderId,
            tags: [...mine.tags],
          );
        }
        break;
    }
  }

  // ---------------------------------------------------------------- historique
  /// Versions précédentes de la note conservées sur cet appareil.
  List<NoteVersion> history(String noteId) => store
      .history(noteId)
      .map((r) => NoteVersion(
            title: (r['title'] ?? '').toString(),
            blocks: blocksFromContent(r['content']),
            savedAt: parseDate(r['saved_at']) ?? DateTime.now().toUtc(),
            reason: (r['reason'] ?? 'edit').toString(),
          ))
      .toList();

  void restoreVersion(String noteId, NoteVersion v) {
    final n = note(noteId);
    if (n == null) return;
    n
      ..title = v.title
      ..blocks = v.blocks.map((b) => b.copy()).toList();
    saveNote(n, reason: 'restore');
  }
}

/// Supprime la copie locale d'une pièce jointe (fichier et référence).
void removeLocalCopy(LocalStore store, String attachmentId) {
  final path = store.localFile(attachmentId);
  if (path == null) return;
  try {
    final f = File(path);
    if (f.existsSync()) f.deleteSync();
    final dir = f.parent;
    if (dir.existsSync() && dir.listSync().isEmpty) dir.deleteSync();
  } catch (_) {}
  store.removeLocalFile(attachmentId);
}

const _accents = {
  'à': 'a', 'â': 'a', 'ä': 'a', 'á': 'a', 'ã': 'a', 'å': 'a',
  'ç': 'c',
  'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e',
  'î': 'i', 'ï': 'i', 'í': 'i', 'ì': 'i',
  'ô': 'o', 'ö': 'o', 'ó': 'o', 'ò': 'o', 'õ': 'o',
  'ù': 'u', 'û': 'u', 'ü': 'u', 'ú': 'u',
  'ÿ': 'y', 'ñ': 'n', 'œ': 'oe', 'æ': 'ae',
};

/// Minuscules sans accents, pour comparer des textes.
String foldText(String s) {
  final b = StringBuffer();
  for (final ch in s.toLowerCase().split('')) {
    b.write(_accents[ch] ?? ch);
  }
  return b.toString();
}
