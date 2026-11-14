import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Palette Nothing Notes (cahier des charges §3).
class NColors {
  static const black = Color(0xFF080808);
  static const black2 = Color(0xFF171717);
  static const grey = Color(0xFF292929);
  static const mid = Color(0xFF858585);
  static const white = Color(0xFFF5F5F5);
  static const red = Color(0xFFE60012);

  // teintes dérivées pour le mode clair
  static const paper = Color(0xFFFFFFFF);
  static const lightLine = Color(0xFFE2E2E2);
  static const lightPanel = Color(0xFFEDEDED);
}

/// Couleurs sémantiques accessibles via `context.nn`.
class NTheme extends ThemeExtension<NTheme> {
  const NTheme({
    required this.bg,
    required this.panel,
    required this.card,
    required this.cardHover,
    required this.line,
    required this.fg,
    required this.mid,
    required this.dots,
    required this.accent,
    required this.invertedBg,
    required this.invertedFg,
  });

  final Color bg, panel, card, cardHover, line, fg, mid, dots, accent, invertedBg, invertedFg;

  static const dark = NTheme(
    bg: NColors.black,
    panel: Color(0xFF0E0E0E),
    card: NColors.black2,
    cardHover: Color(0xFF1F1F1F),
    line: NColors.grey,
    fg: NColors.white,
    mid: NColors.mid,
    dots: Color(0xFF2E2E2E),
    accent: NColors.red,
    invertedBg: NColors.white,
    invertedFg: NColors.black,
  );

  static const light = NTheme(
    bg: NColors.white,
    panel: NColors.lightPanel,
    card: NColors.paper,
    cardHover: Color(0xFFFAFAFA),
    line: NColors.lightLine,
    fg: NColors.black,
    mid: Color(0xFF6E6E6E),
    dots: Color(0xFFD0D0D0),
    accent: NColors.red,
    invertedBg: NColors.black,
    invertedFg: NColors.white,
  );

  @override
  NTheme copyWith() => this;

  @override
  NTheme lerp(ThemeExtension<NTheme>? other, double t) => t < 0.5 ? this : (other as NTheme? ?? this);
}

extension NThemeX on BuildContext {
  NTheme get nn => Theme.of(this).extension<NTheme>()!;
  bool get isDark => Theme.of(this).brightness == Brightness.dark;
}

const kFontBody = 'Inter';
const kFontDot = 'Doto';
const kFontMono = 'JetBrainsMono';

ThemeData buildTheme(Brightness b) {
  final n = b == Brightness.dark ? NTheme.dark : NTheme.light;
  final base = ThemeData(
    brightness: b,
    useMaterial3: true,
    fontFamily: kFontBody,
    colorScheme: ColorScheme(
      brightness: b,
      primary: n.fg,
      onPrimary: n.bg,
      secondary: NColors.red,
      onSecondary: Colors.white,
      error: NColors.red,
      onError: Colors.white,
      surface: n.card,
      onSurface: n.fg,
    ),
  );
  final radius = BorderRadius.circular(16);
  return base.copyWith(
    scaffoldBackgroundColor: n.bg,
    canvasColor: n.bg,
    extensions: [n],
    dividerColor: n.line,
    splashFactory: InkSparkle.splashFactory,
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: NColors.red,
      selectionColor: NColors.red.withValues(alpha: 0.28),
      selectionHandleColor: NColors.red,
    ),
    iconTheme: IconThemeData(color: n.fg, size: 22),
    textTheme: base.textTheme.apply(bodyColor: n.fg, displayColor: n.fg, fontFamily: kFontBody),
    appBarTheme: AppBarTheme(
      backgroundColor: n.bg,
      foregroundColor: n.fg,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: n.card,
      hintStyle: TextStyle(color: n.mid),
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(999), borderSide: BorderSide(color: n.line)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(999), borderSide: BorderSide(color: n.line)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(999), borderSide: BorderSide(color: n.fg)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: n.invertedBg,
        foregroundColor: n.invertedFg,
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        textStyle: const TextStyle(fontFamily: kFontBody, fontWeight: FontWeight.w600, fontSize: 15),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: n.fg,
        side: BorderSide(color: n.line),
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        textStyle: const TextStyle(fontFamily: kFontBody, fontWeight: FontWeight.w500),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: n.fg, shape: const StadiumBorder()),
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: n.invertedBg,
      foregroundColor: n.invertedFg,
      shape: const CircleBorder(),
      elevation: 2,
    ),
    chipTheme: ChipThemeData(
      backgroundColor: n.card,
      selectedColor: n.invertedBg,
      side: BorderSide(color: n.line),
      shape: const StadiumBorder(),
      labelStyle: TextStyle(color: n.fg, fontFamily: kFontBody, fontSize: 13),
      secondaryLabelStyle: TextStyle(color: n.invertedFg, fontFamily: kFontBody, fontSize: 13),
      showCheckmark: false,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: n.card,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24), side: BorderSide(color: n.line)),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: n.card,
      shape: RoundedRectangleBorder(borderRadius: radius, side: BorderSide(color: n.line)),
      textStyle: TextStyle(color: n.fg, fontFamily: kFontBody, fontSize: 14),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: n.card,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      showDragHandle: true,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: n.invertedBg,
      contentTextStyle: TextStyle(color: n.invertedFg, fontFamily: kFontBody),
      behavior: SnackBarBehavior.floating,
      shape: const StadiumBorder(),
    ),
    checkboxTheme: CheckboxThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
      side: BorderSide(color: n.fg, width: 1.6),
      fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? NColors.red : Colors.transparent),
      checkColor: const WidgetStatePropertyAll(Colors.white),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? Colors.white : n.mid),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? NColors.red : n.line),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: n.invertedBg, borderRadius: BorderRadius.circular(8)),
      textStyle: TextStyle(color: n.invertedFg, fontSize: 12, fontFamily: kFontBody),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStatePropertyAll(n.mid.withValues(alpha: 0.4)),
      radius: const Radius.circular(8),
      thickness: const WidgetStatePropertyAll(4),
    ),
  );
}

