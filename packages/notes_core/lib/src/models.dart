import 'dart:convert';

import 'package:uuid/uuid.dart';

const _uuid = Uuid();

/// Génère un identifiant unique (UUID v4).
String newId() => _uuid.v4();

/// Les quatre types d'éléments synchronisés.
enum EntityType { folders, tags, notes, attachments }

EntityType entityFromName(String name) =>
    EntityType.values.firstWhere((e) => e.name == name);

String nowIso() => DateTime.now().toUtc().toIso8601String();

DateTime? parseDate(Object? v) {
  if (v == null) return null;
  if (v is DateTime) return v.toUtc();
  return DateTime.tryParse(v.toString())?.toUtc();
}

int asInt(Object? v, [int fallback = 0]) {
  if (v == null) return fallback;
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse(v.toString()) ?? fallback;
}

bool asBool(Object? v) => v == true || v == 1 || v == 'true';

/// Copie profonde d'une structure JSON.
T jsonClone<T>(T value) => jsonDecode(jsonEncode(value)) as T;

// --------------------------------------------------------------------------
// Conservation des champs inconnus
// --------------------------------------------------------------------------

/// Sépare les champs connus des autres. Les champs inconnus (ajoutés par une
/// version plus récente de l'application) sont toujours réécrits tels quels :
/// une version plus ancienne ne doit jamais effacer ce qu'elle ne comprend pas.
Map<String, dynamic> _extraOf(Map<String, dynamic> row, Set<String> known) => {
      for (final e in row.entries)
        if (!known.contains(e.key)) e.key: jsonClone(e.value)
    };

// --------------------------------------------------------------------------
// Blocs de contenu
// --------------------------------------------------------------------------

/// Types de blocs de l'éditeur.
class BlockType {
  static const paragraph = 'p';
  static const heading1 = 'h1';
  static const heading2 = 'h2';
  static const heading3 = 'h3';
  static const quote = 'quote';
  static const bullet = 'bullet';
  static const numbered = 'numbered';
  static const todo = 'todo';
  static const code = 'code';
  static const divider = 'divider';
  static const image = 'image';
  static const file = 'file';
  static const table = 'table';

  /// Bloc repliable : `text` = résumé toujours visible, `body` = contenu repliable.
  static const toggle = 'toggle';

  /// Blocs édités comme une simple zone de texte.
  static const textual = {paragraph, heading1, heading2, heading3, quote, bullet, numbered, todo, code};
}

/// Statuts d'une tâche suivie.
class TaskStatus {
  static const todo = 'todo';
  static const doing = 'doing';
  static const done = 'done';
  static const all = [todo, doing, done];

  static String label(String s) => switch (s) {
        doing => 'En cours',
        done => 'Terminée',
        _ => 'À faire',
      };
}

/// Informations de suivi d'une case à cocher transformée en tâche.
/// Stockées dans le bloc lui-même (champ `task`) : rien n'est dupliqué.
class TaskInfo {
  TaskInfo({this.status = TaskStatus.todo, this.due, this.priority = 0});

  String status;

  /// Échéance (jour, sans heure), facultative.
  DateTime? due;

  /// 0 aucune, 1 basse, 2 moyenne, 3 haute.
  int priority;

  factory TaskInfo.fromJson(Map<String, dynamic> j) => TaskInfo(
        status: TaskStatus.all.contains(j['status']) ? j['status'] as String : TaskStatus.todo,
        due: parseDay(j['due']),
        priority: asInt(j['priority']).clamp(0, 3),
      );

  Map<String, dynamic> toJson() => {
        'status': status,
        if (due != null) 'due': formatDay(due!),
        if (priority > 0) 'priority': priority,
      };
}

/// Jour au format AAAA-MM-JJ.
String formatDay(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

DateTime? parseDay(Object? v) {
  if (v == null) return null;
  final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})').firstMatch(v.toString());
  if (m == null) return null;
  return DateTime(int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!));
}

/// Un bloc de note. Les champs inconnus sont conservés (compatibilité future).
class Block {
  Block({
    String? id,
    this.type = BlockType.paragraph,
    this.text = '',
    this.checked = false,
    this.attachmentId,
    this.rows,
    Map<String, dynamic>? extra,
  })  : id = id ?? newId(),
        extra = extra ?? {};

