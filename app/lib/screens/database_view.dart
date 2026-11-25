import 'package:flutter/material.dart';
import 'package:notes_core/notes_core.dart';

import '../state/app_controller.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/pages_ui.dart';
import '../widgets/tasks_pane.dart' show dayLabel;

IconData propIcon(String type) => switch (type) {
      PropType.number => Icons.numbers_rounded,
      PropType.date => Icons.event_rounded,
      PropType.checkbox => Icons.check_box_outlined,
      PropType.status => Icons.radio_button_checked_rounded,
      PropType.select => Icons.arrow_drop_down_circle_outlined,
      PropType.url => Icons.link_rounded,
      _ => Icons.short_text_rounded,
    };

String _iso(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${two(d.month)}-${two(d.day)}';

/// Modifie la valeur d'une propriété d'une entrée (boîte de dialogue adaptée au type).
Future<void> editPropValue(BuildContext context, NotesRepository repo, String dbId, DbProp prop, Note entry) async {
  final v = entry.props[prop.id];
  switch (prop.type) {
    case PropType.checkbox:
      repo.setProp(entry.id, prop.id, !asBool(v));
    case PropType.date:
      final now = DateTime.now();
      final d = await showDatePicker(
        context: context,
        initialDate: parseDay(v) ?? now,
        firstDate: DateTime(now.year - 50),
        lastDate: DateTime(now.year + 50),
      );
      if (d != null) repo.setProp(entry.id, prop.id, _iso(d));
    case PropType.status:
    case PropType.select:
      final choice = await showAdaptivePanel<String>(context, width: 380, builder: (c) {
        final nn = c.nn;
        return ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(8, 16, 8, 16), children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(prop.name, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
          ),
          for (final o in prop.options)
            ListTile(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              leading: RedDot(size: 10, color: parseHex(o.color) ?? nn.mid),
              title: Text(o.name),
              trailing: v == o.id ? const Icon(Icons.check_rounded, color: NColors.red) : null,
              onTap: () => Navigator.pop(c, o.id),
            ),
          ListTile(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            leading: const Icon(Icons.add_rounded),
            title: const Text('Nouvelle option…'),
            onTap: () => Navigator.pop(c, '__new__'),
          ),
          if (v != null)
            ListTile(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              leading: Icon(Icons.backspace_outlined, color: nn.mid),
              title: Text('Effacer', style: TextStyle(color: nn.mid)),
              onTap: () => Navigator.pop(c, '__clear__'),
            ),
        ]);
      });
      if (choice == null || !context.mounted) return;
      if (choice == '__clear__') {
        repo.setProp(entry.id, prop.id, null);
      } else if (choice == '__new__') {
        final name = await promptText(context, title: 'Nouvelle option', hint: 'Nom');
        if (name == null || name.isEmpty) return;
        final o = DbOption(name: name, color: kLabelColors[prop.options.length % kLabelColors.length]);
        prop.options.add(o);
        repo.updateProp(dbId, prop);
        repo.setProp(entry.id, prop.id, o.id);
      } else {
        repo.setProp(entry.id, prop.id, choice);
      }
    default:
      final text = await promptText(
        context,
        title: prop.name,
        initial: v?.toString() ?? '',
        hint: prop.type == PropType.url ? 'https://…' : (prop.type == PropType.number ? '0' : ''),
      );
      if (text == null) return;
      if (prop.type == PropType.number) {
        final n = num.tryParse(text.replaceAll(',', '.').replaceAll(' ', ''));
        if (text.isNotEmpty && n == null) {
          if (context.mounted) toast(context, 'Nombre invalide');
          return;
        }
        repo.setProp(entry.id, prop.id, n);
      } else {
        repo.setProp(entry.id, prop.id, text);
      }
  }
}

