import 'package:flutter/material.dart';
import 'package:notes_core/notes_core.dart';

import '../theme.dart';

/// Contrôleur de texte qui affiche la mise en forme en ligne
/// (**gras**, *italique*, ++souligné++, ~~barré~~, `code`, [lien](url)).
///
/// Quand le champ a le focus, les balises restent visibles en gris clair
/// pour pouvoir les modifier ; sinon elles sont masquées et seul le texte
/// mis en forme apparaît.
class InlineController extends TextEditingController {
  InlineController({super.text, this.formatting = true});

  /// Désactivé pour les blocs de code.
  bool formatting;
  bool _revealMarkers = false;

  set revealMarkers(bool v) {
    if (v == _revealMarkers) return;
    _revealMarkers = v;
    notifyListeners();
  }

  bool get hasMarkers => formatting && parseInline(text).any((t) => t.marker);

  /// Lien sous le curseur, s'il y en a un.
  String? linkAtCursor() {
    if (!formatting) return null;
    final off = selection.baseOffset;
    if (off < 0) return null;
    var pos = 0;
    for (final t in parseInline(text)) {
      final end = pos + t.text.length;
      if (t.link != null && off >= pos && off <= end) return t.link;
      pos = end;
    }
    return null;
  }

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    if (!formatting || text.isEmpty) {
      return super.buildTextSpan(context: context, style: style, withComposing: withComposing);
    }
    final tokens = parseInline(text);
    if (!tokens.any((t) => t.marker)) {
      return super.buildTextSpan(context: context, style: style, withComposing: withComposing);
    }
    final n = context.nn;
    final base = style ?? const TextStyle();
    final children = <TextSpan>[];
    for (final t in tokens) {
      var s = base;
      if (t.styles.contains(InlineStyle.bold)) s = s.copyWith(fontWeight: FontWeight.w700);
      if (t.styles.contains(InlineStyle.italic)) s = s.copyWith(fontStyle: FontStyle.italic);
      final decos = <TextDecoration>[
        if (t.styles.contains(InlineStyle.underline) || t.link != null) TextDecoration.underline,
        if (t.styles.contains(InlineStyle.strike)) TextDecoration.lineThrough,
      ];
      if (decos.isNotEmpty) {
        s = s.copyWith(decoration: TextDecoration.combine(decos), decorationColor: t.link != null ? NColors.red : null);
      }
      if (t.styles.contains(InlineStyle.code)) {
        s = s.copyWith(
          fontFamily: kFontMono,
          fontSize: (base.fontSize ?? 16) * 0.9,
          backgroundColor: n.line.withValues(alpha: 0.6),
        );
      }
      if (t.link != null) s = s.copyWith(color: NColors.red);
      if (t.marker) {
        s = _revealMarkers
            ? s.copyWith(color: n.mid.withValues(alpha: 0.7), fontWeight: FontWeight.w400, decoration: TextDecoration.none)
            : s.copyWith(fontSize: 0.01, color: Colors.transparent, letterSpacing: 0, decoration: TextDecoration.none);
      }
      children.add(TextSpan(text: t.text, style: s));
    }
    return TextSpan(style: base, children: children);
  }
}