  static const _known = {'id', 'type', 'text', 'checked', 'attachment_id', 'rows'};

  final String id;
  String type;
  String text;
  bool checked;
  String? attachmentId;
  List<List<String>>? rows;

  /// Autres champs : `body`, `collapsed` (bloc repliable), `task` (tâche
  /// suivie), et tout champ d'une version future.
  final Map<String, dynamic> extra;

  bool get isTextual => BlockType.textual.contains(type);

  /// Contenu d'un bloc repliable.
  String get body => (extra['body'] ?? '').toString();
  set body(String v) => extra['body'] = v;

  bool get collapsed => asBool(extra['collapsed']);
  set collapsed(bool v) => v ? extra['collapsed'] = true : extra.remove('collapsed');

  /// Suivi de tâche (case à cocher uniquement).
  TaskInfo? get task {
    final t = extra['task'];
    return t is Map ? TaskInfo.fromJson(Map<String, dynamic>.from(t)) : null;
  }

  set task(TaskInfo? t) => t == null ? extra.remove('task') : extra['task'] = t.toJson();

  factory Block.fromJson(Map<String, dynamic> j) => Block(
        id: (j['id'] ?? newId()).toString(),
        type: (j['type'] ?? BlockType.paragraph).toString(),
        text: (j['text'] ?? '').toString(),
        checked: asBool(j['checked']),
        attachmentId: j['attachment_id']?.toString(),
        rows: (j['rows'] as List?)
            ?.map((r) => (r as List).map((c) => (c ?? '').toString()).toList())
            .toList(),
        extra: _extraOf(j, _known),
      );

  Map<String, dynamic> toJson() => {
        ...jsonClone(extra),
        'id': id,
        'type': type,
        if (text.isNotEmpty || isTextual || type == BlockType.toggle) 'text': text,
        if (type == BlockType.todo) 'checked': checked,
        if (attachmentId != null) 'attachment_id': attachmentId,
        if (rows != null) 'rows': rows,
      };

  Block copy() => Block.fromJson(jsonClone(toJson()));

  /// Copie avec un nouvel identifiant (duplication, modèles).
  Block cloneFresh() => Block.fromJson({...jsonClone(toJson()), 'id': newId()});
}

List<Block> blocksFromContent(Object? content) {
  if (content is String) {
    try {
      content = jsonDecode(content);
    } catch (_) {
      return [Block(text: content as String)];
    }
  }
  if (content is Map && content['blocks'] is List) {
    return (content['blocks'] as List)
        .whereType<Map>()
        .map((b) => Block.fromJson(Map<String, dynamic>.from(b)))
        .toList();
  }
  return [];
}

Map<String, dynamic> contentFromBlocks(List<Block> blocks) =>
    {'blocks': blocks.map((b) => b.toJson()).toList()};

/// Texte brut d'une liste de blocs (recherche, aperçu, export TXT).
String plainText(List<Block> blocks) {
  final buf = StringBuffer();
  for (final b in blocks) {
    if (b.isTextual && b.text.trim().isNotEmpty) {
      buf.writeln(stripInlineMarkers(b.text));
    } else if (b.type == BlockType.toggle) {
      if (b.text.trim().isNotEmpty) buf.writeln(stripInlineMarkers(b.text));
      if (b.body.trim().isNotEmpty) buf.writeln(stripInlineMarkers(b.body));
    } else if (b.type == BlockType.table && b.rows != null) {
      for (final r in b.rows!) {
        buf.writeln(r.join(' | '));
      }
    }
  }
  return buf.toString().trim();
}

final _markerRe = RegExp(r'\*\*|\+\+|~~|`|(?<![\w*])\*(?!\s)|(?<!\s)\*(?![\w*])');
final _linkRe = RegExp(r'\[([^\]]*)\]\(([^)\s]+)\)');

String stripInlineMarkers(String s) =>
    s.replaceAllMapped(_linkRe, (m) => m.group(1)!).replaceAll(_markerRe, '');

/// Préfixe des liens internes vers une autre page : `[Titre](nn:page:<id>)`.
const kPageLinkPrefix = 'nn:page:';

String pageLink(String title, String id) =>
    '[${title.trim().isEmpty ? 'Sans titre' : title.replaceAll(RegExp(r'[\[\]\n]'), ' ').trim()}]($kPageLinkPrefix$id)';

