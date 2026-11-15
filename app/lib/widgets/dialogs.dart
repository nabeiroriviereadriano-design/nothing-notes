import 'package:flutter/material.dart';
import 'package:notes_core/notes_core.dart';

import '../theme.dart';
import 'common.dart';

/// Feuille de choix des étiquettes d'une note (avec création).
Future<void> showTagPicker(BuildContext context, NotesRepository repo, String noteId) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (c) => _TagPicker(repo: repo, noteId: noteId),
  );
}

class _TagPicker extends StatefulWidget {
  const _TagPicker({required this.repo, required this.noteId});
  final NotesRepository repo;
  final String noteId;
  @override
  State<_TagPicker> createState() => _TagPickerState();
}

class _TagPickerState extends State<_TagPicker> {
  final _ctl = TextEditingController();
  String _color = kLabelColors.first;

  @override
  Widget build(BuildContext context) {
    final note = widget.repo.note(widget.noteId);
    final tags = widget.repo.tags();
    final selected = note?.tags.toSet() ?? {};
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.of(context).viewInsets.bottom),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        const DotTitle('Étiquettes', size: 22),
        const SizedBox(height: 16),
        if (tags.isEmpty) Text('Aucune étiquette pour l\'instant.', style: TextStyle(color: context.nn.mid)),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final t in tags)
            TagPill(
              tag: t,
              selected: selected.contains(t.id),
              onTap: () {
                final next = selected.contains(t.id)
                    ? note!.tags.where((x) => x != t.id).toList()
                    : [...note!.tags, t.id];
                widget.repo.setTags(widget.noteId, next);
                setState(() {});
              },
            ),
        ]),
        const SizedBox(height: 20),
        Row(children: [
          Expanded(
            child: TextField(
              controller: _ctl,
              decoration: const InputDecoration(hintText: 'Nouvelle étiquette'),
              onSubmitted: (_) => _create(),
            ),
          ),
          const SizedBox(width: 10),
          IconButton.filled(onPressed: _create, icon: const Icon(Icons.add_rounded)),
        ]),
        const SizedBox(height: 12),
        ColorChoice(value: _color, onChanged: (v) => setState(() => _color = v ?? kLabelColors.first)),
      ]),
    );
  }

  void _create() {
    final name = _ctl.text.trim();
    if (name.isEmpty) return;
    final t = widget.repo.createTag(name, color: _color);
    final note = widget.repo.note(widget.noteId);
    if (note != null && !note.tags.contains(t.id)) widget.repo.setTags(widget.noteId, [...note.tags, t.id]);
    _ctl.clear();
    setState(() {});
  }
}

/// Choix d'un dossier (null = racine). Retourne `false` si annulé.
Future<(bool, String?)> pickFolder(BuildContext context, NotesRepository repo, {String? current}) async {
  final folders = repo.folders();
  final r = await showModalBottomSheet<(bool, String?)>(
    context: context,
    builder: (c) {
      List<Widget> branch(String? parent, int depth) => [
            for (final f in folders.where((f) => f.parentId == parent)) ...[
              ListTile(
                contentPadding: EdgeInsets.only(left: 20.0 + depth * 22, right: 20),
                leading: Icon(Icons.folder_outlined, color: parseHex(f.color) ?? context.nn.fg),
                title: Text(f.name),
                trailing: current == f.id ? const RedDot() : null,
                onTap: () => Navigator.pop(c, (true, f.id)),
              ),
              ...branch(f.id, depth + 1),
            ],
          ];
      return SafeArea(
        child: ListView(shrinkWrap: true, children: [
          const Padding(padding: EdgeInsets.fromLTRB(20, 0, 20, 8), child: DotTitle('Dossier', size: 22)),
          ListTile(
            contentPadding: const EdgeInsets.symmetric(horizontal: 20),
            leading: const Icon(Icons.inbox_outlined),
            title: const Text('Aucun dossier'),
            trailing: current == null ? const RedDot() : null,
            onTap: () => Navigator.pop(c, (true, null)),
          ),
          ...branch(null, 0),
          if (folders.isEmpty)
            Padding(
              padding: const EdgeInsets.all(20),
              child: Text('Créez un dossier depuis le menu de navigation.', style: TextStyle(color: context.nn.mid)),
            ),
        ]),
      );
    },
  );
  return r ?? (false, null);
}

