import 'dart:io';

import 'package:flutter/material.dart';
import 'package:liquid_glass_renderer/liquid_glass_renderer.dart';

import 'glass.dart';
import 'tokens.dart';

/// Whether real Liquid Glass (refraction of what is behind, through the Flutter GPU renderer) may be used here: the viewer has
/// it on, effects are not reduced, and this is not a test run (tests have no GPU). Where the renderer cannot run the package
/// itself falls back to a frosted glass without refraction.
bool liquidAvailable(BuildContext context) {
  if (Platform.environment.containsKey('FLUTTER_TEST')) return false;
  return AetherLook.of(context).liquid && glassEnabled(context);
}

/// Loads the glass shaders before the first frame that needs them (a failure is ignored: glass just falls back).
Future<void> precacheLiquid() async {
  try {
    await LiquidGlass.precache();
  } on Object {
    // no GPU renderer here
  }
}

/// A real Liquid Glass surface when available, else the frosted [GlassSurface]. The slider «Liquid Glass» (Trasparente ↔
/// Colorato) is [AetherLook.glassIntensity]: the same scale as the iOS Settings slider.
class LiquidSurface extends StatelessWidget {
  const LiquidSurface({
    super.key,
    required this.child,
    this.radius = 26,
    this.padding,
    this.tint,
    this.strong = false,
  });

  final Widget child;
  final double radius;
  final EdgeInsetsGeometry? padding;
  final Color? tint;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    if (!liquidAvailable(context)) {
      return GlassSurface(
        radius: radius,
        padding: padding,
        tint: tint,
        strong: strong,
        child: child,
      );
    }
    final look = AetherLook.of(context);
    final t = look.glassIntensity.clamp(0.0, 1.0);
    return RepaintBoundary(
      child: LiquidGlass.auto(
        settings: LiquidGlassSettings.ios27Regular(
          brightness: Brightness.dark,
          tintAmount: t,
        ),
        // A faint hint of the accent keeps the glass in the app's colours without hiding the refraction.
        shadows: const [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 18,
            offset: Offset(0, 8),
          ),
        ],
        appearance: LiquidGlassAppearance.ios27RegularDark(
          tint: (tint ?? look.accent).withValues(alpha: 0.10 + 0.14 * t),
        ),
        shape: LiquidRoundedSuperellipse(borderRadius: radius),
        child: padding == null
            ? child
            : Padding(padding: padding!, child: child),
      ),
    );
  }
}
