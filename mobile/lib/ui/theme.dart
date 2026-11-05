// Earmark's look, matching the Mac: Newsreader for headings, Geist for everything else,
// quiet surfaces, one accent colour for "live".
import 'package:flutter/material.dart';

@immutable
class Tokens extends ThemeExtension<Tokens> {
  final Color bg, surface, sunk, line, line2, ink, ink2, ink3, live, liveSoft, liveInk, due, dueSoft, ok, okSoft, bad, badSoft;
  const Tokens({
    required this.bg, required this.surface, required this.sunk, required this.line, required this.line2,
    required this.ink, required this.ink2, required this.ink3, required this.live, required this.liveSoft,
    required this.liveInk, required this.due, required this.dueSoft, required this.ok, required this.okSoft,
    required this.bad, required this.badSoft,
  });

  static const light = Tokens(
    bg: Color(0xFFF3F4F6), surface: Color(0xFFFFFFFF), sunk: Color(0xFFF7F8F9), line: Color(0xFFE1E4E8),
    line2: Color(0xFFCDD2D8), ink: Color(0xFF14181D), ink2: Color(0xFF555E68), ink3: Color(0xFF8A929B),
    live: Color(0xFF2F6FEB), liveSoft: Color(0xFFE6EEFD), liveInk: Color(0xFF1D4FB8), due: Color(0xFFB76E12),
    dueSoft: Color(0xFFFBF0E1), ok: Color(0xFF23845A), okSoft: Color(0xFFE3F3EA), bad: Color(0xFFB4362F),
    badSoft: Color(0xFFFBE9E7),
  );
  static const dark = Tokens(
    bg: Color(0xFF12161B), surface: Color(0xFF181D23), sunk: Color(0xFF151A1F), line: Color(0xFF262D35),
    line2: Color(0xFF36404A), ink: Color(0xFFE7EBEF), ink2: Color(0xFFA3ADB8), ink3: Color(0xFF6C7783),
    live: Color(0xFF5B91F5), liveSoft: Color(0xFF18263D), liveInk: Color(0xFF9DBDF9), due: Color(0xFFE3A04A),
    dueSoft: Color(0xFF2E2414), ok: Color(0xFF4CBF8A), okSoft: Color(0xFF14291F), bad: Color(0xFFEE7B73),
    badSoft: Color(0xFF331A18),
  );

  @override
  Tokens copyWith() => this;
  @override
  Tokens lerp(ThemeExtension<Tokens>? other, double t) => t < .5 ? this : (other as Tokens? ?? this);
}

extension TokensX on BuildContext {
  Tokens get t => Theme.of(this).extension<Tokens>()!;
}

ThemeData earmarkTheme(Brightness b) {
  final k = b == Brightness.dark ? Tokens.dark : Tokens.light;
  final base = ThemeData(brightness: b, useMaterial3: true, fontFamily: 'Geist');
  final text = base.textTheme.apply(bodyColor: k.ink, displayColor: k.ink, fontFamily: 'Geist');
  return base.copyWith(
    scaffoldBackgroundColor: k.bg,
    colorScheme: base.colorScheme.copyWith(
      primary: k.live, onPrimary: Colors.white, surface: k.surface, onSurface: k.ink,
      error: k.bad, outline: k.line2, outlineVariant: k.line,
    ),
    extensions: [k],
    textTheme: text.copyWith(
      headlineLarge: TextStyle(fontFamily: 'Newsreader', fontSize: 32, height: 1.15, color: k.ink, fontWeight: FontWeight.w400),
      headlineMedium: TextStyle(fontFamily: 'Newsreader', fontSize: 25, height: 1.2, color: k.ink, fontWeight: FontWeight.w400),
      titleLarge: TextStyle(fontFamily: 'Newsreader', fontSize: 20, height: 1.25, color: k.ink, fontWeight: FontWeight.w500),
      bodyLarge: TextStyle(fontFamily: 'Geist', fontSize: 16, height: 1.5, color: k.ink),
      bodyMedium: TextStyle(fontFamily: 'Geist', fontSize: 14.5, height: 1.45, color: k.ink),
      bodySmall: TextStyle(fontFamily: 'Geist', fontSize: 12.5, height: 1.4, color: k.ink2),
      labelLarge: const TextStyle(fontFamily: 'Geist', fontSize: 14.5, fontWeight: FontWeight.w500),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: k.bg, foregroundColor: k.ink, elevation: 0, scrolledUnderElevation: 0,
      titleTextStyle: TextStyle(fontFamily: 'Geist', fontSize: 15, fontWeight: FontWeight.w600, color: k.ink),
    ),
    dividerTheme: DividerThemeData(color: k.line, thickness: 1, space: 1),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: k.surface,
      indicatorColor: k.liveSoft,
      height: 64,
      labelTextStyle: WidgetStatePropertyAll(TextStyle(fontSize: 11.5, color: k.ink2, fontWeight: FontWeight.w500)),
      iconTheme: WidgetStateProperty.resolveWith((s) => IconThemeData(color: s.contains(WidgetState.selected) ? k.liveInk : k.ink2)),
    ),
    filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(
      backgroundColor: k.live, foregroundColor: Colors.white, minimumSize: const Size(0, 46),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      textStyle: const TextStyle(fontFamily: 'Geist', fontSize: 15, fontWeight: FontWeight.w600),
    )),
    outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(
      foregroundColor: k.ink, side: BorderSide(color: k.line2), minimumSize: const Size(0, 44),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      textStyle: const TextStyle(fontFamily: 'Geist', fontSize: 14.5, fontWeight: FontWeight.w500),
    )),
    inputDecorationTheme: InputDecorationTheme(
      filled: true, fillColor: k.surface, isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: k.line2)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: k.line2)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: k.live, width: 1.5)),
      labelStyle: TextStyle(color: k.ink2), hintStyle: TextStyle(color: k.ink3),
    ),
    checkboxTheme: CheckboxThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
      side: BorderSide(color: k.line2, width: 1.5),
      fillColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? k.ok : Colors.transparent),
    ),
    snackBarTheme: SnackBarThemeData(backgroundColor: k.ink, contentTextStyle: TextStyle(color: k.bg, fontFamily: 'Geist'),
        behavior: SnackBarBehavior.floating, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
  );
}

/// A rounded card on the surface colour, like the Mac's panels.
class Panel extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final Color? color;
  const Panel({super.key, required this.child, this.padding = const EdgeInsets.all(16), this.color});
  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: padding,
        decoration: BoxDecoration(
          color: color ?? context.t.surface,
          border: Border.all(color: context.t.line),
          borderRadius: BorderRadius.circular(12),
        ),
        child: child,
      );
}

String clock(num seconds) {
  final s = seconds.round();
  final h = s ~/ 3600, m = (s % 3600) ~/ 60, sec = s % 60;
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}' : '$m:${sec.toString().padLeft(2, '0')}';
}

String dur(num seconds) {
  final s = seconds.round();
  if (s < 60) return '$s s';
  final h = s ~/ 3600, m = (s % 3600) ~/ 60;
  return h > 0 ? '$h h ${m.toString().padLeft(2, '0')} min' : '$m min';
}
