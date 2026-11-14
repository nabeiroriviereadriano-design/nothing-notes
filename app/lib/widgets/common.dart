import 'package:flutter/material.dart';
import 'package:notes_core/notes_core.dart';

import '../theme.dart';

const _months = ['janv.', 'févr.', 'mars', 'avr.', 'mai', 'juin', 'juil.', 'août', 'sept.', 'oct.', 'nov.', 'déc.'];

String two(int v) => v.toString().padLeft(2, '0');

/// « Aujourd'hui · 14:10 », « Hier · 18:42 », « 11 nov. · 10:21 ».
String formatDate(DateTime utc, {bool withTime = true}) {
  final d = utc.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(d.year, d.month, d.day);
  final time = '${two(d.hour)}:${two(d.minute)}';
  String label;
  if (day == today) {
    label = 'Aujourd\'hui';
  } else if (day == today.subtract(const Duration(days: 1))) {
    label = 'Hier';
  } else if (d.year == now.year) {
    label = '${d.day} ${_months[d.month - 1]}';
  } else {
    label = '${d.day} ${_months[d.month - 1]} ${d.year}';
  }
  return withTime ? '$label · $time' : label;
}

/// Date courte pour la colonne de droite d'une carte (« 14:10 », « Hier », « 11 nov. »).
String formatShortDate(DateTime utc) {
  final d = utc.toLocal();
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(d.year, d.month, d.day);
  if (day == today) return '${two(d.hour)}:${two(d.minute)}';
  if (day == today.subtract(const Duration(days: 1))) return 'Hier';
  if (d.year == now.year) return '${d.day} ${_months[d.month - 1]}';
  return '${d.day}/${two(d.month)}/${d.year % 100}';
}

String formatBytes(int b) {
  if (b < 1024) return '$b o';
  if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)} Ko';
  return '${(b / 1024 / 1024).toStringAsFixed(1)} Mo';
}

/// Icône représentative d'une note selon son contenu.
IconData noteIcon(Note n) {
  final t = foldText(n.title);
  if (RegExp(r'\b(jeu|game)\b').hasMatch(t)) return Icons.sports_esports_outlined;
  if (RegExp(r'\b(idee|idees)\b').hasMatch(t)) return Icons.lightbulb_outline;
  if (n.hasChecklist) return Icons.checklist_rounded;
  if (n.hasCode) return Icons.code_rounded;
  if (n.hasImage) return Icons.image_outlined;
  return Icons.description_outlined;
}

/// Indicateur d'état de synchronisation.
class SyncBadge extends StatelessWidget {
  const SyncBadge({super.key, required this.status, this.compact = false, this.onTap});
  final SyncStatus status;
  final bool compact;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final n = context.nn;
    final (IconData icon, Color color) = switch (status.state) {
      SyncState.synced => (Icons.cloud_done_outlined, n.mid),
      SyncState.syncing => (Icons.sync_rounded, n.fg),
      SyncState.offline => (Icons.cloud_off_outlined, n.mid),
      SyncState.pending => (Icons.cloud_upload_outlined, n.fg),
      SyncState.error => (Icons.error_outline_rounded, NColors.red),
    };
    final conflicts = status.conflicts;
    final label = conflicts > 0 ? '$conflicts conflit${conflicts > 1 ? 's' : ''} à résoudre' : status.label;
    final iconW = status.state == SyncState.syncing
        ? _Spin(child: Icon(icon, size: 18, color: color))
        : Icon(conflicts > 0 ? Icons.call_split_rounded : icon, size: 18, color: conflicts > 0 ? NColors.red : color);
    final tooltip = [label, if (status.message != null && status.state != SyncState.synced) status.message!].join('\n');
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: compact ? 8 : 10, vertical: 6),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            iconW,
            if (!compact) ...[
              const SizedBox(width: 8),
              Flexible(
                child: Text(label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12.5, color: conflicts > 0 ? NColors.red : n.mid)),
              ),
            ],
          ]),
        ),
      ),
    );
  }
}

class _Spin extends StatefulWidget {
  const _Spin({required this.child});
  final Widget child;
  @override
  State<_Spin> createState() => _SpinState();
}

class _SpinState extends State<_Spin> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat();
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RotationTransition(turns: _c, child: widget.child);
}

