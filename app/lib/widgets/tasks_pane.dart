import 'package:flutter/material.dart';
import 'package:notes_core/notes_core.dart';

import '../state/app_controller.dart';
import '../theme.dart';
import 'common.dart';
import 'pages_ui.dart';

String dayLabel(DateTime d) {
  const months = ['janv.', 'févr.', 'mars', 'avr.', 'mai', 'juin', 'juil.', 'août', 'sept.', 'oct.', 'nov.', 'déc.'];
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final diff = DateTime(d.year, d.month, d.day).difference(today).inDays;
  if (diff == 0) return 'Aujourd\'hui';
  if (diff == 1) return 'Demain';
  if (diff == -1) return 'Hier';
  return '${d.day} ${months[d.month - 1]}${d.year != now.year ? ' ${d.year}' : ''}';
}

/// Pastille compacte d'une tâche suivie : statut, échéance, priorité.
class TaskChips extends StatelessWidget {
  const TaskChips({super.key, required this.info, this.onTap});
  final TaskInfo info;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final nn = context.nn;
    final now = DateTime.now();
    final overdue = info.status != TaskStatus.done && info.due != null && info.due!.isBefore(DateTime(now.year, now.month, now.day));
    final chips = <Widget>[
      _chip(context, TaskStatus.label(info.status),
          color: info.status == TaskStatus.doing ? nn.fg : nn.mid, border: info.status == TaskStatus.doing ? nn.fg : nn.line),
      if (info.due != null)
        _chip(context, dayLabel(info.due!),
            icon: Icons.event_rounded,
            color: overdue ? redText(context) : nn.mid,
            border: overdue ? NColors.red : nn.line),
      if (info.priority > 0) PriorityBadge(info.priority),
    ];
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: chips),
    );
  }

  Widget _chip(BuildContext context, String text, {IconData? icon, required Color color, required Color border}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(999), border: Border.all(color: border)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[Icon(icon, size: 12, color: color), const SizedBox(width: 4)],
          Text(text, style: TextStyle(fontSize: 11.5, color: color, fontWeight: FontWeight.w500)),
        ]),
      );
}

/// Réglages d'une tâche suivie (statut, échéance, priorité, arrêt du suivi).
Future<void> showTaskSheet(BuildContext context, NotesRepository repo, String noteId, String blockId) async {
  await showAdaptivePanel<void>(context, width: 440, builder: (c) => _TaskSheet(repo: repo, noteId: noteId, blockId: blockId));
}

class _TaskSheet extends StatefulWidget {
  const _TaskSheet({required this.repo, required this.noteId, required this.blockId});
  final NotesRepository repo;
  final String noteId;
  final String blockId;
  @override
  State<_TaskSheet> createState() => _TaskSheetState();
}

class _TaskSheetState extends State<_TaskSheet> {
  Block? get _block => widget.repo.note(widget.noteId)?.blocks.where((b) => b.id == widget.blockId).firstOrNull;

  @override
  Widget build(BuildContext context) {
    final nn = context.nn;
    final b = _block;
    if (b == null) return const SizedBox(height: 80, child: Center(child: Text('Tâche introuvable')));
    final t = b.task ?? TaskInfo(status: b.checked ? TaskStatus.done : TaskStatus.todo);
    final repo = widget.repo;
    void upd({String? status, DateTime? due, bool clearDue = false, int? priority}) {
      repo.updateTask(widget.noteId, widget.blockId, status: status, due: due, clearDue: clearDue, priority: priority);
      setState(() {});
    }

    return ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(20, 18, 20, 20), children: [
      Text(stripInlineMarkers(b.text).isEmpty ? 'Tâche' : stripInlineMarkers(b.text),
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
      const SectionLabel('Statut'),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final s in TaskStatus.all)
          FilterPill(label: TaskStatus.label(s), selected: t.status == s, onTap: () => upd(status: s)),
      ]),
      const SectionLabel('Échéance'),
      Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        OutlinedButton.icon(
          icon: const Icon(Icons.event_rounded, size: 18),
          label: Text(t.due == null ? 'Choisir une date' : dayLabel(t.due!)),
          onPressed: () async {
            final now = DateTime.now();
            final d = await showDatePicker(
              context: context,
              initialDate: t.due ?? now,
              firstDate: DateTime(now.year - 5),
              lastDate: DateTime(now.year + 10),
              locale: const Locale('fr'),
            );
            if (d != null) upd(due: DateTime(d.year, d.month, d.day));
          },
        ),
        if (t.due != null) TextButton(onPressed: () => upd(clearDue: true), child: const Text('Sans échéance')),
      ]),
      const SectionLabel('Priorité'),
      Wrap(spacing: 8, runSpacing: 8, children: [
        for (final p in [0, 1, 2, 3])
          FilterPill(label: PriorityBadge.label(p), selected: t.priority == p, onTap: () => upd(priority: p)),
      ]),
      const SizedBox(height: 18),
      Row(children: [
        TextButton.icon(
          onPressed: () {
            repo.setTracked(widget.noteId, widget.blockId, false);
            Navigator.pop(context);
          },
          icon: Icon(Icons.remove_done_rounded, size: 18, color: nn.mid),
          label: Text('Ne plus suivre', style: TextStyle(color: nn.mid)),
        ),
        const Spacer(),
        FilledButton(onPressed: () => Navigator.pop(context), child: const Text('OK')),
      ]),
    ]);
  }
}

