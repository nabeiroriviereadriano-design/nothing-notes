import 'package:flutter/material.dart';
import 'package:notes_core/notes_core.dart';

import '../state/app_controller.dart';
import '../theme.dart';
import 'common.dart';
import 'dialogs.dart';
import '../screens/devices_screen.dart';

/// Colonne de navigation : notes, favoris, dossiers, étiquettes, archives,
/// corbeille, paramètres.
class Sidebar extends StatelessWidget {
  const Sidebar({super.key, this.onNavigate, required this.onSettings, this.showHeader = true});
  final VoidCallback? onNavigate;
  final VoidCallback onSettings;
  final bool showHeader;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final repo = app.repo!;
    final nn = context.nn;
    final c = app.counts();
    final folders = repo.folders();
    final tags = repo.tags();

    void go(NavView v, {String? folder, String? tag}) {
      app.showView(v, folder: folder, tag: tag);
      onNavigate?.call();
    }

    List<Widget> folderBranch(String? parent, int depth) => [
          for (final f in folders.where((f) => f.parentId == parent)) ...[
            _NavItem(
              icon: Icons.folder_outlined,
              iconColor: parseHex(f.color),
              label: f.name,
              count: c.folders[f.id],
              indent: depth * 16.0,
              selected: app.view == NavView.folder && app.folderId == f.id,
              onTap: () => go(NavView.folder, folder: f.id),
              menu: (ctx) => _folderMenu(ctx, repo, f, app),
            ),
            ...folderBranch(f.id, depth + 1),
          ],
        ];

    return Container(
      color: nn.panel,
      child: SafeArea(
        right: false,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (showHeader)
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 22, 20, 18),
              child: Row(children: [NothingLogo(size: 30), SizedBox(width: 12), DotTitle('Notes', size: 24)]),
            ),
          Expanded(
            child: ListView(padding: const EdgeInsets.symmetric(horizontal: 12), children: [
              _NavItem(
                icon: Icons.grid_view_rounded,
                label: 'Toutes les notes',
                count: c.all,
                selected: app.view == NavView.all,
                onTap: () => go(NavView.all),
              ),
              _NavItem(
                icon: Icons.history_rounded,
                label: 'Récents',
                selected: app.view == NavView.recent,
                onTap: () => go(NavView.recent),
              ),
              _NavItem(
                icon: Icons.star_outline_rounded,
                label: 'Favoris',
                count: c.favorites,
                selected: app.view == NavView.favorites,
                onTap: () => go(NavView.favorites),
              ),
              _NavItem(
                icon: Icons.task_alt_rounded,
                label: 'Tâches',
                count: c.tasks,
                selected: app.view == NavView.tasks,
                onTap: () => go(NavView.tasks),
              ),
              _NavItem(
                icon: Icons.dashboard_customize_outlined,
                label: 'Modèles',
                count: c.templates,
                selected: app.view == NavView.templates,
                onTap: () => go(NavView.templates),
              ),
              _PageTree(onNavigate: onNavigate),
              _Group(
                icon: Icons.folder_open_outlined,
                label: 'Dossiers',
                onAdd: () => editFolderDialog(context, repo),
                children: folders.isEmpty
                    ? [_Hint('Aucun dossier')]
                    : folderBranch(null, 0),
              ),
              _Group(
                icon: Icons.sell_outlined,
                label: 'Étiquettes',
                onAdd: () => editTagDialog(context, repo),
                children: tags.isEmpty
                    ? [_Hint('Aucune étiquette')]
                    : [
                        for (final t in tags)
                          _NavItem(
                            dot: parseHex(t.color) ?? nn.mid,
                            label: t.name,
                            count: c.tags[t.id],
                            selected: app.view == NavView.tag && app.tagId == t.id,
                            onTap: () => go(NavView.tag, tag: t.id),
                            menu: (ctx) => _tagMenu(ctx, repo, t, app),
                          ),
                      ],
              ),
              Divider(color: nn.line, height: 24, indent: 8, endIndent: 8),
              _NavItem(
                icon: Icons.inventory_2_outlined,
                label: 'Archives',
                count: c.archive,
                selected: app.view == NavView.archive,
                onTap: () => go(NavView.archive),
              ),
              _NavItem(
                icon: Icons.delete_outline_rounded,
                label: 'Corbeille',
                count: c.trash,
                selected: app.view == NavView.trash,
                onTap: () => go(NavView.trash),
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
            child: SyncBadge(
              status: app.syncStatus,
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const DevicesScreen())),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
            child: _NavItem(icon: Icons.settings_outlined, label: 'Paramètres', selected: false, onTap: onSettings),
          ),
        ]),
      ),
    );
  }

  Future<void> _folderMenu(BuildContext context, NotesRepository repo, Folder f, AppController app) async {
    final v = await _contextSheet(context, f.name, const [
      ('sub', Icons.create_new_folder_outlined, 'Nouveau sous-dossier'),
      ('edit', Icons.edit_outlined, 'Renommer / couleur'),
      ('del', Icons.delete_outline_rounded, 'Supprimer le dossier'),
    ]);
    if (!context.mounted) return;
    switch (v) {
      case 'sub':
        await editFolderDialog(context, repo, parentId: f.id);
      case 'edit':
        await editFolderDialog(context, repo, folder: f);
      case 'del':
        if (await confirm(context,
            title: 'Supprimer « ${f.name} » ?',
            message: 'Le dossier et ses sous-dossiers seront supprimés. Les notes qu\'ils contiennent sont conservées.',
            ok: 'Supprimer',
            danger: true)) {
          repo.deleteFolder(f.id);
          if (app.view == NavView.folder) app.showView(NavView.all);
        }
    }
  }

  Future<void> _tagMenu(BuildContext context, NotesRepository repo, Tag t, AppController app) async {
    final v = await _contextSheet(context, t.name, const [
      ('edit', Icons.edit_outlined, 'Renommer / couleur'),
      ('del', Icons.delete_outline_rounded, 'Supprimer l\'étiquette'),
    ]);
    if (!context.mounted) return;
    switch (v) {
      case 'edit':
        await editTagDialog(context, repo, tag: t);
      case 'del':
        if (await confirm(context,
            title: 'Supprimer « ${t.name} » ?',
            message: 'L\'étiquette sera retirée de toutes les notes. Les notes sont conservées.',
            ok: 'Supprimer',
            danger: true)) {
          repo.deleteTag(t.id);
          if (app.view == NavView.tag) app.showView(NavView.all);
        }
    }
  }
}