/// Affichage d'une valeur dans une cellule.
class PropValue extends StatelessWidget {
  const PropValue({super.key, required this.prop, required this.value, this.dense = false});
  final DbProp prop;
  final Object? value;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final nn = context.nn;
    if (prop.type == PropType.checkbox) {
      return Icon(asBool(value) ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded,
          size: 18, color: asBool(value) ? NColors.red : nn.mid);
    }
    if (prop.type == PropType.status || prop.type == PropType.select) {
      final o = prop.option(value);
      if (o == null) return const SizedBox.shrink();
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(999), border: Border.all(color: nn.line)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          RedDot(size: 7, color: parseHex(o.color) ?? nn.mid),
          const SizedBox(width: 6),
          Flexible(child: Text(o.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5))),
        ]),
      );
    }
    if (prop.type == PropType.date) {
      final d = parseDay(value);
      return Text(d == null ? '' : dayLabel(d), style: const TextStyle(fontSize: 13));
    }
    final s = displayValue(prop, value);
    return Text(s,
        maxLines: dense ? 1 : 3,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 13,
          decoration: prop.type == PropType.url && s.isNotEmpty ? TextDecoration.underline : null,
          fontFeatures: prop.type == PropType.number ? const [FontFeature.tabularFigures()] : null,
        ));
  }
}

/// Propriétés d'une entrée, affichées en tête de sa page.
class PropertyPanel extends StatelessWidget {
  const PropertyPanel({super.key, required this.db, required this.entry, this.readOnly = false});
  final Note db;
  final Note entry;
  final bool readOnly;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final repo = app.repo!;
    final nn = context.nn;
    final schema = repo.schemaOf(db.id);
    if (schema.props.isEmpty) return const SizedBox.shrink();
    final fresh = repo.note(entry.id) ?? entry;
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: nn.line))),
      child: Column(children: [
        for (final p in schema.props)
          InkWell(
            key: ValueKey('prop-${p.id}'),
            borderRadius: BorderRadius.circular(10),
            onTap: readOnly ? null : () => editPropValue(context, repo, db.id, p, fresh),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
              child: Row(children: [
                Icon(propIcon(p.type), size: 16, color: nn.mid),
                const SizedBox(width: 8),
                SizedBox(
                  width: 130,
                  child: Text(p.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: nn.mid)),
                ),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: fresh.props[p.id] == null && p.type != PropType.checkbox
                        ? Text('Vide', style: TextStyle(fontSize: 13, color: nn.mid.withValues(alpha: 0.6)))
                        : PropValue(prop: p, value: fresh.props[p.id]),
                  ),
                ),
              ]),
            ),
          ),
      ]),
    );
  }
}

/// Vue d'une base de données : tableau (grand écran), liste (téléphone), calendrier.
class DatabaseView extends StatefulWidget {
  const DatabaseView({super.key, required this.dbId, this.readOnly = false});
  final String dbId;
  final bool readOnly;
  @override
  State<DatabaseView> createState() => _DatabaseViewState();
}

class _DatabaseViewState extends State<DatabaseView> {
  String? _viewId;
  String _search = '';
  DateTime _month = DateTime(DateTime.now().year, DateTime.now().month);

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final repo = app.repo!;
    final nn = context.nn;
    final schema = repo.schemaOf(widget.dbId);
    if (schema.views.isEmpty) schema.views.add(DbView(name: 'Tableau'));
    final view = schema.views.firstWhere((v) => v.id == _viewId, orElse: () => schema.views.first);
    final wide = MediaQuery.of(context).size.width >= 700;
    final entries = repo.queryEntries(widget.dbId, view, search: _search);

