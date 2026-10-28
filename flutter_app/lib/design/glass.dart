import 'dart:ui';

import 'package:flutter/material.dart';

import 'tokens.dart';

/// Whether heavy effects are allowed: switched off by the setting, by the system's "reduce motion" / "remove animations",
/// and (via [AetherLook.glassIntensity] = 0) by the viewer.
bool glassEnabled(BuildContext context) {
  final look = AetherLook.of(context);
  final media = MediaQuery.maybeOf(context);
  return !look.reduceEffects && look.glassIntensity > 0.02 && !(media?.disableAnimations ?? false);
}

/// A translucent "liquid glass" surface: a clipped backdrop blur, a soft light gradient, a thin edge highlight and a faint inner
/// shadow. The blur is applied only to this clipped rectangle (never to a full screen) and falls back to a flat, opaque-ish
/// surface when effects are reduced, so it stays cheap on slow devices.
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.radius = AetherTokens.rMedium,
    this.padding,
    this.blur = AetherTokens.blurLow,
    this.tint,
    this.strong = false,
    this.borderRadius,
  });

  final Widget child;
  final double radius;
  final BorderRadius? borderRadius;
  final EdgeInsetsGeometry? padding;
  final double blur;
  final Color? tint;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final look = AetherLook.of(context);
    final shape = borderRadius ?? BorderRadius.circular(radius);
    final enabled = glassEnabled(context);
    final k = look.glassIntensity.clamp(0.0, 1.0);
    final base = tint ?? Colors.white;
    final top = base.withValues(alpha: (strong ? 0.20 : 0.13) * (enabled ? k : 1));
    final bottom = base.withValues(alpha: (strong ? 0.08 : 0.04) * (enabled ? k : 1));
    final flat = look.amoled ? const Color(0xFF111114) : AetherTokens.inkRaised;

    Widget content = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: shape,
        gradient: enabled
            ? LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [top, bottom])
            : LinearGradient(colors: [flat.withValues(alpha: 0.96), flat.withValues(alpha: 0.96)]),
        border: Border.all(color: Colors.white.withValues(alpha: enabled ? 0.22 * k + 0.04 : 0.12), width: 0.8),
        boxShadow: enabled ? [BoxShadow(color: Colors.black.withValues(alpha: 0.28), blurRadius: 24, offset: const Offset(0, 10))] : const [],
      ),
      child: padding == null ? child : Padding(padding: padding!, child: child),
    );

    if (enabled) {
      content = ClipRRect(
        borderRadius: shape,
        child: BackdropFilter(filter: ImageFilter.blur(sigmaX: blur * (0.4 + 0.6 * k), sigmaY: blur * (0.4 + 0.6 * k)), child: content),
      );
    } else {
      content = ClipRRect(borderRadius: shape, child: content);
    }
    return RepaintBoundary(child: content);
  }
}

/// A round or pill-shaped glass button with a real tap target (min 44 px) and a semantic label.
class GlassButton extends StatelessWidget {
  const GlassButton({super.key, this.icon, this.label, required this.onPressed, this.tooltip, this.prominent = false, this.size = 44, this.selected = false});

  final IconData? icon;
  final String? label;
  final VoidCallback? onPressed;
  final String? tooltip;
  final bool prominent;
  final double size;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final look = AetherLook.of(context);
    final enabled = onPressed != null;
    final fg = prominent ? Colors.black : AetherTokens.textPrimary;
    final child = Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: [
      if (icon != null) Icon(icon, size: 20, color: enabled ? fg : fg.withValues(alpha: 0.4)),
      if (icon != null && label != null) const SizedBox(width: 8),
      if (label != null) Text(label!, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 14, color: enabled ? fg : fg.withValues(alpha: 0.4))),
    ]);
    final isRound = label == null;
    final body = prominent
        ? DecoratedBox(
            decoration: BoxDecoration(color: look.accent, borderRadius: BorderRadius.circular(isRound ? size : AetherTokens.rPill)),
            child: SizedBox(height: size, width: isRound ? size : null, child: Padding(padding: EdgeInsets.symmetric(horizontal: isRound ? 0 : 20), child: Center(child: child))),
          )
        : GlassSurface(
            radius: AetherTokens.rPill,
            strong: selected,
            tint: selected ? look.accent : null,
            child: SizedBox(height: size, width: isRound ? size : null, child: Padding(padding: EdgeInsets.symmetric(horizontal: isRound ? 0 : 18), child: Center(child: child))),
          );
    return Semantics(
      button: true,
      enabled: enabled,
      label: tooltip ?? label,
      excludeSemantics: true,
      child: Tooltip(
        message: tooltip ?? label ?? '',
        child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: onPressed, child: ConstrainedBox(constraints: BoxConstraints(minWidth: 44, minHeight: size < 44 ? 44 : size), child: Center(child: body))),
      ),
    );
  }
}

/// The animated page background: deep ink, a soft accent glow, and (when [tint] is given) the colour of the film on screen.
class AetherBackdrop extends StatelessWidget {
  const AetherBackdrop({super.key, this.tint, this.child});
  final Color? tint;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final look = AetherLook.of(context);
    final base = look.amoled ? Colors.black : AetherTokens.ink;
    final glow = (look.cinematic ? tint : null) ?? look.accent;
    final reduced = look.reduceEffects;
    final strength = look.amoled ? 0.10 : (look.cinematic && tint != null ? 0.38 : 0.22);
    return AnimatedContainer(
      duration: reduced ? Duration.zero : AetherTokens.slow,
      decoration: BoxDecoration(
        color: base,
        gradient: reduced
            ? null
            : RadialGradient(center: const Alignment(0.7, -1.0), radius: 1.25, colors: [glow.withValues(alpha: strength), Colors.transparent]),
      ),
      child: child,
    );
  }
}
