import 'models.dart';
import 'repository.dart';

/// Types de propriétés d'une base de données.
class PropType {
  static const text = 'text';
  static const number = 'number';
  static const date = 'date';
  static const checkbox = 'checkbox';
  static const status = 'status';
  static const select = 'select';
  static const url = 'url';
  static const all = [text, number, date, checkbox, status, select, url];

  static String label(String t) => switch (t) {
        number => 'Nombre',
        date => 'Date',
        checkbox => 'Case à cocher',
        status => 'Statut',
        select => 'Sélection',
        url => 'Lien (URL)',
        _ => 'Texte',
      };

  static bool hasOptions(String t) => t == status || t == select;
}

class DbOption {
  DbOption({String? id, required this.name, this.color}) : id = id ?? newId();
  final String id;
  String name;
  String? color;

  factory DbOption.fromJson(Map<String, dynamic> j) =>
      DbOption(id: j['id']?.toString(), name: (j['name'] ?? '').toString(), color: j['color']?.toString());
  Map<String, dynamic> toJson() => {'id': id, 'name': name, if (color != null) 'color': color};
}

class DbProp {
  DbProp({String? id, required this.name, required this.type, List<DbOption>? options})
      : id = id ?? newId(),
        options = options ?? [];
  final String id;
  String name;
  String type;
  List<DbOption> options;

  DbOption? option(Object? id) => options.where((o) => o.id == id).firstOrNull;

  factory DbProp.fromJson(Map<String, dynamic> j) => DbProp(
        id: j['id']?.toString(),
        name: (j['name'] ?? '').toString(),
        type: PropType.all.contains(j['type']) ? j['type'] as String : PropType.text,
        options: ((j['options'] as List?) ?? const [])
            .whereType<Map>()
            .map((o) => DbOption.fromJson(Map<String, dynamic>.from(o)))
            .toList(),
      );
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type,
        if (options.isNotEmpty) 'options': options.map((o) => o.toJson()).toList(),
      };
}

/// Propriété spéciale : le titre de l'entrée.
const kTitleProp = 'title';

class DbFilter {
  DbFilter({required this.prop, required this.op, this.value});
  final String prop;

  /// contains, is, isnot, eq, gt, lt, before, after, on, checked, unchecked, empty, notempty
  final String op;
  final Object? value;

  factory DbFilter.fromJson(Map<String, dynamic> j) =>
      DbFilter(prop: (j['prop'] ?? '').toString(), op: (j['op'] ?? 'contains').toString(), value: j['value']);
  Map<String, dynamic> toJson() => {'prop': prop, 'op': op, if (value != null) 'value': value};
}

class DbView {
  DbView({String? id, required this.name, this.type = 'table', this.sortProp, this.sortDesc = false, List<DbFilter>? filters, this.dateProp})
      : id = id ?? newId(),
        filters = filters ?? [];
  final String id;
  String name;

  /// table, list, calendar
  String type;
  String? sortProp;
  bool sortDesc;
  List<DbFilter> filters;

  /// Propriété date utilisée par la vue calendrier.
  String? dateProp;

  factory DbView.fromJson(Map<String, dynamic> j) => DbView(
        id: j['id']?.toString(),
        name: (j['name'] ?? '').toString(),
        type: (j['type'] ?? 'table').toString(),
        sortProp: j['sort_prop']?.toString(),
        sortDesc: asBool(j['sort_desc']),
        filters: ((j['filters'] as List?) ?? const [])
            .whereType<Map>()
            .map((f) => DbFilter.fromJson(Map<String, dynamic>.from(f)))
            .toList(),
        dateProp: j['date_prop']?.toString(),
      );
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'type': type,
        if (sortProp != null) 'sort_prop': sortProp,
        if (sortDesc) 'sort_desc': true,
        if (filters.isNotEmpty) 'filters': filters.map((f) => f.toJson()).toList(),
        if (dateProp != null) 'date_prop': dateProp,
      };
}

/// Définition d'une base de données (champ `db` de la page).
class DbSchema {
  DbSchema({List<DbProp>? props, List<DbView>? views, Map<String, dynamic>? extra})
      : props = props ?? [],
        views = views ?? [],
        extra = extra ?? {};
  List<DbProp> props;
  List<DbView> views;
  final Map<String, dynamic> extra;

  DbProp? prop(String id) => props.where((p) => p.id == id).firstOrNull;