    final header = Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
      for (final v in schema.views)
        FilterPill(
          key: ValueKey('dbview-${v.type}'),
          label: v.name,
          selected: v.id == view.id,
          onTap: () => setState(() => _viewId = v.id),
        ),
      SizedBox(
        width: wide ? 200 : double.infinity,
        child: TextField(
          onChanged: (v) => setState(() => _search = v),
          style: const TextStyle(fontSize: 13.5),
          decoration: InputDecoration(
            isDense: true,
            hintText: 'Rechercher dans la base',
            prefixIcon: Icon(Icons.search_rounded, size: 18, color: nn.mid),
          ),
        ),
      ),
      _SortButton(repo: repo, dbId: widget.dbId, schema: schema, view: view),
      _FilterButton(repo: repo, dbId: widget.dbId, schema: schema, view: view),
      if (!widget.readOnly) ...[
        OutlinedButton.icon(
          key: const ValueKey('db-add-prop'),
          onPressed: () => _addProp(context, repo),
          icon: const Icon(Icons.add_rounded, size: 18),
          label: const Text('Propriété'),
        ),
        FilledButton.icon(
          key: const ValueKey('db-add-entry'),
          style: FilledButton.styleFrom(backgroundColor: NColors.red, foregroundColor: Colors.white),
          onPressed: () => _addEntry(context, repo),
          icon: const Icon(Icons.add_rounded, size: 18),
          label: const Text('Entrée'),
        ),
      ],
    ]);

    Widget body;
    switch (view.type) {
      case 'calendar':
        body = _calendar(context, repo, schema, view, entries);
      case 'list':
        body = _list(context, repo, schema, entries);
      default:
        body = wide ? _table(context, repo, schema, entries) : _list(context, repo, schema, entries);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      header,
      if (view.filters.isNotEmpty || view.sortProp != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(
            [
              if (view.sortProp != null)
                'Tri : ${view.sortProp == kTitleProp ? 'Nom' : schema.prop(view.sortProp!)?.name ?? '?'} ${view.sortDesc ? '↓' : '↑'}',
              if (view.filters.isNotEmpty) '${view.filters.length} filtre(s)',
            ].join('  ·  '),
            style: TextStyle(fontSize: 12, color: nn.mid),
          ),
        ),
      const SizedBox(height: 12),
      body,
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text('${entries.length} entrée(s)', style: TextStyle(fontSize: 12, color: nn.mid)),
      ),
    ]);
  }

  Future<void> _addEntry(BuildContext context, NotesRepository repo) async {
    final app = AppScope.read(context);
    final tpls = repo.templates(forDatabase: widget.dbId);
    PageTemplate? tpl;
    if (tpls.isNotEmpty) {
      final id = await showAdaptivePanel<String>(context, width: 400, builder: (c) => ListView(shrinkWrap: true, padding: const EdgeInsets.all(12), children: [
            ListTile(leading: const Icon(Icons.note_add_outlined), title: const Text('Entrée vide'), onTap: () => Navigator.pop(c, '')),
            for (final t in tpls)
              ListTile(
                leading: templateIcon(t),
                title: Text(t.name),
                onTap: () => Navigator.pop(c, t.id),
              ),
          ]));
      if (id == null) return;
      if (id.isNotEmpty) tpl = repo.templateById(id);
    }
    final e = repo.addEntry(widget.dbId, title: tpl?.title ?? '', blocks: tpl?.blocks());
    app.openPage(e.id);
  }

  Future<void> _addProp(BuildContext context, NotesRepository repo) async {
    final type = await showAdaptivePanel<String>(context, width: 380, builder: (c) => ListView(shrinkWrap: true, padding: const EdgeInsets.all(12), children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: Text('Nouvelle propriété', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
          ),
          for (final t in PropType.all)
            ListTile(
              key: ValueKey('proptype-$t'),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              leading: Icon(propIcon(t)),
              title: Text(PropType.label(t)),
              onTap: () => Navigator.pop(c, t),
            ),
        ]));
    if (type == null || !context.mounted) return;
    final name = await promptText(context, title: 'Nom de la propriété', initial: PropType.label(type));
    if (name == null) return;
    repo.addProp(widget.dbId, name, type);
  }

  Future<void> _propMenu(BuildContext context, NotesRepository repo, DbProp p) async {
    final v = await showAdaptivePanel<String>(context, width: 380, builder: (c) => ListView(shrinkWrap: true, padding: const EdgeInsets.all(12), children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: Text(p.name, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
          ),
          ListTile(leading: const Icon(Icons.edit_outlined), title: const Text('Renommer'), onTap: () => Navigator.pop(c, 'rename')),
          if (PropType.hasOptions(p.type))
            ListTile(leading: const Icon(Icons.list_rounded), title: const Text('Options…'), onTap: () => Navigator.pop(c, 'options')),
          ListTile(
            leading: const Icon(Icons.visibility_off_outlined, color: NColors.red),
            title: const Text('Retirer la propriété', style: TextStyle(color: NColors.red)),
            subtitle: const Text('Les valeurs déjà saisies sont conservées dans les pages.'),
            onTap: () => Navigator.pop(c, 'remove'),
          ),
        ]));
    if (!context.mounted) return;
    switch (v) {
      case 'rename':
        final name = await promptText(context, title: 'Renommer', initial: p.name);
        if (name != null && name.isNotEmpty) {
          p.name = name;
          repo.updateProp(widget.dbId, p);
        }
      case 'options':
        await _editOptions(context, repo, p);
      case 'remove':
        if (await confirm(context,
            title: 'Retirer « ${p.name} » ?',
            message: 'La colonne disparaît de la base. Les valeurs saisies restent enregistrées dans chaque page.',
            ok: 'Retirer')) {
          repo.removeProp(widget.dbId, p.id);
        }
    }
  }

  Future<void> _editOptions(BuildContext context, NotesRepository repo, DbProp p) async {
    await showAdaptivePanel<void>(context, width: 400, builder: (c) => StatefulBuilder(builder: (c, setS) {
          return ListView(shrinkWrap: true, padding: const EdgeInsets.all(12), children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: Text('Options de « ${p.name} »', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
            ),
            for (final o in p.options)
              ListTile(
                leading: RedDot(size: 10, color: parseHex(o.color) ?? c.nn.mid),
                title: Text(o.name),
                trailing: IconButton(
                  tooltip: 'Renommer',
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  onPressed: () async {
                    final n = await promptText(c, title: 'Renommer l\'option', initial: o.name);
                    if (n != null && n.isNotEmpty) {
                      o.name = n;
                      repo.updateProp(widget.dbId, p);
                      setS(() {});
                    }
                  },
                ),
              ),
            ListTile(
              leading: const Icon(Icons.add_rounded),
              title: const Text('Ajouter une option'),
              onTap: () async {
                final n = await promptText(c, title: 'Nouvelle option', hint: 'Nom');
                if (n != null && n.isNotEmpty) {
                  p.options.add(DbOption(name: n, color: kLabelColors[p.options.length % kLabelColors.length]));
                  repo.updateProp(widget.dbId, p);
                  setS(() {});
                }
              },
            ),
          ]);
        }));
  }

  Widget _table(BuildContext context, NotesRepository repo, DbSchema schema, List<Note> entries) {
    final nn = context.nn;
    final app = AppScope.read(context);
    const titleW = 240.0, colW = 170.0;
    final width = titleW + schema.props.length * colW;
    Widget headCell(String label, IconData icon, double w, {VoidCallback? onTap}) => InkWell(
          onTap: onTap,
          child: Container(
            width: w,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(children: [
              Icon(icon, size: 15, color: nn.mid),
              const SizedBox(width: 6),
              Expanded(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: nn.mid))),
            ]),
          ),
        );
    return Container(
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), border: Border.all(color: nn.line)),
      clipBehavior: Clip.antiAlias,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: width,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Container(
              color: nn.cardHover,
              child: Row(children: [
                headCell('Nom', Icons.title_rounded, titleW),
                for (final p in schema.props)
                  headCell(p.name, propIcon(p.type), colW, onTap: widget.readOnly ? null : () => _propMenu(context, repo, p)),
              ]),
            ),
            for (final e in entries)
              Container(
                key: ValueKey('dbrow-${e.id}'),
                decoration: BoxDecoration(border: Border(top: BorderSide(color: nn.line))),
                child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                  InkWell(
                    onTap: () => app.openPage(e.id),
                    child: Container(
                      width: titleW,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                      child: Row(children: [
                        PageIcon(note: e, size: 16),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(e.title.isEmpty ? 'Sans titre' : e.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w500, color: e.title.isEmpty ? nn.mid : nn.fg)),
                        ),
                      ]),
                    ),
                  ),
                  for (final p in schema.props)
                    InkWell(
                      onTap: widget.readOnly ? null : () => editPropValue(context, repo, widget.dbId, p, e),
                      child: Container(
                        width: colW,
                        constraints: const BoxConstraints(minHeight: 42),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        alignment: Alignment.centerLeft,
                        child: PropValue(prop: p, value: e.props[p.id], dense: true),
                      ),
                    ),
                ]),
              ),
            if (entries.isEmpty)
              Padding(padding: const EdgeInsets.all(18), child: Text('Aucune entrée', style: TextStyle(color: nn.mid))),
          ]),
        ),
      ),
    );
  }

  Widget _list(BuildContext context, NotesRepository repo, DbSchema schema, List<Note> entries) {
    final nn = context.nn;
    final app = AppScope.read(context);
    if (entries.isEmpty) {
      return Padding(padding: const EdgeInsets.all(18), child: Text('Aucune entrée', style: TextStyle(color: nn.mid)));
    }
    return Column(children: [
      for (final e in entries)
        Padding(
          key: ValueKey('dbcard-${e.id}'),
          padding: const EdgeInsets.only(bottom: 8),
          child: Material(
            color: nn.card,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16), side: BorderSide(color: nn.line)),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () => app.openPage(e.id),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    PageIcon(note: e, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(e.title.isEmpty ? 'Sans titre' : e.title,
                          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: e.title.isEmpty ? nn.mid : nn.fg)),
                    ),
                  ]),
                  if (schema.props.any((p) => e.props[p.id] != null)) ...[
                    const SizedBox(height: 8),
                    Wrap(spacing: 12, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                      for (final p in schema.props)
                        if (e.props[p.id] != null)
                          Row(mainAxisSize: MainAxisSize.min, children: [
                            Text('${p.name} ', style: TextStyle(fontSize: 12, color: nn.mid)),
                            PropValue(prop: p, value: e.props[p.id], dense: true),
                          ]),
                    ]),
                  ],
                ]),
              ),
            ),
          ),
        ),
    ]);
  }

  Widget _calendar(BuildContext context, NotesRepository repo, DbSchema schema, DbView view, List<Note> entries) {
    final nn = context.nn;
    final app = AppScope.read(context);
    final dateProps = schema.props.where((p) => p.type == PropType.date).toList();
    final dp = dateProps.where((p) => p.id == view.dateProp).firstOrNull ?? dateProps.firstOrNull;
    if (dp == null) {
      return Padding(
        padding: const EdgeInsets.all(18),
        child: Text('Ajoutez une propriété « Date » pour utiliser le calendrier.', style: TextStyle(color: nn.mid)),
      );
    }
    final first = DateTime(_month.year, _month.month);
    final days = DateTime(_month.year, _month.month + 1, 0).day;
    final lead = first.weekday - 1; // lundi en premier
    final byDay = <int, List<Note>>{};
    for (final e in entries) {
      final d = parseDay(e.props[dp.id]);
      if (d != null && d.year == _month.year && d.month == _month.month) byDay.putIfAbsent(d.day, () => []).add(e);
    }
    const months = ['Janvier', 'Février', 'Mars', 'Avril', 'Mai', 'Juin', 'Juillet', 'Août', 'Septembre', 'Octobre', 'Novembre', 'Décembre'];
    final now = DateTime.now();
    final wide = MediaQuery.of(context).size.width >= 700;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        IconButton(
          tooltip: 'Mois précédent',
          onPressed: () => setState(() => _month = DateTime(_month.year, _month.month - 1)),
          icon: const Icon(Icons.chevron_left_rounded),
        ),
        Expanded(
          child: Text('${months[_month.month - 1]} ${_month.year}',
              textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w600)),
        ),
        IconButton(
          tooltip: 'Mois suivant',
          onPressed: () => setState(() => _month = DateTime(_month.year, _month.month + 1)),
          icon: const Icon(Icons.chevron_right_rounded),
        ),
      ]),
      Row(children: [
        for (final d in ['L', 'M', 'M', 'J', 'V', 'S', 'D'])
          Expanded(child: Center(child: Text(d, style: TextStyle(fontSize: 11, color: nn.mid)))),
      ]),
      const SizedBox(height: 4),
      for (var week = 0; week * 7 < lead + days; week++)
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (var wd = 0; wd < 7; wd++)
            Expanded(
              child: Builder(builder: (c) {
                final day = week * 7 + wd - lead + 1;
                if (day < 1 || day > days) return SizedBox(height: wide ? 86 : 52);
                final isToday = now.year == _month.year && now.month == _month.month && now.day == day;
                final items = byDay[day] ?? const <Note>[];
                return InkWell(
                  onTap: widget.readOnly
                      ? null
                      : () {
                          final e = repo.addEntry(widget.dbId, props: {dp.id: _iso(DateTime(_month.year, _month.month, day))});
                          app.openPage(e.id);
                        },
                  child: Container(
                    height: wide ? 86 : 52,
                    margin: const EdgeInsets.all(1),
                    padding: const EdgeInsets.all(4),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: isToday ? NColors.red : nn.line),
                    ),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('$day', style: TextStyle(fontSize: 11, color: isToday ? redText(context) : nn.mid)),
                      if (wide)
                        for (final e in items.take(3))
                          GestureDetector(
                            onTap: () => app.openPage(e.id),
                            child: Text(e.title.isEmpty ? 'Sans titre' : e.title,
                                maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11.5)),
                          )
                      else if (items.isNotEmpty)
                        const Padding(padding: EdgeInsets.only(top: 4), child: RedDot(size: 6)),
                    ]),
                  ),
                );
              }),
            ),
        ]),
      if (!wide && byDay.isNotEmpty) ...[
        const SizedBox(height: 10),
        for (final d in (byDay.keys.toList()..sort()))
          for (final e in byDay[d]!)
            ListTile(
              dense: true,
              leading: Text('$d', style: TextStyle(color: nn.mid)),
              title: Text(e.title.isEmpty ? 'Sans titre' : e.title),
              onTap: () => app.openPage(e.id),
            ),
      ],
    ]);
  }
}

