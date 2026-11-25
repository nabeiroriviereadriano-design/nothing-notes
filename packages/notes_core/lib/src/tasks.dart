import 'models.dart';
import 'repository.dart';

/// Filtres de la vue Tâches.
enum TaskFilter { open, todo, doing, done, overdue, all }

/// Une tâche suivie : une case à cocher d'une page, avec son suivi.
/// La tâche n'est pas dupliquée : elle EST le bloc de la page.
class TaskItem {
  TaskItem(this.note, this.block, this.info);
  final Note note;
  final Block block;
  final TaskInfo info;

  String get text => stripInlineMarkers(block.text);

  bool get done => info.status == TaskStatus.done;

  bool isOverdue([DateTime? now]) {
    if (done || info.due == null) return false;
    final t = now ?? DateTime.now();
    return info.due!.isBefore(DateTime(t.year, t.month, t.day));
  }
}

extension TasksX on NotesRepository {
  /// Toutes les tâches suivies des pages (hors corbeille et modèles).
  List<TaskItem> tasks({TaskFilter filter = TaskFilter.open, DateTime? now}) {
    final out = <TaskItem>[];
    for (final n in allNotes()) {
      if (n.trashed || n.isTemplate) continue;
      for (final b in n.blocks) {
        if (b.type != BlockType.todo) continue;
        final info = b.task;
        if (info == null) continue;
        final item = TaskItem(n, b, info);
        final keep = switch (filter) {
          TaskFilter.all => true,
          TaskFilter.open => !item.done,
          TaskFilter.todo => info.status == TaskStatus.todo,
          TaskFilter.doing => info.status == TaskStatus.doing,
          TaskFilter.done => item.done,
          TaskFilter.overdue => item.isOverdue(now),
        };
        if (keep) out.add(item);
      }
    }
    // En retard d'abord, puis par échéance, priorité, page.
    out.sort((a, b) {
      final o = (b.isOverdue(now) ? 1 : 0) - (a.isOverdue(now) ? 1 : 0);
      if (o != 0) return o;
      final da = a.info.due, db = b.info.due;
      if (da != null && db != null && da != db) return da.compareTo(db);
      if (da != null && db == null) return -1;
      if (da == null && db != null) return 1;
      final p = b.info.priority.compareTo(a.info.priority);
      if (p != 0) return p;
      return a.note.title.compareTo(b.note.title);
    });
    return out;
  }

  /// Modifie un bloc d'une page.
  void updateBlock(String noteId, String blockId, void Function(Block b) change) {
    final n = note(noteId);
    if (n == null) return;
    final i = n.blocks.indexWhere((b) => b.id == blockId);
    if (i < 0) return;
    change(n.blocks[i]);
    saveNote(n);
  }

  /// Transforme une case à cocher en tâche suivie (ou arrête le suivi).
  void setTracked(String noteId, String blockId, bool tracked) => updateBlock(noteId, blockId, (b) {
        if (b.type != BlockType.todo) b.type = BlockType.todo;
        b.task = tracked ? (b.task ?? TaskInfo(status: b.checked ? TaskStatus.done : TaskStatus.todo)) : null;
      });

  /// Met à jour le suivi. La case est cochée si et seulement si la tâche est terminée.
  void updateTask(String noteId, String blockId,
          {String? status, DateTime? due, bool clearDue = false, int? priority}) =>
      updateBlock(noteId, blockId, (b) {
        final t = b.task ?? TaskInfo(status: b.checked ? TaskStatus.done : TaskStatus.todo);
        if (status != null) t.status = status;
        if (clearDue) {
          t.due = null;
        } else if (due != null) {
          t.due = due;
        }
        if (priority != null) t.priority = priority.clamp(0, 3);
        b.task = t;
        b.checked = t.status == TaskStatus.done;
      });

  /// Coche / décoche une case ; garde le statut de la tâche cohérent.
  void setChecked(String noteId, String blockId, bool checked) => updateBlock(noteId, blockId, (b) {
        b.checked = checked;
        final t = b.task;
        if (t != null) {
          t.status = checked ? TaskStatus.done : (t.status == TaskStatus.done ? TaskStatus.todo : t.status);
          b.task = t;
        }
      });
}