  factory DbSchema.fromJson(Map<String, dynamic>? j) {
    j ??= const {};
    return DbSchema(
      props: ((j['props'] as List?) ?? const []).whereType<Map>().map((p) => DbProp.fromJson(Map<String, dynamic>.from(p))).toList(),
      views: ((j['views'] as List?) ?? const []).whereType<Map>().map((v) => DbView.fromJson(Map<String, dynamic>.from(v))).toList(),
      extra: {
        for (final e in j.entries)
          if (e.key != 'props' && e.key != 'views') e.key: jsonClone(e.value)
      },
    );
  }

  Map<String, dynamic> toJson() => {
        ...jsonClone(extra),
        'props': props.map((p) => p.toJson()).toList(),
        'views': views.map((v) => v.toJson()).toList(),
      };
}

/// Valeur affichable d'une propriété.
String displayValue(DbProp prop, Object? v) {
  if (v == null) return '';
  switch (prop.type) {
    case PropType.checkbox:
      return asBool(v) ? '✓' : '';
    case PropType.status:
    case PropType.select:
      return prop.option(v)?.name ?? '';
    case PropType.date:
      final d = parseDay(v);
      return d == null ? '' : '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
    case PropType.number:
      final n = v is num ? v : num.tryParse(v.toString());
      if (n == null) return '';
      return n == n.roundToDouble() ? n.toInt().toString() : n.toString().replaceAll('.', ',');
    default:
      return v.toString();
  }
}

Object? _value(Note n, String prop) => prop == kTitleProp ? n.title : n.props[prop];

bool _isEmpty(Object? v) => v == null || (v is String && v.trim().isEmpty);

bool matchesFilter(Note n, DbFilter f, DbSchema schema) {
  final v = _value(n, f.prop);
  final type = f.prop == kTitleProp ? PropType.text : (schema.prop(f.prop)?.type ?? PropType.text);
  switch (f.op) {
    case 'empty':
      return _isEmpty(v) || (type == PropType.checkbox && !asBool(v));
    case 'notempty':
      return !_isEmpty(v) && !(type == PropType.checkbox && !asBool(v));
    case 'checked':
      return asBool(v);
    case 'unchecked':
      return !asBool(v);
    case 'is':
      return v?.toString() == f.value?.toString();
    case 'isnot':
      return v?.toString() != f.value?.toString();
    case 'eq':
    case 'gt':
    case 'lt':
      final a = v is num ? v : num.tryParse('$v');
      final b = f.value is num ? f.value as num : num.tryParse('${f.value}');
      if (a == null || b == null) return false;
      return f.op == 'eq' ? a == b : (f.op == 'gt' ? a > b : a < b);
    case 'before':
    case 'after':
    case 'on':
      final a = parseDay(v), b = parseDay(f.value);
      if (a == null || b == null) return false;
      return f.op == 'on' ? a == b : (f.op == 'before' ? a.isBefore(b) : a.isAfter(b));
    case 'contains':
    default:
      if (f.value == null || '${f.value}'.trim().isEmpty) return true;
      final prop = schema.prop(f.prop);
      final shown = (f.prop == kTitleProp || prop == null) ? (v ?? '').toString() : displayValue(prop, v);
      return foldText(shown).contains(foldText('${f.value}'));
  }
}

int compareValues(Object? a, Object? b, String type, DbProp? prop) {
  if (_isEmpty(a) && _isEmpty(b)) return 0;
  if (_isEmpty(a)) return 1; // vides à la fin
  if (_isEmpty(b)) return -1;
  switch (type) {
    case PropType.number:
      return (num.tryParse('$a') ?? 0).compareTo(num.tryParse('$b') ?? 0);
    case PropType.date:
      return (parseDay(a) ?? DateTime(0)).compareTo(parseDay(b) ?? DateTime(0));
    case PropType.checkbox:
      return (asBool(b) ? 1 : 0).compareTo(asBool(a) ? 1 : 0);
    case PropType.status:
    case PropType.select:
      final ia = prop?.options.indexWhere((o) => o.id == a) ?? 0, ib = prop?.options.indexWhere((o) => o.id == b) ?? 0;
      return ia.compareTo(ib);
    default:
      return foldText('$a').compareTo(foldText('$b'));
  }
}