/// Titre en matrice de points (police libre Doto, inspirée des afficheurs à points).
class DotTitle extends StatelessWidget {
  const DotTitle(this.text, {super.key, this.size = 30, this.color});
  final String text;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => Text(
        text.toUpperCase(),
        style: TextStyle(
          fontFamily: kFontDot,
          fontWeight: FontWeight.w900,
          fontSize: size,
          height: 1.0,
          letterSpacing: size * 0.06,
          color: color ?? context.nn.fg,
        ),
      );
}

/// Motif de points discret en arrière-plan.
class DotPattern extends StatelessWidget {
  const DotPattern({super.key, this.spacing = 22, this.radius = 1.1, this.fade = true});
  final double spacing;
  final double radius;
  final bool fade;

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: CustomPaint(
          painter: _DotsPainter(context.nn.dots, spacing, radius, fade),
          size: Size.infinite,
        ),
      );
}

class _DotsPainter extends CustomPainter {
  _DotsPainter(this.color, this.spacing, this.radius, this.fade);
  final Color color;
  final double spacing;
  final double radius;
  final bool fade;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Paint()..color = color;
    for (var y = spacing / 2; y < size.height; y += spacing) {
      for (var x = spacing / 2; x < size.width; x += spacing) {
        if (fade) {
          // dégradé : les points s'estompent vers le centre
          final dx = (x / size.width - 0.5).abs() * 2;
          final dy = (y / size.height - 0.5).abs() * 2;
          final k = (dx > dy ? dx : dy);
          if (k < 0.55) continue;
          p.color = color.withValues(alpha: ((k - 0.55) / 0.45).clamp(0.0, 1.0));
        }
        canvas.drawCircle(Offset(x, y), radius, p);
      }
    }
  }

  @override
  bool shouldRepaint(_DotsPainter old) => old.color != color || old.spacing != spacing;
}

/// Logo de l'application dessiné en vectoriel (pas d'image à charger).
class NothingLogo extends StatelessWidget {
  const NothingLogo({super.key, this.size = 40, this.withTile = true});
  final double size;
  final bool withTile;

  @override
  Widget build(BuildContext context) {
    final fg = withTile ? NColors.white : context.nn.fg;
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _LogoPainter(fg, withTile)),
    );
  }
}

class _LogoPainter extends CustomPainter {
  _LogoPainter(this.fg, this.tile);
  final Color fg;
  final bool tile;

  @override
  void paint(Canvas canvas, Size s) {
    final w = s.width;
    if (tile) {
      canvas.drawRRect(RRect.fromRectAndRadius(Offset.zero & s, Radius.circular(w * 0.225)),
          Paint()..color = NColors.black);
    }
    final dot = Paint()..color = fg;
    final r = w * 0.0185;
    const step = 0.062;
    void line(double ax, double ay, double bx, double by, {bool skipFirst = false}) {
      final len = ((bx - ax) * (bx - ax) + (by - ay) * (by - ay));
      final n = (math.sqrt(len) / step).round().clamp(1, 100);
      for (var i = skipFirst ? 1 : 0; i <= n; i++) {
        final t = i / n;
        canvas.drawCircle(Offset((ax + (bx - ax) * t) * w, (ay + (by - ay) * t) * w), r, dot);
      }
    }

    line(0.235, 0.285, 0.545, 0.285);
    line(0.235, 0.285, 0.235, 0.765, skipFirst: true);
    line(0.235, 0.765, 0.715, 0.765, skipFirst: true);
    line(0.715, 0.52, 0.715, 0.765);
    line(0.42, 0.585, 0.70, 0.305);
    canvas.drawCircle(Offset(0.775 * w, 0.225 * w), w * 0.048, Paint()..color = NColors.red);
  }

  @override
  bool shouldRepaint(_LogoPainter old) => old.fg != fg || old.tile != tile;
}

/// Petit point rouge (indicateur Nothing).
class RedDot extends StatelessWidget {
  const RedDot({super.key, this.size = 8, this.color});
  final double size;
  final Color? color;
  @override
  Widget build(BuildContext context) {
    final c = color ?? NColors.red;
    // Les points très clairs reçoivent un fin contour pour rester visibles en thème clair.
    final light = c.computeLuminance() > 0.75;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: c,
        shape: BoxShape.circle,
        border: light ? Border.all(color: const Color(0xFFADADAD), width: 1) : null,
      ),
    );
  }
}

/// Couleurs proposées pour les étiquettes et dossiers.
const kLabelColors = <String>[
  '#E60012', // rouge
  '#F5F5F5', // blanc
  '#858585', // gris
  '#4A4A4A', // anthracite
  '#FF6B00', // orange
  '#FFC400', // jaune
  '#00B86B', // vert
  '#2F80ED', // bleu
  '#9B51E0', // violet
];

Color? parseHex(String? hex) {
  if (hex == null || hex.length < 7) return null;
  final v = int.tryParse(hex.substring(1, 7), radix: 16);
  return v == null ? null : Color(0xFF000000 | v);
}