/// Création / modification d'un dossier.
Future<void> editFolderDialog(BuildContext context, NotesRepository repo, {Folder? folder, String? parentId}) async {
  final ctl = TextEditingController(text: folder?.name ?? '');
  String? color = folder?.color;
  await showDialog<void>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, setS) => AlertDialog(
        title: Text(folder == null ? (parentId == null ? 'Nouveau dossier' : 'Nouveau sous-dossier') : 'Modifier le dossier',
            style: const TextStyle(fontWeight: FontWeight.w600)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: ctl, autofocus: true, decoration: const InputDecoration(hintText: 'Nom')),
          const SizedBox(height: 16),
          ColorChoice(value: color, onChanged: (v) => setS(() => color = v)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Annuler')),
          FilledButton(
            onPressed: () {
              final name = ctl.text.trim();
              if (name.isEmpty) return;
              if (folder == null) {
                repo.createFolder(name, parentId: parentId, color: color);
              } else {
                folder
                  ..name = name
                  ..color = color;
                repo.updateFolder(folder);
              }
              Navigator.pop(c);
            },
            child: const Text('Enregistrer'),
          ),
        ],
      ),
    ),
  );
}

Future<void> editTagDialog(BuildContext context, NotesRepository repo, {Tag? tag}) async {
  final ctl = TextEditingController(text: tag?.name ?? '');
  String? color = tag?.color ?? kLabelColors.first;
  await showDialog<void>(
    context: context,
    builder: (c) => StatefulBuilder(
      builder: (c, setS) => AlertDialog(
        title: Text(tag == null ? 'Nouvelle étiquette' : 'Modifier l\'étiquette',
            style: const TextStyle(fontWeight: FontWeight.w600)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: ctl, autofocus: true, decoration: const InputDecoration(hintText: 'Nom')),
          const SizedBox(height: 16),
          ColorChoice(value: color, onChanged: (v) => setS(() => color = v)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Annuler')),
          FilledButton(
            onPressed: () {
              final name = ctl.text.trim();
              if (name.isEmpty) return;
              if (tag == null) {
                repo.createTag(name, color: color);
              } else {
                tag
                  ..name = name
                  ..color = color;
                repo.updateTag(tag);
              }
              Navigator.pop(c);
            },
            child: const Text('Enregistrer'),
          ),
        ],
      ),
    ),
  );
}

/// Comparaison des deux versions en conflit et choix de l'utilisateur.
Future<void> showConflictDialog(BuildContext context, NotesRepository repo, String noteId) async {
  final rec = repo.store.get(EntityType.notes, noteId);
  final otherRow = rec?.conflictRow;
  if (rec == null || otherRow == null) return;
  final mine = Note.fromRow(rec.data);
  final other = Note.fromRow(otherRow);
  final choice = await showDialog<ConflictChoice>(
    context: context,
    builder: (c) {
      Widget side(String label, Note n) => Expanded(
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: c.nn.bg,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: c.nn.line),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(label.toUpperCase(),
                    style: TextStyle(fontFamily: kFontMono, fontSize: 11, letterSpacing: 1.4, color: c.nn.mid)),
                const SizedBox(height: 4),
                Text(formatDate(n.updatedAt), style: TextStyle(fontSize: 12, color: c.nn.mid)),
                const SizedBox(height: 10),
                Text(n.purged ? '(supprimée définitivement)' : (n.title.isEmpty ? 'Sans titre' : n.title),
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Expanded(
                  child: SingleChildScrollView(
                    child: Text(plainText(n.blocks), style: const TextStyle(fontSize: 13.5, height: 1.45)),
                  ),
                ),
              ]),
            ),
          );
      return AlertDialog(
        title: const Text('Modifiée sur deux appareils', style: TextStyle(fontWeight: FontWeight.w600)),
        content: SizedBox(
          width: 720,
          height: 380,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              'Cette note a été modifiée ici et sur un autre appareil avant d\'être synchronisée. '
              'Rien n\'a été écrasé : choisissez la version à conserver.',
              style: TextStyle(color: c.nn.mid, fontSize: 13.5),
            ),
            const SizedBox(height: 14),
            Expanded(
              child: MediaQuery.of(c).size.width < 600
                  ? Column(children: [side('Cet appareil', mine), const SizedBox(height: 10), side('Autre appareil', other)])
                  : Row(children: [side('Cet appareil', mine), const SizedBox(width: 12), side('Autre appareil', other)]),
            ),
          ]),
        ),
        actionsOverflowButtonSpacing: 8,
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Plus tard')),
          OutlinedButton(onPressed: () => Navigator.pop(c, ConflictChoice.keepOther), child: const Text('Garder l\'autre')),
          OutlinedButton(onPressed: () => Navigator.pop(c, ConflictChoice.keepMine), child: const Text('Garder la mienne')),
          FilledButton(onPressed: () => Navigator.pop(c, ConflictChoice.keepBoth), child: const Text('Garder les deux')),
        ],
      );
    },
  );
  if (choice != null) await repo.resolveConflict(noteId, choice);
}