class _SortButton extends StatelessWidget {
  const _SortButton({required this.repo, required this.dbId, required this.schema, required this.view});
  final NotesRepository repo;
  final String dbId;
  final DbSchema schema;
  final DbView view;

  @override
  Widget build(BuildContext context) => PopupMenuButton<String>(
        tooltip: 'Trier',
        icon: Icon(Icons.swap_vert_rounded, color: view.sortProp != null ? NColors.red : null),
        onSelected: (v) {
          if (v == '__none__') {
            view.sortProp = null;
          } else if (v == '__dir__') {
            view.sortDesc = !view.sortDesc;
          } else {
            view.sortProp = v;
          }
          repo.saveView(dbId, view);
        },
        itemBuilder: (c) => [
          PopupMenuItem(value: kTitleProp, child: Text('Nom${view.sortProp == kTitleProp ? '  ✓' : ''}')),
          for (final p in schema.props) PopupMenuItem(value: p.id, child: Text('${p.name}${view.sortProp == p.id ? '  ✓' : ''}')),
          const PopupMenuDivider(),
          PopupMenuItem(value: '__dir__', child: Text(view.sortDesc ? 'Ordre croissant' : 'Ordre décroissant')),
          const PopupMenuItem(value: '__none__', child: Text('Sans tri')),
        ],
      );
}