Future<String?> _contextSheet(BuildContext context, String title, List<(String, IconData, String)> items) {
  return showModalBottomSheet<String>(
    context: context,
    builder: (c) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
        ),
        for (final (v, icon, label) in items)
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 24),
            leading: Icon(icon, color: v == 'del' ? NColors.red : null),
            title: Text(label, style: TextStyle(color: v == 'del' ? NColors.red : null)),
            onTap: () => Navigator.pop(c, v),
          ),
      ]),
    ),
  );
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    this.icon,
    this.iconColor,
    this.dot,
    required this.label,
    this.count,
    required this.selected,
    required this.onTap,
    this.indent = 0,
    this.menu,
  });
  final IconData? icon;
  final Color? iconColor;
  final Color? dot;
  final String label;
  final int? count;
  final bool selected;
  final VoidCallback onTap;
  final double indent;
  final Future<void> Function(BuildContext)? menu;

  @override
  Widget build(BuildContext context) {
    final nn = context.nn;
    final fg = selected ? nn.invertedFg : nn.fg;
    return Padding(
      padding: EdgeInsets.only(left: indent, bottom: 2),
      child: Stack(children: [
        Material(
        color: selected ? nn.invertedBg : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          onLongPress: menu == null ? null : () => menu!(context),
          onSecondaryTap: menu == null ? null : () => menu!(context),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(children: [
              if (icon != null) Icon(icon, size: 19, color: selected ? fg : (iconColor ?? fg)),
              if (dot != null) Padding(padding: const EdgeInsets.symmetric(horizontal: 5), child: RedDot(size: 9, color: dot)),
              const SizedBox(width: 12),
              Expanded(
                child: Text(label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: fg)),
              ),
              if (count != null && count! > 0)
                Text('$count',
                    style: TextStyle(
                        fontSize: 12.5,
                        color: selected ? fg : nn.mid,
                        fontFeatures: const [FontFeature.tabularFigures()])),
            ]),
          ),
        ),
      ),
        // Repère rouge de l'élément actif.
        if (selected)
          const Positioned(left: 4, top: 12, bottom: 12, child: SizedBox(width: 3, child: ColoredBox(color: NColors.red))),
      ]),
    );
  }
}