final _pageLinkRe = RegExp(r'\]\(nn:page:([A-Za-z0-9-]+)\)');

/// Identifiants des pages citées dans des blocs (liens internes).
Set<String> linkedPageIds(List<Block> blocks) {
  final out = <String>{};
  void scan(String s) {
    for (final m in _pageLinkRe.allMatches(s)) {
      out.add(m.group(1)!);
    }
  }

  for (final b in blocks) {
    scan(b.text);
    if (b.type == BlockType.toggle) scan(b.body);
    for (final r in b.rows ?? const <List<String>>[]) {
      r.forEach(scan);
    }
  }
  return out;
}

// --------------------------------------------------------------------------
// Entités
// --------------------------------------------------------------------------

/// Sortes de pages.
class PageKind {
  /// Page ordinaire (valeur par défaut, y compris pour les notes existantes).
  static const page = 'page';

  /// Base de données : sa définition est dans `db`, ses entrées sont ses sous-pages.
  static const database = 'database';

  /// Modèle de page (invisible dans les listes de notes).
  static const template = 'template';
}

/// Note (page) telle que manipulée par l'interface.
class Note {
  Note({
    required this.id,
    this.title = '',
    List<Block>? blocks,
    this.folderId,
    List<String>? tags,
    this.favorite = false,
    this.archived = false,
    this.trashedAt,
    this.purged = false,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.deviceId,
    this.parentId,
    this.kind = PageKind.page,
    this.icon,
    Map<String, dynamic>? props,
    this.db,
    this.templateFor,
    Map<String, dynamic>? extra,
    Map<String, dynamic>? contentExtra,
    this.dirty = false,
    this.conflictRow,
  })  : contentExtra = contentExtra ?? {},
        blocks = blocks ?? [],
        tags = tags ?? [],
        props = props ?? {},
        extra = extra ?? {},
        createdAt = createdAt ?? DateTime.now().toUtc(),
        updatedAt = updatedAt ?? DateTime.now().toUtc();

  static const known = {
    'id', 'title', 'content', 'folder_id', 'tags', 'favorite', 'archived', 'trashed_at', 'purged', //
    'created_at', 'updated_at', 'device_id', 'parent_id', 'kind', 'icon', 'props', 'db', 'template_for',
  };

  final String id;
  String title;
  List<Block> blocks;
  String? folderId;
  List<String> tags;
  bool favorite;
  bool archived;
  DateTime? trashedAt;
  bool purged;
  DateTime createdAt;
  DateTime updatedAt;
  String? deviceId;

  /// Page parente (sous-page), ou null pour une page racine.
  String? parentId;

  /// [PageKind] : page, base de données ou modèle.
  String kind;

  /// Petite icône (un emoji), facultative.
  String? icon;

  /// Valeurs des propriétés quand la page est une entrée de base de données
  /// (identifiant de propriété → valeur).
  Map<String, dynamic> props;

  /// Définition de la base de données (propriétés et vues), pour [PageKind.database].
  Map<String, dynamic>? db;

  /// Pour un modèle d'entrée : identifiant de la base de données visée.
  String? templateFor;

  /// Champs d'une version future, conservés tels quels.
  final Map<String, dynamic> extra;

  /// Champs d'une version future à l'intérieur de `content` (à côté de `blocks`).
  final Map<String, dynamic> contentExtra;

  /// Modifications pas encore transmises à un appareil associé.
  bool dirty;

  /// Version concurrente venue d'un autre appareil (conflit à arbitrer).
  Map<String, dynamic>? conflictRow;

  bool get hasConflict => conflictRow != null;
  bool get trashed => trashedAt != null;
  bool get isDatabase => kind == PageKind.database;
  bool get isTemplate => kind == PageKind.template;

