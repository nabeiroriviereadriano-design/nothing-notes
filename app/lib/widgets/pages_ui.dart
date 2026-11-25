import 'package:flutter/material.dart';
import 'package:notes_core/notes_core.dart';

import '../state/app_controller.dart';
import '../theme.dart';
import 'common.dart';

bool _isWide(BuildContext context) => MediaQuery.of(context).size.width >= 700;

/// Ouvre un panneau adapté à l'appareil : feuille du bas sur téléphone,
/// boîte de dialogue sur grand écran.
Future<T?> showAdaptivePanel<T>(BuildContext context, {required WidgetBuilder builder, double width = 520}) {
  if (_isWide(context)) {
    return showDialog<T>(
      context: context,
      builder: (c) => Dialog(
        insetPadding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: width, maxHeight: 620),
          child: builder(c),
        ),
      ),
    );
  }
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    builder: (c) => SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(c).viewInsets.bottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(c).size.height * 0.82),
          child: builder(c),
        ),
      ),
    ),
  );
}

// ==================================================================== insertion rapide « / »
class BlockChoice {
  const BlockChoice(this.key, this.icon, this.label, this.hint, [this.words = '']);
  final String key;
  final IconData icon;
  final String label;
  final String hint;
  final String words;
}

const kBlockChoices = <BlockChoice>[
  BlockChoice(BlockType.paragraph, Icons.notes_rounded, 'Texte', 'Paragraphe simple', 'paragraphe texte'),
  BlockChoice(BlockType.heading1, Icons.title_rounded, 'Titre 1', 'Grand titre de section', 'h1 titre'),
  BlockChoice(BlockType.heading2, Icons.text_fields_rounded, 'Titre 2', 'Titre moyen', 'h2 sous-titre'),
  BlockChoice(BlockType.heading3, Icons.short_text_rounded, 'Titre 3', 'Petit titre', 'h3'),
  BlockChoice(BlockType.bullet, Icons.format_list_bulleted_rounded, 'Liste à puces', 'Liste simple', 'puce liste'),
  BlockChoice(BlockType.numbered, Icons.format_list_numbered_rounded, 'Liste numérotée', '1, 2, 3…', 'numéro liste'),
  BlockChoice(BlockType.todo, Icons.check_box_outlined, 'Case à cocher', 'Liste de tâches', 'todo tâche case'),
  BlockChoice('task', Icons.task_alt_rounded, 'Tâche suivie', 'Avec échéance, statut et priorité', 'tâche échéance'),
  BlockChoice(BlockType.toggle, Icons.arrow_right_rounded, 'Bloc repliable', 'Contenu masqué que l\'on déplie', 'toggle replier'),
  BlockChoice(BlockType.quote, Icons.format_quote_rounded, 'Citation', 'Texte mis en retrait', 'citation'),
  BlockChoice(BlockType.divider, Icons.horizontal_rule_rounded, 'Séparateur', 'Ligne de points', 'ligne séparateur'),
  BlockChoice(BlockType.code, Icons.code_rounded, 'Code', 'Bloc de code', 'code'),
  BlockChoice(BlockType.table, Icons.grid_on_rounded, 'Tableau', 'Lignes et colonnes', 'tableau'),
  BlockChoice(BlockType.image, Icons.image_outlined, 'Image', 'Depuis l\'appareil', 'image photo'),
  BlockChoice(BlockType.file, Icons.attach_file_rounded, 'Pièce jointe', 'Un fichier', 'fichier pièce'),
  BlockChoice('pagelink', Icons.link_rounded, 'Lien vers une page', 'Mention d\'une autre page (@)', 'mention lien page'),
  BlockChoice('subpage', Icons.note_add_outlined, 'Sous-page', 'Nouvelle page dans celle-ci', 'sous-page page'),
  BlockChoice('database', Icons.table_chart_outlined, 'Base de données', 'Tableau d\'entrées avec propriétés', 'base données'),
];