class _FilterButton extends StatelessWidget {
  const _FilterButton({required this.repo, required this.dbId, required this.schema, required this.view});
  final NotesRepository repo;
  final String dbId;
  final DbSchema schema;
  final DbView view;

  static List<(String, String)> opsFor(String type) => switch (type) {
        PropType.number => [('eq', '='), ('gt', '>'), ('lt', '<'), ('empty', 'est vide'), ('notempty', 'n\'est pas vide')],
        PropType.date => [('on', 'le'), ('before', 'avant le'), ('after', 'après le'), ('empty', 'est vide'), ('notempty', 'n\'est pas vide')],
        PropType.checkbox => [('checked', 'est coché'), ('unchecked', 'n\'est pas coché')],
        PropType.status || PropType.select => [('is', 'est'), ('isnot', 'n\'est pas'), ('empty', 'est vide')],
        _ => [('contains', 'contient'), ('empty', 'est vide'), ('notempty', 'n\'est pas vide')],
      };

  @override
  Widget build(BuildContext context) => IconButton(
        tooltip: 'Filtrer',
        onPressed: () => _open(context),
        icon: Badge(
          isLabelVisible: view.filters.isNotEmpty,
          smallSize: 7,
          backgroundColor: NColors.red,
          child: const Icon(Icons.filter_list_rounded),
        ),
      );

