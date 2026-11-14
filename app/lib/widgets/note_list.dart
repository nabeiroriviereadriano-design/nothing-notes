import 'package:flutter/material.dart';
import 'package:notes_core/notes_core.dart';

import '../state/app_controller.dart';
import '../theme.dart';
import 'common.dart';
import 'dialogs.dart';

/// Barre de recherche avec raccourci Ctrl+F.
class SearchField extends StatefulWidget {
  const SearchField({super.key, this.autofocus = false});
  final bool autofocus;
  @override
  State<SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<SearchField> {
  final _ctl = TextEditingController();
  final _focus = FocusNode();
  AppController? _app;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = AppScope.read(context);
    if (_app != app) {
      _app?.searchFocusRequest.removeListener(_focusMe);
      _app = app;
      app.searchFocusRequest.addListener(_focusMe);
      _ctl.text = app.query;
    }
  }

  void _focusMe() {
    _focus.requestFocus();
    _ctl.selection = TextSelection(baseOffset: 0, extentOffset: _ctl.text.length);
  }

  @override
  void dispose() {
    _app?.searchFocusRequest.removeListener(_focusMe);
    _ctl.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final nn = context.nn;
    return TextField(
      controller: _ctl,
      focusNode: _focus,
      autofocus: widget.autofocus,
      onChanged: (v) {
        AppScope.read(context).setQuery(v);
        setState(() {});
      },
      textInputAction: TextInputAction.search,
      style: const TextStyle(fontSize: 14),
      decoration: InputDecoration(
        hintText: 'Rechercher une note…',
        isDense: true,
        prefixIcon: Icon(Icons.search_rounded, size: 20, color: nn.mid),
        suffixIcon: _ctl.text.isEmpty
            ? null
            : IconButton(
                onPressed: () {
                  _ctl.clear();
                  AppScope.read(context).setQuery('');
                  setState(() {});
                },
                icon: Icon(Icons.close_rounded, size: 18, color: nn.mid),
              ),
      ),
    );
  }
}

/// Menu de tri et de filtre.
class SortFilterButton extends StatelessWidget {
  const SortFilterButton({super.key});
  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final nn = context.nn;
    final active = app.filter != NoteFilter.none;
    return PopupMenuButton<String>(
      tooltip: 'Trier et filtrer',
      icon: Badge(
        isLabelVisible: active,
        smallSize: 7,
        backgroundColor: NColors.red,
        child: Icon(Icons.tune_rounded, color: nn.fg, size: 21),
      ),
      onSelected: (v) {
        if (v.startsWith('sort:')) {
          app.setSort(SortMode.values.firstWhere((s) => s.name == v.substring(5)));
        } else {
          app.setFilter(NoteFilter.values.firstWhere((f) => f.name == v.substring(7)));
        }
      },
      itemBuilder: (c) {
        PopupMenuItem<String> item(String value, String label, bool on) => PopupMenuItem(
              value: value,
              child: Row(children: [
                SizedBox(width: 22, child: on ? const RedDot(size: 7) : null),
                Text(label),
              ]),
            );
        return [
          const PopupMenuItem(enabled: false, height: 28, child: Text('TRIER PAR', style: TextStyle(fontSize: 11, letterSpacing: 1.2))),
          item('sort:modified', 'Date de modification', app.sort == SortMode.modified),
          item('sort:created', 'Date de création', app.sort == SortMode.created),
          item('sort:title', 'Titre', app.sort == SortMode.title),
          const PopupMenuDivider(),
          const PopupMenuItem(enabled: false, height: 28, child: Text('AFFICHER', style: TextStyle(fontSize: 11, letterSpacing: 1.2))),
          item('filter:none', 'Toutes', app.filter == NoteFilter.none),
          item('filter:checklists', 'Avec cases à cocher', app.filter == NoteFilter.checklists),
          item('filter:images', 'Avec images', app.filter == NoteFilter.images),
          item('filter:code', 'Avec code', app.filter == NoteFilter.code),
          item('filter:unsynced', 'Non synchronisées', app.filter == NoteFilter.unsynced),
        ];
      },
    );
  }
}