/// Historique des versions enregistrées sur le serveur.
Future<void> showHistoryDialog(BuildContext context, NotesRepository repo, String noteId) {
  return showDialog<void>(context: context, builder: (c) => _HistoryDialog(repo: repo, noteId: noteId));
}

class _HistoryDialog extends StatefulWidget {
  const _HistoryDialog({required this.repo, required this.noteId});
  final NotesRepository repo;
  final String noteId;
  @override
  State<_HistoryDialog> createState() => _HistoryDialogState();
}

class _HistoryDialogState extends State<_HistoryDialog> {
  late final Future<List<NoteVersion>> _future = Future.value(widget.repo.history(widget.noteId));
  NoteVersion? _selected;

  @override
  Widget build(BuildContext context) {
    final n = context.nn;
    return AlertDialog(
      title: const Text('Historique des versions', style: TextStyle(fontWeight: FontWeight.w600)),
      content: SizedBox(
        width: 720,
        height: 420,
        child: FutureBuilder<List<NoteVersion>>(
          future: _future,
          builder: (c, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator(strokeWidth: 2));
            }
            final versions = snap.data!;
            if (versions.isEmpty) {
              return const EmptyState(
                icon: Icons.history_rounded,
                title: 'Aucune version antérieure',
                subtitle: 'Les versions précédentes apparaissent ici après chaque modification.',
              );
            }
            _selected ??= versions.first;
            final list = ListView(children: [
              for (final v in versions)
                ListTile(
                  selected: identical(v, _selected),
                  selectedTileColor: n.cardHover,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  title: Text(formatDate(v.savedAt), style: const TextStyle(fontSize: 14)),
                  subtitle: Text(
                    switch (v.reason) {
                      'conflict' => 'Version écartée lors d\'un conflit',
                      'sync' || 'merge' => 'Avant une modification reçue d\'un autre appareil',
                      'restore' => 'Avant une restauration',
                      _ => v.title.isEmpty ? 'Sans titre' : v.title,
                    },
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: n.mid, fontSize: 12.5),
                  ),
                  onTap: () => setState(() => _selected = v),
                ),
            ]);
            final preview = Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                  color: n.bg, borderRadius: BorderRadius.circular(16), border: Border.all(color: n.line)),
              child: SingleChildScrollView(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(_selected!.title.isEmpty ? 'Sans titre' : _selected!.title,
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                  const SizedBox(height: 8),
                  Text(plainText(_selected!.blocks), style: const TextStyle(fontSize: 13.5, height: 1.45)),
                ]),
              ),
            );
            return MediaQuery.of(context).size.width < 600
                ? Column(children: [Expanded(child: list), const SizedBox(height: 10), Expanded(child: preview)])
                : Row(children: [SizedBox(width: 240, child: list), const SizedBox(width: 12), Expanded(child: preview)]);
          },
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Fermer')),
        FilledButton(
          onPressed: _selected == null
              ? null
              : () {
                  widget.repo.restoreVersion(widget.noteId, _selected!);
                  Navigator.pop(context);
                  toast(context, 'Version restaurée');
                },
          child: const Text('Restaurer cette version'),
        ),
      ],
    );
  }
}