extension DatabaseX on NotesRepository {
  /// Nouvelle base de données avec deux propriétés et deux vues par défaut.
  Note createDatabase({String title = 'Nouvelle base', String? parentId, String? folderId}) {
    final status = DbProp(name: 'Statut', type: PropType.status, options: [
      DbOption(name: 'À faire', color: '#858585'),
      DbOption(name: 'En cours', color: '#FF6B00'),
      DbOption(name: 'Terminé', color: '#00B86B'),
    ]);
    final date = DbProp(name: 'Date', type: PropType.date);
    final schema = DbSchema(props: [status, date], views: [
      DbView(name: 'Tableau', type: 'table'),
      DbView(name: 'Liste', type: 'list'),
      DbView(name: 'Calendrier', type: 'calendar', dateProp: date.id),
    ]);
    final parent = parentId == null ? null : note(parentId);
    return createNote(
      title: title,
      blocks: [Block()],
      kind: PageKind.database,
      parentId: parentId,
      folderId: folderId ?? parent?.folderId,
      db: schema.toJson(),
    );
  }

  DbSchema schemaOf(String dbId) => DbSchema.fromJson(note(dbId)?.db);

  void saveSchema(String dbId, DbSchema schema) {
    final n = note(dbId);
    if (n == null) return;
    n.db = schema.toJson();
    saveNote(n);
  }

  DbProp addProp(String dbId, String name, String type) {
    final s = schemaOf(dbId);
    final p = DbProp(name: name.trim().isEmpty ? PropType.label(type) : name.trim(), type: type);
    if (type == PropType.status) {
      p.options = [DbOption(name: 'À faire', color: '#858585'), DbOption(name: 'En cours', color: '#FF6B00'), DbOption(name: 'Terminé', color: '#00B86B')];
    }
    s.props.add(p);
    saveSchema(dbId, s);
    return p;
  }

  void updateProp(String dbId, DbProp prop) {
    final s = schemaOf(dbId);
    final i = s.props.indexWhere((p) => p.id == prop.id);
    if (i < 0) return;
    s.props[i] = prop;
    saveSchema(dbId, s);
  }

  /// Retire la propriété de la base. Les valeurs déjà saisies dans les
  /// entrées sont conservées (elles ne sont simplement plus affichées).
  void removeProp(String dbId, String propId) {
    final s = schemaOf(dbId);
    s.props.removeWhere((p) => p.id == propId);
    for (final v in s.views) {
      v.filters.removeWhere((f) => f.prop == propId);
      if (v.sortProp == propId) v.sortProp = null;
      if (v.dateProp == propId) v.dateProp = null;
    }
    saveSchema(dbId, s);
  }

  void saveView(String dbId, DbView view) {
    final s = schemaOf(dbId);
    final i = s.views.indexWhere((v) => v.id == view.id);
    if (i < 0) {
      s.views.add(view);
    } else {
      s.views[i] = view;
    }
    saveSchema(dbId, s);
  }

  /// Entrées de la base (ses sous-pages).
  List<Note> entriesOf(String dbId) => childrenOf(dbId).where((n) => n.kind == PageKind.page).toList();

  Note addEntry(String dbId, {String title = '', Map<String, dynamic>? props, List<Block>? blocks}) {
    final db = note(dbId);
    return createNote(
      title: title,
      blocks: blocks ?? [Block()],
      parentId: dbId,
      folderId: db?.folderId,
      props: props,
    );
  }

  /// Valeur d'une propriété d'une entrée (null efface la valeur).
  void setProp(String entryId, String propId, Object? value) {
    final n = note(entryId);
    if (n == null) return;
    if (propId == kTitleProp) {
      n.title = (value ?? '').toString();
    } else if (value == null || (value is String && value.isEmpty)) {
      n.props.remove(propId);
    } else {
      n.props[propId] = value;
    }
    saveNote(n);
  }

  /// Entrées filtrées, recherchées et triées selon la vue.
  List<Note> queryEntries(String dbId, DbView view, {String search = ''}) {
    final schema = schemaOf(dbId);
    var list = entriesOf(dbId);
    final q = foldText(search.trim());
    if (q.isNotEmpty) {
      list = list.where((n) {
        if (foldText(n.title).contains(q)) return true;
        for (final p in schema.props) {
          if (foldText(displayValue(p, n.props[p.id])).contains(q)) return true;
        }
        return foldText(plainText(n.blocks)).contains(q);
      }).toList();
    }
    for (final f in view.filters) {
      list = list.where((n) => matchesFilter(n, f, schema)).toList();
    }
    final sp = view.sortProp;
    if (sp != null) {
      final prop = schema.prop(sp);
      final type = sp == kTitleProp ? PropType.text : (prop?.type ?? PropType.text);
      list.sort((a, b) {
        final c = compareValues(_value(a, sp), _value(b, sp), type, prop);
        return view.sortDesc ? -c : c;
      });
    }
    return list;
  }
}