/// Ligne de puces « Toutes · Travail · BTS · + » (mobile).
class TagChipsRow extends StatelessWidget {
  const TagChipsRow({super.key});
  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final repo = app.repo!;
    final tags = repo.tags();
    return SizedBox(
      height: 42,
      child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 20), children: [
        FilterPill(label: 'Toutes', selected: app.view == NavView.all, onTap: () => app.showView(NavView.all)),
        const SizedBox(width: 8),
        FilterPill(label: 'Favoris', selected: app.view == NavView.favorites, onTap: () => app.showView(NavView.favorites)),
        for (final t in tags) ...[
          const SizedBox(width: 8),
          FilterPill(
            label: t.name,
            dot: parseHex(t.color),
            selected: app.view == NavView.tag && app.tagId == t.id,
            onTap: () => app.showView(NavView.tag, tag: t.id),
          ),
        ],
        const SizedBox(width: 8),
        IconButton.outlined(
          tooltip: 'Nouvelle étiquette',
          onPressed: () => editTagDialog(context, repo),
          icon: const Icon(Icons.add_rounded, size: 18),
          style: IconButton.styleFrom(side: BorderSide(color: context.nn.line)),
        ),
      ]),
    );
  }
}

/// Liste des notes de la vue courante.
class NoteList extends StatelessWidget {
  const NoteList({super.key, required this.onOpen, this.padding = const EdgeInsets.fromLTRB(16, 8, 16, 110)});
  final ValueChanged<Note> onOpen;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final notes = app.visibleNotes();
    final tags = {for (final t in app.repo!.tags()) t.id: t};
    if (notes.isEmpty) {
      if (app.query.isNotEmpty) {
        return EmptyState(icon: Icons.search_off_rounded, title: 'Aucun résultat', subtitle: '« ${app.query} »');
      }
      return switch (app.view) {
        NavView.trash => const EmptyState(icon: Icons.delete_outline_rounded, title: 'Corbeille vide'),
        NavView.archive => const EmptyState(icon: Icons.inventory_2_outlined, title: 'Aucune note archivée'),
        NavView.favorites => const EmptyState(
            icon: Icons.star_outline_rounded, title: 'Aucun favori', subtitle: 'Touchez l\'étoile d\'une note pour la retrouver ici.'),
        _ => const EmptyState(
            icon: Icons.edit_note_rounded, title: 'Aucune note', subtitle: 'Créez votre première note avec le bouton +.'),
      };
    }
    return Column(children: [
      if (app.view == NavView.trash)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Row(children: [
            Expanded(
              child: Text('Supprimées définitivement après 30 jours',
                  style: TextStyle(fontSize: 12.5, color: context.nn.mid)),
            ),
            TextButton(
              onPressed: () async {
                if (await confirm(context,
                    title: 'Vider la corbeille ?',
                    message: '${notes.length} note(s) seront supprimées définitivement sur tous vos appareils.',
                    ok: 'Vider',
                    danger: true)) {
                  app.repo!.emptyTrash();
                  app.select(null);
                }
              },
              child: const Text('Vider', style: TextStyle(color: NColors.red)),
            ),
          ]),
        ),
      Expanded(
        child: ListView.builder(
          padding: padding,
          itemCount: notes.length,
          itemBuilder: (c, i) => NoteCard(
            key: ValueKey(notes[i].id),
            note: notes[i],
            tags: tags,
            selected: notes[i].id == app.selectedNoteId,
            onTap: () => onOpen(notes[i]),
          ),
        ),
      ),
    ]);
  }
}

class NoteCard extends StatefulWidget {
  const NoteCard({super.key, required this.note, required this.tags, required this.selected, required this.onTap});
  final Note note;
  final Map<String, Tag> tags;
  final bool selected;
  final VoidCallback onTap;
  @override
  State<NoteCard> createState() => _NoteCardState();
}