/// Vue « Tâches » : toutes les cases suivies, avec filtres.
class TasksPane extends StatefulWidget {
  const TasksPane({super.key, required this.onOpen});
  final ValueChanged<String> onOpen;
  @override
  State<TasksPane> createState() => _TasksPaneState();
}

class _TasksPaneState extends State<TasksPane> {
  TaskFilter _filter = TaskFilter.open;

  @override
  Widget build(BuildContext context) {
    final app = AppScope.of(context);
    final repo = app.repo!;
    final nn = context.nn;
    final items = repo.tasks(filter: _filter);
    const labels = {
      TaskFilter.open: 'Ouvertes',
      TaskFilter.todo: 'À faire',
      TaskFilter.doing: 'En cours',
      TaskFilter.done: 'Terminées',
      TaskFilter.overdue: 'En retard',
      TaskFilter.all: 'Toutes',
    };
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // Tous les filtres restent visibles (retour à la ligne), sur téléphone comme sur PC.
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
        child: Wrap(spacing: 8, runSpacing: 8, children: [
          for (final f in labels.entries)
            FilterPill(
              key: ValueKey('task-filter-${f.key.name}'),
              label: f.value,
              selected: _filter == f.key,
              dot: f.key == TaskFilter.overdue ? NColors.red : null,
              onTap: () => setState(() => _filter = f.key),
            ),
        ]),
      ),
      Expanded(
        child: items.isEmpty
            ? EmptyState(
                icon: Icons.task_alt_rounded,
                title: _filter == TaskFilter.overdue ? 'Rien en retard' : 'Aucune tâche',
                subtitle: 'Dans une page, appuyez longuement sur une case à cocher puis « Suivre comme tâche ».',
              )
            : ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 110),
                itemCount: items.length,
                itemBuilder: (c, i) {
                  final t = items[i];
                  return Padding(
                    key: ValueKey('task-${t.block.id}'),
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Material(
                      color: nn.card,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                        side: BorderSide(color: t.isOverdue() ? NColors.red : nn.line),
                      ),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(16),
                        onTap: () => widget.onOpen(t.note.id),
                        onLongPress: () => showTaskSheet(context, repo, t.note.id, t.block.id),
                        onSecondaryTap: () => showTaskSheet(context, repo, t.note.id, t.block.id),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(6, 8, 10, 10),
                          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Checkbox(
                              value: t.done,
                              onChanged: (v) => repo.setChecked(t.note.id, t.block.id, v ?? false),
                            ),
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                const SizedBox(height: 10),
                                Text(t.text.isEmpty ? 'Tâche sans texte' : t.text,
                                    style: TextStyle(
                                      fontSize: 14.5,
                                      fontWeight: FontWeight.w500,
                                      color: t.done ? nn.mid : nn.fg,
                                      decoration: t.done ? TextDecoration.lineThrough : null,
                                    )),
                                const SizedBox(height: 4),
                                Text(t.note.title.isEmpty ? 'Sans titre' : t.note.title,
                                    maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: nn.mid)),
                                const SizedBox(height: 6),
                                TaskChips(info: t.info, onTap: () => showTaskSheet(context, repo, t.note.id, t.block.id)),
                              ]),
                            ),
                            IconButton(
                              tooltip: 'Modifier la tâche',
                              onPressed: () => showTaskSheet(context, repo, t.note.id, t.block.id),
                              icon: Icon(Icons.tune_rounded, size: 19, color: nn.mid),
                            ),
                          ]),
                        ),
                      ),
                    ),
                  );
                },
              ),
      ),
    ]);
  }
}