  Future<void> _open(BuildContext context) async {
    await showAdaptivePanel<void>(context, width: 460, builder: (c) => StatefulBuilder(builder: (c, setS) {
          final nn = c.nn;
          String propName(String id) => id == kTitleProp ? 'Nom' : (schema.prop(id)?.name ?? '?');
          String typeOf(String id) => id == kTitleProp ? PropType.text : (schema.prop(id)?.type ?? PropType.text);
          String valueText(DbFilter f) {
            if (f.value == null) return '';
            final p = schema.prop(f.prop);
            return p == null ? '${f.value}' : displayValue(p, f.value);
          }

          return ListView(shrinkWrap: true, padding: const EdgeInsets.all(16), children: [
            const Text('Filtres', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            if (view.filters.isEmpty) Text('Aucun filtre', style: TextStyle(color: nn.mid)),
            for (final f in [...view.filters])
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                    '${propName(f.prop)} ${opsFor(typeOf(f.prop)).where((o) => o.$1 == f.op).firstOrNull?.$2 ?? f.op} ${valueText(f)}'),
                trailing: IconButton(
                  tooltip: 'Retirer',
                  icon: const Icon(Icons.close_rounded, size: 18),
                  onPressed: () {
                    view.filters.remove(f);
                    repo.saveView(dbId, view);
                    setS(() {});
                  },
                ),
              ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Ajouter un filtre'),
              onPressed: () async {
                final f = await _newFilter(c);
                if (f != null) {
                  view.filters.add(f);
                  repo.saveView(dbId, view);
                  setS(() {});
                }
              },
            ),
          ]);
        }));
  }

  Future<DbFilter?> _newFilter(BuildContext context) async {
    final propId = await showAdaptivePanel<String>(context, width: 380, builder: (c) => ListView(shrinkWrap: true, padding: const EdgeInsets.all(12), children: [
          ListTile(leading: const Icon(Icons.title_rounded), title: const Text('Nom'), onTap: () => Navigator.pop(c, kTitleProp)),
          for (final p in schema.props)
            ListTile(leading: Icon(propIcon(p.type)), title: Text(p.name), onTap: () => Navigator.pop(c, p.id)),
        ]));
    if (propId == null || !context.mounted) return null;
    final type = propId == kTitleProp ? PropType.text : schema.prop(propId)!.type;
    final op = await showAdaptivePanel<String>(context, width: 340, builder: (c) => ListView(shrinkWrap: true, padding: const EdgeInsets.all(12), children: [
          for (final o in opsFor(type)) ListTile(title: Text(o.$2), onTap: () => Navigator.pop(c, o.$1)),
        ]));
    if (op == null || !context.mounted) return null;
    if (const {'empty', 'notempty', 'checked', 'unchecked'}.contains(op)) return DbFilter(prop: propId, op: op);
    Object? value;
    switch (type) {
      case PropType.date:
        final now = DateTime.now();
        final d = await showDatePicker(context: context, initialDate: now, firstDate: DateTime(now.year - 50), lastDate: DateTime(now.year + 50));
        if (d == null) return null;
        value = _iso(d);
      case PropType.status:
      case PropType.select:
        final p = schema.prop(propId)!;
        value = await showAdaptivePanel<String>(context, width: 340, builder: (c) => ListView(shrinkWrap: true, padding: const EdgeInsets.all(12), children: [
              for (final o in p.options) ListTile(title: Text(o.name), onTap: () => Navigator.pop(c, o.id)),
            ]));
        if (value == null) return null;
      default:
        if (!context.mounted) return null;
        final t = await promptText(context, title: 'Valeur');
        if (t == null || t.isEmpty) return null;
        value = type == PropType.number ? num.tryParse(t.replaceAll(',', '.')) : t;
        if (value == null) return null;
    }
    return DbFilter(prop: propId, op: op, value: value);
  }
}