/// Pastille d'étiquette (point de couleur + nom + croix facultative).
class TagPill extends StatelessWidget {
  const TagPill({super.key, required this.tag, this.onRemove, this.onTap, this.selected = false});
  final Tag tag;
  final VoidCallback? onRemove;
  final VoidCallback? onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final n = context.nn;
    final color = parseHex(tag.color) ?? n.mid;
    return Material(
      color: selected ? n.invertedBg : n.card,
      shape: StadiumBorder(side: BorderSide(color: selected ? n.invertedBg : n.line)),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.fromLTRB(12, 6, onRemove == null ? 14 : 6, 6),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            RedDot(size: 8, color: color),
            const SizedBox(width: 7),
            Text(tag.name,
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: selected ? n.invertedFg : n.fg)),
            if (onRemove != null) ...[
              const SizedBox(width: 2),
              InkWell(
                customBorder: const CircleBorder(),
                onTap: onRemove,
                child: Padding(
                  padding: const EdgeInsets.all(3),
                  child: Icon(Icons.close_rounded, size: 14, color: n.mid),
                ),
              ),
            ],
          ]),
        ),
      ),
    );
  }
}

/// Puce de filtre « Toutes / Travail / BTS… ».
class FilterPill extends StatelessWidget {
  const FilterPill({super.key, required this.label, required this.selected, required this.onTap, this.dot});
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Color? dot;

  @override
  Widget build(BuildContext context) {
    final n = context.nn;
    return Material(
      color: selected ? n.invertedBg : n.card,
      shape: StadiumBorder(side: BorderSide(color: selected ? n.invertedBg : n.line)),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (dot != null) ...[RedDot(size: 7, color: dot), const SizedBox(width: 7)],
            Text(label,
                style: TextStyle(
                    fontSize: 13.5, fontWeight: FontWeight.w500, color: selected ? n.invertedFg : n.fg)),
          ]),
        ),
      ),
    );
  }
}

class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
        child: Text(text.toUpperCase(),
            style: TextStyle(
                fontFamily: kFontMono, fontSize: 11, letterSpacing: 1.6, color: context.nn.mid)),
      );
}

void toast(BuildContext context, String message) {
  final m = ScaffoldMessenger.maybeOf(context);
  m?.hideCurrentSnackBar();
  m?.showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 3)));
}

Future<bool> confirm(BuildContext context,
    {required String title, required String message, String ok = 'Confirmer', bool danger = false}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Annuler')),
        FilledButton(
          style: danger ? FilledButton.styleFrom(backgroundColor: NColors.red, foregroundColor: Colors.white) : null,
          onPressed: () => Navigator.pop(c, true),
          child: Text(ok),
        ),
      ],
    ),
  );
  return r ?? false;
}

Future<String?> promptText(BuildContext context,
    {required String title, String initial = '', String hint = '', String ok = 'Valider'}) {
  final ctl = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
      content: TextField(
        controller: ctl,
        autofocus: true,
        decoration: InputDecoration(hintText: hint),
        onSubmitted: (v) => Navigator.pop(c, v.trim()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c), child: const Text('Annuler')),
        FilledButton(onPressed: () => Navigator.pop(c, ctl.text.trim()), child: Text(ok)),
      ],
    ),
  );
}

/// Choix d'une couleur parmi la palette.
class ColorChoice extends StatelessWidget {
  const ColorChoice({super.key, required this.value, required this.onChanged});
  final String? value;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) => Wrap(spacing: 10, runSpacing: 10, children: [
        for (final hex in kLabelColors)
          InkWell(
            customBorder: const CircleBorder(),
            onTap: () => onChanged(hex),
            child: Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                color: parseHex(hex),
                shape: BoxShape.circle,
                border: Border.all(
                  color: value == hex ? context.nn.fg : context.nn.line,
                  width: value == hex ? 2.5 : 1,
                ),
              ),
            ),
          ),
      ]);
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.title, this.subtitle, this.icon = Icons.notes_rounded});
  final String title;
  final String? subtitle;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 40, color: context.nn.mid),
            const SizedBox(height: 14),
            Text(title,
                textAlign: TextAlign.center, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            if (subtitle != null) ...[
              const SizedBox(height: 6),
              Text(subtitle!, textAlign: TextAlign.center, style: TextStyle(color: context.nn.mid, fontSize: 13.5)),
            ],
          ]),
        ),
      );
}