/// Menu d'insertion. Renvoie la clé choisie (type de bloc ou action).
Future<String?> showBlockMenu(BuildContext context) =>
    showAdaptivePanel<String>(context, builder: (c) => const _BlockMenu(), width: 460);

class _BlockMenu extends StatefulWidget {
  const _BlockMenu();
  @override
  State<_BlockMenu> createState() => _BlockMenuState();
}

class _BlockMenuState extends State<_BlockMenu> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final nn = context.nn;
    final q = foldText(_q);
    final items = kBlockChoices
        .where((b) => q.isEmpty || foldText('${b.label} ${b.words}').contains(q))
        .toList();
    final big = !_isWide(context);
    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: TextField(
          autofocus: !big,
          onChanged: (v) => setState(() => _q = v),
          onSubmitted: (_) {
            if (items.isNotEmpty) Navigator.pop(context, items.first.key);
          },
          decoration: InputDecoration(
            hintText: 'Insérer un bloc…',
            isDense: true,
            prefixIcon: Icon(Icons.add_box_outlined, size: 20, color: nn.mid),
          ),
        ),
      ),
      Flexible(
        child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(8, 0, 8, 12), children: [
          for (final b in items)
            ListTile(
              key: ValueKey('insert-${b.key}'),
              minVerticalPadding: big ? 12 : 4,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              leading: Container(
                width: big ? 44 : 36,
                height: big ? 44 : 36,
                decoration: BoxDecoration(color: nn.card, borderRadius: BorderRadius.circular(12), border: Border.all(color: nn.line)),
                child: Icon(b.icon, size: big ? 22 : 19),
              ),
              title: Text(b.label, style: TextStyle(fontSize: big ? 16 : 14.5, fontWeight: FontWeight.w500)),
              subtitle: Text(b.hint, style: TextStyle(fontSize: 12.5, color: nn.mid)),
              onTap: () => Navigator.pop(context, b.key),
            ),
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.all(20),
              child: Text('Aucun bloc ne correspond', style: TextStyle(color: nn.mid)),
            ),
        ]),
      ),
    ]);
  }
}

// ==================================================================== choix d'une page
/// Recherche une page (mention, déplacement, ouverture rapide).
Future<Note?> pickPage(
  BuildContext context, {
  required String title,
  String hint = 'Rechercher une page…',
  String? excludeId,
  bool Function(Note n)? allow,
  String? rootLabel,
}) =>
    showAdaptivePanel<Note?>(
      context,
      builder: (c) => _PagePicker(
        title: title,
        hint: hint,
        excludeId: excludeId,
        allow: allow,
        rootLabel: rootLabel,
      ),
    );

/// Page spéciale renvoyée par [pickPage] quand l'utilisateur choisit « racine ».
final kRootChoice = Note(id: '__root__', title: '');

class _PagePicker extends StatefulWidget {
  const _PagePicker({required this.title, required this.hint, this.excludeId, this.allow, this.rootLabel});
  final String title;
  final String hint;
  final String? excludeId;
  final bool Function(Note n)? allow;
  final String? rootLabel;
  @override
  State<_PagePicker> createState() => _PagePickerState();
}

