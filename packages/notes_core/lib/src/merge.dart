import 'models.dart';

/// Résultat d'une fusion à trois voies (ancêtre commun / local / autre appareil).
class MergeOutcome {
  MergeOutcome(this.merged, {this.hardConflicts = const [], this.softConflicts = const []});

  /// Ligne fusionnée (valable seulement si [isClean]).
  final Map<String, dynamic> merged;

  /// Champs modifiés différemment des deux côtés sans résolution sûre :
  /// l'utilisateur doit choisir.
  final List<String> hardConflicts;

  /// Champs secondaires (favori, dossier, couleur...) modifiés des deux côtés :
  /// la modification locale, la plus récente pour cet appareil, est retenue.
  final List<String> softConflicts;

  bool get isClean => hardConflicts.isEmpty;
}

/// Égalité profonde JSON, insensible à l'ordre des clés et à la
/// représentation des dates.
bool jsonEq(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return a == b;
  if (a is Map && b is Map) {
    final keys = {...a.keys, ...b.keys};
    for (final k in keys) {
      if (!jsonEq(a[k], b[k])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!jsonEq(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is num && b is num) return a == b;
  if (a is String && b is String) {
    if (a == b) return true;
    // dates : "2026-11-14T10:00:00.000Z" == "2026-11-14T10:00:00+00:00"
    if (a.length >= 19 && b.length >= 19 && a[4] == '-' && b[4] == '-') {
      final da = DateTime.tryParse(a), db = DateTime.tryParse(b);
      if (da != null && db != null) return da.isAtSameMomentAs(db);
    }
    return false;
  }
  return a == b;
}

const _softFields = <EntityType, List<String>>{
  EntityType.notes: ['folder_id', 'favorite', 'archived', 'trashed_at', 'parent_id', 'icon', 'kind', 'template_for'],
  EntityType.folders: ['name', 'parent_id', 'color', 'position', 'deleted'],
  EntityType.tags: ['name', 'color', 'deleted'],
  EntityType.attachments: ['note_id', 'file_name', 'mime', 'size_bytes', 'sha256', 'deleted'],
};

/// Fusionne une ligne modifiée localement ([local]) avec la version serveur
/// concurrente ([server]), à partir de leur ancêtre commun ([base], la
/// dernière version serveur connue de l'appareil, ou `null` si inconnue).
///
/// La décision ne repose jamais sur l'heure de modification : seules les
/// différences par rapport à l'ancêtre commun comptent.
MergeOutcome mergeRows(EntityType type, Map<String, dynamic>? baseRow, Map<String, dynamic> local,
    Map<String, dynamic> server) {
  final Map<String, dynamic> base = baseRow ?? const <String, dynamic>{};
  final merged = jsonClone(server);
  final hard = <String>[];
  final soft = <String>[];

  bool changed(Map<String, dynamic> side, String f) => !jsonEq(side[f], base[f]);

  for (final f in _softFields[type]!) {
    final lc = changed(local, f), sc = changed(server, f);
    if (lc) {
      if (sc && !jsonEq(local[f], server[f])) soft.add(f);
      merged[f] = jsonClone(local[f]);
    }
  }

  if (type == EntityType.notes) {
    // Titre
    final lt = changed(local, 'title'), st = changed(server, 'title');
    if (lt && st && !jsonEq(local['title'], server['title'])) {
      hard.add('title');
    } else if (lt) {
      merged['title'] = local['title'];
    }

    // Étiquettes : fusion d'ensembles (ajouts et retraits des deux côtés)
    final bt = _strSet(base['tags']), ltg = _strSet(local['tags']), stg = _strSet(server['tags']);
    final tags = {...stg}
      ..addAll(ltg.difference(bt))
      ..removeAll(bt.difference(ltg));
    final ordered = <String>[
      ...((server['tags'] as List?) ?? const []).map((e) => e.toString()).where(tags.contains),
      ...((local['tags'] as List?) ?? const []).map((e) => e.toString()).where(tags.contains),
    ];
    merged['tags'] = {...ordered}.toList();

    // Contenu : fusion bloc par bloc
    final lcContent = changed(local, 'content'), scContent = changed(server, 'content');
    if (lcContent && scContent && !jsonEq(local['content'], server['content'])) {
      final r = mergeBlocks(
        _blocks(base['content']),
        _blocks(local['content']),
        _blocks(server['content']),
      );
      if (r == null) {
        hard.add('content');
      } else {
        merged['content'] = {'blocks': r};
      }
    } else if (lcContent) {
      merged['content'] = jsonClone(local['content']);
    }

    // Propriétés (entrée de base de données) : fusion propriété par propriété
    final lpChanged = changed(local, 'props'), spChanged = changed(server, 'props');
    if (lpChanged && spChanged) {
      final r = _mergeMaps(_map(base['props']), _map(local['props']), _map(server['props']));
      if (r == null) {
        hard.add('props');
      } else {
        merged['props'] = r;
      }
    } else if (lpChanged) {
      merged['props'] = jsonClone(local['props']);
    }

    // Définition d'une base de données (propriétés, vues)
    final ldb = changed(local, 'db'), sdb = changed(server, 'db');
    if (ldb && sdb && !jsonEq(local['db'], server['db'])) {
      final r = _mergeMaps(_map(base['db']), _map(local['db']), _map(server['db']));
      if (r == null) {
        hard.add('db');
      } else {
        merged['db'] = r;
      }
    } else if (ldb) {
      merged['db'] = jsonClone(local['db']);
    }

    // Suppression définitive d'un côté, modifications de l'autre
    final lp = asBool(local['purged']), sp = asBool(server['purged']), bp = asBool(base['purged']);
    if (lp != sp && !bp) {
      final otherEdited = lp ? (changed(server, 'content') || changed(server, 'title'))
                             : (lcContent || lt);
      if (otherEdited) {
        hard.add('purged');
      } else {
        merged['purged'] = true;
        merged['title'] = '';
        merged['content'] = {'blocks': []};
      }
    }
  }

  // Tout autre champ (ajouté par une version plus récente) : jamais écrasé
  // en silence ; modifié des deux côtés différemment → conflit.
  final handled = {
    'id', 'created_at', 'updated_at', 'device_id', 'version', 'server_seq', 'server_updated_at', 'user_id',
    ..._softFields[type]!,
    if (type == EntityType.notes) ...['title', 'tags', 'content', 'purged', 'props', 'db'],
  };
  for (final f in {...local.keys, ...server.keys, ...base.keys}) {
    if (handled.contains(f)) continue;
    final lc = changed(local, f), sc = changed(server, f);
    if (lc && sc && !jsonEq(local[f], server[f])) {
      hard.add(f);
    } else if (lc) {
      if (local.containsKey(f)) {
        merged[f] = jsonClone(local[f]);
      } else {
        merged.remove(f);
      }
    }
  }

  // Métadonnées : on garde la date la plus récente pour l'affichage et
  // l'appareil d'origine de la dernière modification locale.
  final lu = parseDate(local['updated_at']), su = parseDate(server['updated_at']);
  if (lu != null && (su == null || lu.isAfter(su))) merged['updated_at'] = local['updated_at'];
  if (local['device_id'] != null) merged['device_id'] = local['device_id'];

  return MergeOutcome(merged, hardConflicts: hard, softConflicts: soft);
}

Map<String, dynamic> _map(Object? v) => v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

/// Fusion à trois voies de deux dictionnaires, clé par clé. Retourne `null`
/// si une même clé a été modifiée différemment des deux côtés.
Map<String, dynamic>? _mergeMaps(Map<String, dynamic> base, Map<String, dynamic> local, Map<String, dynamic> other,
    {Set<String> ignore = const {}}) {
  final out = jsonClone(other);
  for (final k in {...base.keys, ...local.keys, ...other.keys}) {
    if (ignore.contains(k)) continue;
    final lc = !jsonEq(local[k], base[k]), oc = !jsonEq(other[k], base[k]);
    if (lc && oc && !jsonEq(local[k], other[k])) return null;
    if (lc) {
      if (local.containsKey(k) && local[k] != null) {
        out[k] = jsonClone(local[k]);
      } else {
        out.remove(k);
      }
    }
  }
  return out;
}

Set<String> _strSet(Object? v) => ((v as List?) ?? const []).map((e) => e.toString()).toSet();

List<Map<String, dynamic>> _blocks(Object? content) {
  if (content is Map && content['blocks'] is List) {
    return (content['blocks'] as List).whereType<Map>().map((b) => Map<String, dynamic>.from(b)).toList();
  }
  return [];
}

/// Fusion à trois voies d'une liste de blocs identifiés par `id`.
/// Retourne `null` si un même champ d'un même bloc a été modifié
/// différemment des deux côtés, ou modifié d'un côté et supprimé de l'autre.
List<Map<String, dynamic>>? mergeBlocks(
    List<Map<String, dynamic>> base, List<Map<String, dynamic>> local, List<Map<String, dynamic>> server) {
  String idOf(Map<String, dynamic> b) => b['id'].toString();
  final bm = {for (final b in base) idOf(b): b};
  final lm = {for (final b in local) idOf(b): b};
  final sm = {for (final b in server) idOf(b): b};

  final result = <String, Map<String, dynamic>>{};
  final removed = <String>{};
  final ids = {...bm.keys, ...lm.keys, ...sm.keys};

  for (final id in ids) {
    final b = bm[id], l = lm[id], s = sm[id];
    if (b == null) {
      // bloc ajouté
      if (l != null && s != null) {
        if (!jsonEq(l, s)) return null;
        result[id] = s;
      } else {
        result[id] = (l ?? s)!;
      }
      continue;
    }
    final lDel = l == null, sDel = s == null;
    final lCh = !lDel && !jsonEq(l, b), sCh = !sDel && !jsonEq(s, b);
    if (lDel && sDel) {
      removed.add(id);
    } else if (lDel) {
      if (sCh) return null;
      removed.add(id);
    } else if (sDel) {
      if (lCh) return null;
      removed.add(id);
    } else if (lCh && sCh) {
      if (jsonEq(l, s)) {
        result[id] = s;
      } else {
        // Même bloc modifié des deux côtés : fusion champ par champ (par
        // exemple le texte ici, l'échéance de la tâche là-bas).
        final m = _mergeMaps(b, l, s);
        if (m == null) return null;
        result[id] = m;
      }
    } else {
      result[id] = lCh ? l : s;
    }
  }

  // Ordre : on part de l'ordre modifié (si un seul côté a réordonné les
  // blocs), puis on insère les blocs ajoutés par l'autre côté après leur
  // prédécesseur.
  final baseOrder = base.map(idOf).toList();
  final localOrder = local.map(idOf).toList();
  final serverOrder = server.map(idOf).toList();
  bool reordered(List<String> side) {
    final common = side.where(bm.containsKey).toList();
    final baseCommon = baseOrder.where(side.contains).toList();
    return !_listEq(common, baseCommon);
  }

  final useLocal = reordered(localOrder) && !reordered(serverOrder);
  final primary = useLocal ? localOrder : serverOrder;
  final secondary = useLocal ? serverOrder : localOrder;

  final order = primary.where((id) => result.containsKey(id)).toList();
  for (var i = 0; i < secondary.length; i++) {
    final id = secondary[i];
    if (!result.containsKey(id) || order.contains(id)) continue;
    var insertAt = 0;
    for (var j = i - 1; j >= 0; j--) {
      final idx = order.indexOf(secondary[j]);
      if (idx >= 0) {
        insertAt = idx + 1;
        break;
      }
    }
    order.insert(insertAt, id);
  }
  return [for (final id in order) result[id]!];
}

bool _listEq(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