/// Arborescence des pages qui ont des sous-pages (et des bases de données).
class _PageTree extends StatelessWidget {
  const _PageTree({this.onNavigate});
  final VoidCallback? onNavigate;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final repo = app.repo!;
    final all = repo.allNotes().where((n) => !n.trashed && !n.isTemplate && !n.archived).toList();
    final byId = {for (final n in all) n.id: n};
    final kids = <String, List<Note>>{};
    for (final n in all) {
      if (n.parentId != null && byId.containsKey(n.parentId)) kids.putIfAbsent(n.parentId!, () => []).add(n);
    }
    final roots = all
        .where((n) => (n.parentId == null || !byId.containsKey(n.parentId)) && (kids.containsKey(n.id) || n.isDatabase))
        .toList()
      ..sort((a, b) => foldText(a.title).compareTo(foldText(b.title)));
    if (roots.isEmpty) return const SizedBox.shrink();

    List<Widget> branch(Note n, int depth, Set<String> seen) {
      if (!seen.add(n.id) || depth > 8) return const [];
      final children = [...?kids[n.id]]..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      return [
        _TreeNode(
          note: n,
          depth: depth,
          hasChildren: children.isNotEmpty,
          selected: app.selectedNoteId == n.id,
          onTap: () {
            app.openPage(n.id);
            onNavigate?.call();
          },
          children: [for (final c in children) ...branch(c, depth + 1, seen)],
        ),
      ];
    }

    final seen = <String>{};
    return _Group(
      icon: Icons.account_tree_outlined,
      label: 'Pages',
      onAdd: () {
        app.newNote();
        onNavigate?.call();
      },
      children: [for (final r in roots.take(40)) ...branch(r, 0, seen)],
    );
  }
}

class _TreeNode extends StatefulWidget {
  const _TreeNode({
    required this.note,
    required this.depth,
    required this.hasChildren,
    required this.selected,
    required this.onTap,
    required this.children,
  });
  final Note note;
  final int depth;
  final bool hasChildren;
  final bool selected;
  final VoidCallback onTap;
  final List<Widget> children;

  @override
  State<_TreeNode> createState() => _TreeNodeState();
}

class _TreeNodeState extends State<_TreeNode> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final nn = context.nn;
    final n = widget.note;
    final fg = widget.selected ? nn.invertedFg : nn.fg;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: EdgeInsets.only(left: widget.depth * 14.0, bottom: 2),
        child: Material(
          color: widget.selected ? nn.invertedBg : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: widget.onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
              child: Row(children: [
                SizedBox(
                  width: 28,
                  height: 28,
                  child: widget.hasChildren
                      ? IconButton(
                          padding: EdgeInsets.zero,
                          iconSize: 18,
                          tooltip: _open ? 'Replier' : 'Déplier',
                          onPressed: () => setState(() => _open = !_open),
                          icon: Icon(_open ? Icons.expand_more_rounded : Icons.chevron_right_rounded, color: fg),
                        )
                      : null,
                ),
                PageIcon(note: n, size: 16, color: fg),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(n.title.isEmpty ? 'Sans titre' : n.title,
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13.5, color: fg)),
                ),
              ]),
            ),
          ),
        ),
      ),
      if (_open) ...widget.children,
    ]);
  }
}

class _Group extends StatefulWidget {
  const _Group({required this.icon, required this.label, required this.children, required this.onAdd});
  final IconData icon;
  final String label;
  final List<Widget> children;
  final VoidCallback onAdd;
  @override
  State<_Group> createState() => _GroupState();
}

class _GroupState extends State<_Group> {
  bool _open = true;
  @override
  Widget build(BuildContext context) {
    final nn = context.nn;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => setState(() => _open = !_open),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
          child: Row(children: [
            Icon(widget.icon, size: 19),
            const SizedBox(width: 12),
            Expanded(child: Text(widget.label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500))),
            InkWell(
              customBorder: const CircleBorder(),
              onTap: widget.onAdd,
              child: Padding(padding: const EdgeInsets.all(4), child: Icon(Icons.add_rounded, size: 18, color: nn.mid)),
            ),
            Icon(_open ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 20, color: nn.mid),
          ]),
        ),
      ),
      AnimatedSize(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        child: _open
            ? Padding(padding: const EdgeInsets.only(left: 12), child: Column(children: widget.children))
            : const SizedBox(width: double.infinity),
      ),
    ]);
  }
}

class _Hint extends StatelessWidget {
  const _Hint(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
        child: Text(text, style: TextStyle(color: context.nn.mid, fontSize: 13)),
      );
}