class _NoteCardState extends State<NoteCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final n = widget.note;
    final nn = context.nn;
    final sel = widget.selected;
    final tagNames = n.tags.map((t) => widget.tags[t]?.name).whereType<String>().toList();
    final subtitle = tagNames.isNotEmpty && n.preview.isEmpty ? tagNames.join(' · ') : n.preview;
    final fg = nn.fg;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0.96, end: 1),
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        builder: (c, v, child) => Transform.scale(scale: v, child: Opacity(opacity: ((v - 0.96) / 0.04).clamp(0, 1), child: child)),
        child: MouseRegion(
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            decoration: BoxDecoration(
              color: sel || _hover ? nn.cardHover : nn.card,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(color: sel ? nn.mid : nn.line),
            ),
            clipBehavior: Clip.antiAlias,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: widget.onTap,
                onLongPress: () => _actions(context),
                onSecondaryTap: () => _actions(context),
                child: Stack(children: [
                  if (sel) Positioned(left: 0, top: 0, bottom: 0, child: Container(width: 3, color: NColors.red)),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 14, 14),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 2, right: 14),
                        child: Icon(noteIcon(n), size: 26, color: fg),
                      ),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Row(children: [
                            Expanded(
                              child: Text(
                                n.title.trim().isEmpty ? 'Sans titre' : n.title.trim(),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: n.title.trim().isEmpty ? nn.mid : fg),
                              ),
                            ),
                            if (n.favorite) ...[
                              const SizedBox(width: 6),
                              const Icon(Icons.star_rounded, size: 15, color: NColors.red),
                            ],
                            if (n.hasConflict) ...[
                              const SizedBox(width: 6),
                              const Tooltip(message: 'Conflit à résoudre', child: Icon(Icons.call_split_rounded, size: 15, color: NColors.red)),
                            ] else if (n.dirty) ...[
                              const SizedBox(width: 6),
                              Tooltip(
                                message: 'En attente de synchronisation',
                                child: Icon(Icons.cloud_upload_outlined, size: 15, color: nn.mid),
                              ),
                            ],
                          ]),
                          if (subtitle.isNotEmpty) ...[
                            const SizedBox(height: 3),
                            Text(subtitle,
                                maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, color: nn.mid)),
                          ],
                          const SizedBox(height: 6),
                          Row(children: [
                            Text(formatDate(n.updatedAt), style: TextStyle(fontSize: 11.5, color: nn.mid)),
                            const SizedBox(width: 8),
                            for (final t in n.tags.take(3))
                              if (widget.tags[t] != null)
                                Padding(
                                  padding: const EdgeInsets.only(right: 4),
                                  child: RedDot(size: 6, color: parseHex(widget.tags[t]!.color) ?? nn.mid),
                                ),
                          ]),
                        ]),
                      ),
                    ]),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _actions(BuildContext context) async {
    final app = AppScope.read(context);
    final repo = app.repo!;
    final n = widget.note;
    final v = await showModalBottomSheet<String>(
      context: context,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (!n.trashed) ...[
            ListTile(
              leading: Icon(n.favorite ? Icons.star_rounded : Icons.star_outline_rounded),
              title: Text(n.favorite ? 'Retirer des favoris' : 'Ajouter aux favoris'),
              onTap: () => Navigator.pop(c, 'fav'),
            ),
            ListTile(leading: const Icon(Icons.sell_outlined), title: const Text('Étiquettes…'), onTap: () => Navigator.pop(c, 'tags')),
            ListTile(leading: const Icon(Icons.folder_outlined), title: const Text('Déplacer…'), onTap: () => Navigator.pop(c, 'move')),
            ListTile(
              leading: const Icon(Icons.inventory_2_outlined),
              title: Text(n.archived ? 'Désarchiver' : 'Archiver'),
              onTap: () => Navigator.pop(c, 'archive'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline_rounded, color: NColors.red),
              title: const Text('Mettre à la corbeille', style: TextStyle(color: NColors.red)),
              onTap: () => Navigator.pop(c, 'trash'),
            ),
          ] else ...[
            ListTile(leading: const Icon(Icons.restore_rounded), title: const Text('Restaurer'), onTap: () => Navigator.pop(c, 'restore')),
            ListTile(
              leading: const Icon(Icons.delete_forever_outlined, color: NColors.red),
              title: const Text('Supprimer définitivement', style: TextStyle(color: NColors.red)),
              onTap: () => Navigator.pop(c, 'purge'),
            ),
          ],
        ]),
      ),
    );
    if (!context.mounted) return;
    switch (v) {
      case 'fav':
        repo.setFavorite(n.id, !n.favorite);
      case 'tags':
        await showTagPicker(context, repo, n.id);
      case 'move':
        final (ok, folder) = await pickFolder(context, repo, current: n.folderId);
        if (ok) repo.moveToFolder(n.id, folder);
      case 'archive':
        repo.setArchived(n.id, !n.archived);
      case 'trash':
        repo.trashNote(n.id);
        if (app.selectedNoteId == n.id) app.select(null);
        if (context.mounted) toast(context, 'Note mise à la corbeille');
      case 'restore':
        repo.restoreNote(n.id);
      case 'purge':
        if (await confirm(context,
            title: 'Supprimer définitivement ?',
            message: 'Cette note sera supprimée sur tous vos appareils.',
            ok: 'Supprimer',
            danger: true)) {
          repo.purgeNote(n.id);
          if (app.selectedNoteId == n.id) app.select(null);
        }
    }
  }
}