  factory Note.fromRow(Map<String, dynamic> r, {bool dirty = false, Map<String, dynamic>? conflict}) => Note(
        id: r['id'].toString(),
        title: (r['title'] ?? '').toString(),
        blocks: blocksFromContent(r['content']),
        folderId: r['folder_id']?.toString(),
        tags: ((r['tags'] as List?) ?? const []).map((e) => e.toString()).toList(),
        favorite: asBool(r['favorite']),
        archived: asBool(r['archived']),
        trashedAt: parseDate(r['trashed_at']),
        purged: asBool(r['purged']),
        createdAt: parseDate(r['created_at']),
        updatedAt: parseDate(r['updated_at']),
        deviceId: r['device_id']?.toString(),
        parentId: r['parent_id']?.toString(),
        kind: (r['kind'] ?? PageKind.page).toString(),
        icon: r['icon']?.toString(),
        props: r['props'] is Map ? Map<String, dynamic>.from(jsonClone(r['props']) as Map) : null,
        db: r['db'] is Map ? Map<String, dynamic>.from(jsonClone(r['db']) as Map) : null,
        templateFor: r['template_for']?.toString(),
        extra: _extraOf(r, known),
        contentExtra: r['content'] is Map ? _extraOf(Map<String, dynamic>.from(r['content'] as Map), const {'blocks'}) : null,
        dirty: dirty,
        conflictRow: conflict,
      );

  /// Ligne enregistrée. Les nouveaux champs ne sont écrits que s'ils ont une
  /// valeur : une note ordinaire garde exactement la forme d'avant.
  Map<String, dynamic> toRow() => {
        ...jsonClone(extra),
        'id': id,
        'title': title,
        'content': {...jsonClone(contentExtra), ...contentFromBlocks(blocks)},
        'folder_id': folderId,
        'tags': tags,
        'favorite': favorite,
        'archived': archived,
        'trashed_at': trashedAt?.toUtc().toIso8601String(),
        'purged': purged,
        'created_at': createdAt.toUtc().toIso8601String(),
        'updated_at': updatedAt.toUtc().toIso8601String(),
        'device_id': deviceId,
        if (parentId != null) 'parent_id': parentId,
        if (kind != PageKind.page) 'kind': kind,
        if (icon != null && icon!.isNotEmpty) 'icon': icon,
        if (props.isNotEmpty) 'props': jsonClone(props),
        if (db != null) 'db': jsonClone(db),
        if (templateFor != null) 'template_for': templateFor,
      };

  Note copy() => Note.fromRow(jsonClone(toRow()), dirty: dirty, conflict: conflictRow);

  String get preview {
    final t = plainText(blocks).replaceAll('\n', ' · ');
    return t.length > 140 ? '${t.substring(0, 140)}…' : t;
  }

  bool get hasChecklist => blocks.any((b) => b.type == BlockType.todo);
  bool get hasImage => blocks.any((b) => b.type == BlockType.image);
  bool get hasCode => blocks.any((b) => b.type == BlockType.code);
}

class Folder {
  Folder({
    required this.id,
    this.name = '',
    this.parentId,
    this.color,
    this.position = 0,
    this.deleted = false,
    DateTime? createdAt,
    DateTime? updatedAt,
    Map<String, dynamic>? extra,
  })  : extra = extra ?? {},
        createdAt = createdAt ?? DateTime.now().toUtc(),
        updatedAt = updatedAt ?? DateTime.now().toUtc();

  static const known = {'id', 'name', 'parent_id', 'color', 'position', 'deleted', 'created_at', 'updated_at', 'device_id'};

  final String id;
  String name;
  String? parentId;
  String? color;
  double position;
  bool deleted;
  DateTime createdAt;
  DateTime updatedAt;
  final Map<String, dynamic> extra;

  factory Folder.fromRow(Map<String, dynamic> r) => Folder(
        id: r['id'].toString(),
        name: (r['name'] ?? '').toString(),
        parentId: r['parent_id']?.toString(),
        color: r['color']?.toString(),
        position: (r['position'] as num?)?.toDouble() ?? 0,
        deleted: asBool(r['deleted']),
        createdAt: parseDate(r['created_at']),
        updatedAt: parseDate(r['updated_at']),
        extra: _extraOf(r, known),
      );

  Map<String, dynamic> toRow() => {
        ...jsonClone(extra),
        'id': id,
        'name': name,
        'parent_id': parentId,
        'color': color,
        'position': position,
        'deleted': deleted,
        'created_at': createdAt.toUtc().toIso8601String(),
        'updated_at': updatedAt.toUtc().toIso8601String(),
      };
}