class _PagePickerState extends State<_PagePicker> {
  String _q = '';

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final repo = app.repo!;
    final nn = context.nn;
    final pages = repo.findPages(_q, excludeId: widget.excludeId, limit: 30).where((n) => widget.allow?.call(n) ?? true).toList();
    String path(Note n) {
      final a = repo.ancestorsOf(n.id);
      return a.isEmpty ? '' : a.map((x) => x.title.isEmpty ? 'Sans titre' : x.title).join(' › ');
    }

    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
        child: Text(widget.title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: TextField(
          autofocus: true,
          onChanged: (v) => setState(() => _q = v),
          onSubmitted: (_) {
            if (pages.isNotEmpty) Navigator.pop(context, pages.first);
          },
          decoration: InputDecoration(hintText: widget.hint, isDense: true, prefixIcon: Icon(Icons.search_rounded, size: 20, color: nn.mid)),
        ),
      ),
      Flexible(
        child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(8, 0, 8, 12), children: [
          if (widget.rootLabel != null)
            ListTile(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              leading: const Icon(Icons.vertical_align_top_rounded),
              title: Text(widget.rootLabel!),
              onTap: () => Navigator.pop(context, kRootChoice),
            ),
          for (final n in pages)
            ListTile(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              leading: PageIcon(note: n, size: 20),
              title: Text(n.title.isEmpty ? 'Sans titre' : n.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: path(n).isEmpty
                  ? null
                  : Text(path(n), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: nn.mid)),
              onTap: () => Navigator.pop(context, n),
            ),
          if (pages.isEmpty)
            Padding(padding: const EdgeInsets.all(20), child: Text('Aucune page trouvée', style: TextStyle(color: nn.mid))),
        ]),
      ),
    ]);
  }
}

/// Ouverture rapide (Ctrl+P).
Future<void> showQuickSwitcher(BuildContext context) async {
  final n = await pickPage(context, title: 'Aller à une page', hint: 'Titre de la page…');
  if (n != null && context.mounted) AppScope.read(context).openPage(n.id);
}

// ==================================================================== nouvelle page
/// Pictogrammes monochromes des modèles intégrés (style Nothing).
const kBuiltInTemplateIcons = <String, IconData>{
  'builtin:quick': Icons.bolt_rounded,
  'builtin:course': Icons.menu_book_rounded,
  'builtin:meeting': Icons.groups_rounded,
  'builtin:project': Icons.flag_outlined,
  'builtin:todo': Icons.checklist_rounded,
  'builtin:journal': Icons.edit_calendar_outlined,
  'builtin:revision': Icons.psychology_alt_outlined,
};

/// Icône d'un modèle : pictogramme pour les intégrés, emoji choisi sinon.
Widget templateIcon(PageTemplate t, {double size = 22}) {
  final i = kBuiltInTemplateIcons[t.id];
  if (i != null) return Icon(i, size: size);
  if (t.icon != null && t.icon!.isNotEmpty) return Text(t.icon!, style: TextStyle(fontSize: size - 2));
  return Icon(Icons.dashboard_customize_outlined, size: size);
}

/// Choix : page vide, base de données ou modèle. Renvoie la page créée.
Future<Note?> showNewPageSheet(BuildContext context, {String? parentId}) async {
  final app = AppScope.read(context);
  final repo = app.repo!;
  final choice = await showAdaptivePanel<String>(context, builder: (c) {
    final nn = c.nn;
    final big = !_isWide(c);
    Widget tile(String key, Widget leading, String title, String sub) => ListTile(
          key: ValueKey('new-$key'),
          minVerticalPadding: big ? 12 : 6,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          leading: SizedBox(width: 40, child: Center(child: leading)),
          title: Text(title, style: TextStyle(fontSize: big ? 16 : 14.5, fontWeight: FontWeight.w500)),
          subtitle: sub.isEmpty ? null : Text(sub, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: nn.mid)),
          onTap: () => Navigator.pop(c, key),
        );
    final custom = repo.templates().where((t) => !t.builtIn).toList();
    return ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(8, 16, 8, 16), children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
        child: Text(parentId == null ? 'Nouvelle page' : 'Nouvelle sous-page',
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
      ),
      tile('blank', const Icon(Icons.note_add_outlined), 'Page vide', big ? '' : 'Ctrl+N'),
      tile('database', const Icon(Icons.table_chart_outlined), 'Base de données', 'Entrées avec propriétés, vues tableau, liste et calendrier'),
      const Padding(padding: EdgeInsets.symmetric(horizontal: 12), child: SectionLabel('Modèles')),
      for (final t in builtInTemplates.skip(1)) tile('tpl:${t.id}', templateIcon(t), t.name, t.description),
      if (custom.isNotEmpty) ...[
        const Padding(padding: EdgeInsets.symmetric(horizontal: 12), child: SectionLabel('Mes modèles')),
        for (final t in custom) tile('tpl:${t.id}', templateIcon(t), t.name, t.description),
      ],
    ]);
  });
  if (choice == null || !context.mounted) return null;
  if (choice == 'blank') return app.newNote(parentId: parentId);
  if (choice == 'database') return app.newDatabase(parentId: parentId);
  final t = repo.templateById(choice.substring(4));
  if (t == null) return null;
  return app.newNote(template: t, parentId: parentId);
}

