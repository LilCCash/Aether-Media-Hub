import 'package:flutter/material.dart';

/// Shared design tokens: one place for colours, radii, spacing, type and motion, so every screen speaks the same visual language.
class AetherTokens {
  const AetherTokens._();

  // Colour
  static const Color ink = Color(0xFF05060D);
  static const Color inkRaised = Color(0xFF0C0F1C);
  static const Color textPrimary = Color(0xFFF4F6FF);
  static const Color textSecondary = Color(0xB3E7EAFF); // 70%
  static const Color textTertiary = Color(0x80E7EAFF); // 50%
  static const Color hairline = Color(0x26FFFFFF);
  static const Color success = Color(0xFF4FD18B);
  static const Color warning = Color(0xFFFFB454);
  static const Color danger = Color(0xFFFF6B6B);

  // Radius
  static const double rSmall = 10;
  static const double rMedium = 16;
  static const double rLarge = 24;
  static const double rPill = 999;

  // Spacing (4-pt grid)
  static const double s1 = 4;
  static const double s2 = 8;
  static const double s3 = 12;
  static const double s4 = 16;
  static const double s5 = 24;
  static const double s6 = 32;
  static const double pageMargin = 20;

  // Motion
  static const Duration fast = Duration(milliseconds: 140);
  static const Duration medium = Duration(milliseconds: 260);
  static const Duration slow = Duration(milliseconds: 520);
  static const Curve ease = Curves.easeOutCubic;

  // Elevation for glass layers (blur sigma, fill opacity)
  static const double blurLow = 14;
  static const double blurHigh = 28;

  static TextTheme textTheme(Color color, {String? titleFamily}) => TextTheme(
    displaySmall: TextStyle(
      fontFamily: titleFamily,
      fontSize: 34,
      fontWeight: FontWeight.w800,
      letterSpacing: -0.8,
      height: 1.05,
      color: color,
    ),
    headlineMedium: TextStyle(
      fontFamily: titleFamily,
      fontSize: 26,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.4,
      color: color,
    ),
    titleLarge: TextStyle(
      fontFamily: titleFamily,
      fontSize: 21,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.2,
      color: color,
    ),
    titleMedium: TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w600,
      color: color,
    ),
    bodyLarge: TextStyle(fontSize: 16, height: 1.35, color: color),
    bodyMedium: TextStyle(fontSize: 14, height: 1.35, color: color),
    bodySmall: TextStyle(
      fontSize: 12,
      height: 1.3,
      color: color.withValues(alpha: 0.7),
    ),
    labelLarge: TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w600,
      color: color,
    ),
    labelSmall: TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.4,
      color: color.withValues(alpha: 0.7),
    ),
  );
}

/// The live look chosen in Settings, read by the glass widgets.
class AetherLook extends InheritedWidget {
  const AetherLook({
    super.key,
    required this.accent,
    required this.glassIntensity,
    required this.reduceEffects,
    required this.amoled,
    required this.cinematic,
    this.secondary,
    required super.child,
  });

  final Color accent;
  final double glassIntensity;
  final bool reduceEffects;
  final bool amoled;
  final bool cinematic;

  /// Second wash of the palette, shown as a faint glow in the lower corner.
  final Color? secondary;

  static AetherLook of(BuildContext context) {
    final look = context.dependOnInheritedWidgetOfExactType<AetherLook>();
    assert(look != null, 'AetherLook missing above this widget');
    return look ?? const _Fallback().look;
  }

  @override
  bool updateShouldNotify(AetherLook old) =>
      accent != old.accent ||
      glassIntensity != old.glassIntensity ||
      reduceEffects != old.reduceEffects ||
      amoled != old.amoled ||
      cinematic != old.cinematic ||
      secondary != old.secondary;
}

class _Fallback {
  const _Fallback();
  AetherLook get look => const AetherLook(
    accent: Color(0xFF7C8CFF),
    glassIntensity: 1,
    reduceEffects: false,
    amoled: false,
    cinematic: true,
    child: SizedBox(),
  );
}

Color colorFromHex(String hex, {Color fallback = const Color(0xFF7C8CFF)}) {
  final h = hex.replaceFirst('#', '');
  final value = int.tryParse(h, radix: 16);
  if (h.length != 6 || value == null) return fallback;
  return Color(0xFF000000 | value);
}