class Tag {
  Tag({
    required this.id,
    this.name = '',
    this.color,
    this.deleted = false,
    DateTime? createdAt,
    DateTime? updatedAt,
    Map<String, dynamic>? extra,
  })  : extra = extra ?? {},
        createdAt = createdAt ?? DateTime.now().toUtc(),
        updatedAt = updatedAt ?? DateTime.now().toUtc();

  static const known = {'id', 'name', 'color', 'deleted', 'created_at', 'updated_at', 'device_id'};

  final String id;
  String name;
  String? color;
  bool deleted;
  DateTime createdAt;
  DateTime updatedAt;
  final Map<String, dynamic> extra;

  factory Tag.fromRow(Map<String, dynamic> r) => Tag(
        id: r['id'].toString(),
        name: (r['name'] ?? '').toString(),
        color: r['color']?.toString(),
        deleted: asBool(r['deleted']),
        createdAt: parseDate(r['created_at']),
        updatedAt: parseDate(r['updated_at']),
        extra: _extraOf(r, known),
      );

  Map<String, dynamic> toRow() => {
        ...jsonClone(extra),
        'id': id,
        'name': name,
        'color': color,
        'deleted': deleted,
        'created_at': createdAt.toUtc().toIso8601String(),
        'updated_at': updatedAt.toUtc().toIso8601String(),
      };
}

class Attachment {
  Attachment({
    required this.id,
    required this.noteId,
    this.fileName = 'fichier',
    this.mime = 'application/octet-stream',
    this.sizeBytes = 0,
    this.sha256,
    this.deleted = false,
    DateTime? createdAt,
    DateTime? updatedAt,
    Map<String, dynamic>? extra,
  })  : extra = extra ?? {},
        createdAt = createdAt ?? DateTime.now().toUtc(),
        updatedAt = updatedAt ?? DateTime.now().toUtc();

  static const known = {
    'id', 'note_id', 'file_name', 'mime', 'size_bytes', 'sha256', 'deleted', 'created_at', 'updated_at', 'device_id', //
  };

  final String id;
  String noteId;
  String fileName;
  String mime;
  int sizeBytes;
  String? sha256;
  bool deleted;
  DateTime createdAt;
  DateTime updatedAt;
  final Map<String, dynamic> extra;

  bool get isImage => mime.startsWith('image/');

  factory Attachment.fromRow(Map<String, dynamic> r) => Attachment(
        id: r['id'].toString(),
        noteId: r['note_id'].toString(),
        fileName: (r['file_name'] ?? 'fichier').toString(),
        mime: (r['mime'] ?? 'application/octet-stream').toString(),
        sizeBytes: asInt(r['size_bytes']),
        sha256: r['sha256']?.toString(),
        deleted: asBool(r['deleted']),
        createdAt: parseDate(r['created_at']),
        updatedAt: parseDate(r['updated_at']),
        extra: _extraOf(r, known),
      );

  Map<String, dynamic> toRow() => {
        ...jsonClone(extra),
        'id': id,
        'note_id': noteId,
        'file_name': fileName,
        'mime': mime,
        'size_bytes': sizeBytes,
        'sha256': sha256,
        'deleted': deleted,
        'created_at': createdAt.toUtc().toIso8601String(),
        'updated_at': updatedAt.toUtc().toIso8601String(),
      };
}

/// Devine le type MIME à partir de l'extension.
String guessMime(String fileName) {
  final ext = fileName.contains('.') ? fileName.split('.').last.toLowerCase() : '';
  const map = {
    'png': 'image/png',
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'gif': 'image/gif',
    'webp': 'image/webp',
    'bmp': 'image/bmp',
    'pdf': 'application/pdf',
    'txt': 'text/plain',
    'md': 'text/markdown',
    'csv': 'text/csv',
    'zip': 'application/zip',
    'doc': 'application/msword',
    'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'mp3': 'audio/mpeg',
    'wav': 'audio/wav',
    'mp4': 'video/mp4',
  };
  return map[ext] ?? 'application/octet-stream';
}

/// Nom de fichier sans caractères problématiques (Windows et Android).
String safeFileName(String name) {
  final cleaned = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_').replaceAll(RegExp(r'_+'), '_');
  final trimmed = cleaned.replaceAll(RegExp(r'^[._]+'), '');
  if (trimmed.isEmpty) return 'fichier';
  return trimmed.length > 100 ? trimmed.substring(trimmed.length - 100) : trimmed;
}