/// Petit choix d'emoji pour l'icône d'une page.
Future<String?> pickEmoji(BuildContext context) => showAdaptivePanel<String>(context, width: 420, builder: (c) {
      const emojis = [
        '📄', '📘', '📗', '📕', '📓', '🗒', '🗓', '📅', '✅', '☑️', '🎯', '🚀', '💡', '🧠', '📌', '📎', '🔖', '⭐', '❤️',
        '🔥', '⚡', '🔧', '⚙️', '🔌', '🔋', '💻', '📱', '🖥', '🧪', '📐', '📊', '📈', '🧾', '💶', '🏠', '🚗', '✈️', '🎵',
        '🎮', '🍽', '☕', '🌱', '🏃', '📷', '🎨', '🧩', '🗂', '📦', '🔒', '🌍',
      ];
      return Padding(
        padding: const EdgeInsets.all(20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Icône de la page', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
          const SizedBox(height: 14),
          Wrap(spacing: 4, runSpacing: 4, children: [
            for (final e in emojis)
              InkWell(
                borderRadius: BorderRadius.circular(10),
                onTap: () => Navigator.pop(c, e),
                child: SizedBox(width: 44, height: 44, child: Center(child: Text(e, style: const TextStyle(fontSize: 24)))),
              ),
          ]),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(onPressed: () => Navigator.pop(c, ''), child: const Text('Retirer l\'icône')),
          ),
        ]),
      );
    });

// ==================================================================== fil d'Ariane, sous-pages, rétroliens
class Breadcrumb extends StatelessWidget {
  const Breadcrumb({super.key, required this.ancestors, required this.onOpen});
  final List<Note> ancestors;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context) {
    if (ancestors.isEmpty) return const SizedBox.shrink();
    final nn = context.nn;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: [
        for (var i = 0; i < ancestors.length; i++) ...[
          if (i > 0) Icon(Icons.chevron_right_rounded, size: 16, color: nn.mid),
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => onOpen(ancestors[i].id),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                PageIcon(note: ancestors[i], size: 14),
                const SizedBox(width: 4),
                Text(ancestors[i].title.isEmpty ? 'Sans titre' : ancestors[i].title,
                    style: TextStyle(fontSize: 12.5, color: nn.mid)),
              ]),
            ),
          ),
        ],
        Icon(Icons.chevron_right_rounded, size: 16, color: nn.mid),
      ]),
    );
  }
}

class PageLinksSection extends StatelessWidget {
  const PageLinksSection({super.key, required this.label, required this.pages, required this.onOpen, this.onAdd, this.addLabel});
  final String label;
  final List<Note> pages;
  final ValueChanged<String> onOpen;
  final VoidCallback? onAdd;
  final String? addLabel;

  @override
  Widget build(BuildContext context) {
    final nn = context.nn;
    if (pages.isEmpty && onAdd == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(label, style: TextStyle(fontFamily: kFontMono, fontSize: 11, letterSpacing: 1.5, color: nn.mid)),
        const SizedBox(height: 6),
        for (final n in pages)
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => onOpen(n.id),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
              child: Row(children: [
                PageIcon(note: n, size: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(n.title.isEmpty ? 'Sans titre' : n.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(decoration: TextDecoration.underline, decorationColor: nn.line)),
                ),
              ]),
            ),
          ),
        if (onAdd != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add_rounded, size: 18),
              label: Text(addLabel ?? 'Ajouter'),
            ),
          ),
      ]),
    );
  }
}
