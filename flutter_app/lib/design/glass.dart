import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

import 'liquid.dart';
import 'tokens.dart';

/// Whether heavy effects are allowed: switched off by the setting, by the system's "reduce motion" / "remove animations",
/// and (via [AetherLook.glassIntensity] = 0) by the viewer.
bool glassEnabled(BuildContext context) {
  final look = AetherLook.of(context);
  final media = MediaQuery.maybeOf(context);
  return !look.reduceEffects && !(media?.disableAnimations ?? false);
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
    this.intensity,
    this.strong = false,
    this.borderRadius,
    this.liquid = false,
  });

  final Widget child;
  final double radius;
  final BorderRadius? borderRadius;
  final EdgeInsetsGeometry? padding;
  final double blur;
  final Color? tint;

  /// Overrides the app-wide Clear ↔ Tinted choice for this surface (the tab bar has its own).
  final double? intensity;
  final bool strong;

  /// Use real Liquid Glass (refraction) when the viewer has it on; the frosted glass below is the fallback.
  final bool liquid;

  @override
  Widget build(BuildContext context) {
    final look = AetherLook.of(context);
    if (liquid && borderRadius == null && liquidAvailable(context)) {
      return LiquidSurface(
        radius: radius,
        padding: padding,
        tint: tint,
        strong: strong,
        intensity: intensity,
        child: child,
      );
    }
    // «Angoli» changes every glass surface: 14 is the standard corner, the others scale from it.
    final r = (radius * look.corner / 14).clamp(3.0, 60.0);
    final shape = borderRadius ?? BorderRadius.circular(r);
    final enabled = glassEnabled(context);
    final k = (intensity ?? look.glassIntensity).clamp(0.0, 1.0);
    final base = tint ?? Colors.white;
    // The slider is Clear ↔ Tinted: more of it means a denser wash and more frost, never a switch between glass and no glass.
    // A chosen item (a tint with `strong`) must stand out at once: a dense accent fill and a bright edge.
    final chosen = tint != null && strong;
    final top = base.withValues(
      alpha: chosen ? 0.62 : (strong ? 0.15 : 0.09) + 0.17 * k,
    );
    final bottom = base.withValues(
      alpha: chosen ? 0.40 : (strong ? 0.05 : 0.025) + 0.08 * k,
    );
    final flat = look.amoled ? const Color(0xFF111114) : AetherTokens.inkRaised;
    final edge = look.chrome == 'outline'
        ? 0.5
        : (enabled ? 0.16 + 0.14 * k : 0.12);
    final shadows = <BoxShadow>[
      if (enabled || look.chrome == 'shadow')
        BoxShadow(
          color: Colors.black.withValues(
            alpha: look.chrome == 'shadow' ? 0.55 : 0.26,
          ),
          blurRadius: look.chrome == 'shadow' ? 30 : 22,
          offset: const Offset(0, 10),
        ),
      if (look.chrome == 'glow')
        BoxShadow(color: look.accent.withValues(alpha: 0.45), blurRadius: 22),
    ];

    Widget content = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: shape,
        gradient: enabled
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [top, bottom],
              )
            : LinearGradient(
                colors: [
                  flat.withValues(alpha: 0.96),
                  flat.withValues(alpha: 0.96),
                ],
              ),
        border: Border.all(
          color: chosen
              ? Colors.white.withValues(alpha: 0.55)
              : (look.chrome == 'glow' ? look.accent : Colors.white).withValues(
                  alpha: edge,
                ),
          width: chosen || look.chrome == 'outline' ? 1.3 : 0.8,
        ),
        boxShadow: shadows,
      ),
      child: padding == null ? child : Padding(padding: padding!, child: child),
    );

    if (enabled && !look.noBlur) {
      final sigma = blur * (0.5 + 0.9 * k);
      content = ClipRRect(
        borderRadius: shape,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
          child: content,
        ),
      );
    } else {
      content = ClipRRect(borderRadius: shape, child: content);
    }
    return RepaintBoundary(child: content);
  }
}

/// A round or pill-shaped glass button with a real tap target (min 44 px) and a semantic label.
class GlassButton extends StatelessWidget {
  const GlassButton({
    super.key,
    this.icon,
    this.label,
    required this.onPressed,
    this.tooltip,
    this.prominent = false,
    this.size = 44,
    this.selected = false,
    this.liquid = false,
  });

  /// Real Liquid Glass (refraction) for this button; use it on the few main controls of a screen, not on every chip.
  final bool liquid;

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
    final child = FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (icon != null)
            Icon(
              icon,
              size: 20,
              color: enabled ? fg : fg.withValues(alpha: 0.4),
            ),
          if (icon != null && label != null) const SizedBox(width: 8),
          if (label != null)
            Text(
              label!,
              maxLines: 1,
              softWrap: false,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                fontSize: 14,
                color: enabled ? fg : fg.withValues(alpha: 0.4),
              ),
            ),
        ],
      ),
    );
    final isRound = label == null;
    // «Angoli» also shapes the buttons: round ones stay round, pills get squarer with sharper corners.
    final br = isRound
        ? size / 2
        : (size / 2).clamp(0.0, look.corner * 1.6 + 4);
    final body = prominent
        ? DecoratedBox(
            decoration: BoxDecoration(
              color: look.accent,
              borderRadius: BorderRadius.circular(br),
            ),
            child: SizedBox(
              height: size,
              width: isRound ? size : null,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: isRound ? 0 : 20),
                child: Center(child: child),
              ),
            ),
          )
        : GlassSurface(
            radius: br * 14 / look.corner,
            liquid: liquid,
            strong: selected,
            tint: selected ? look.accent : null,
            child: SizedBox(
              height: size,
              width: isRound ? size : null,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: isRound ? 0 : 18),
                child: Center(child: child),
              ),
            ),
          );
    return Semantics(
      button: true,
      enabled: enabled,
      label: tooltip ?? label,
      excludeSemantics: true,
      child: Tooltip(
        message: tooltip ?? label ?? '',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onPressed,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: 44,
              minHeight: size < 44 ? 44 : size,
            ),
            child: Align(
              widthFactor: 1,
              heightFactor: 1,
              child: _PressScale(enabled: enabled, child: body),
            ),
          ),
        ),
      ),
    );
  }
}

/// The animated page background: deep ink, moving light in the style the viewer chose, and (when [tint] is given) the colour
/// of the film on screen.
class AetherBackdrop extends StatelessWidget {
  const AetherBackdrop({super.key, this.tint, this.child});
  final Color? tint;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final look = AetherLook.of(context);
    final base = look.amoled
        ? Colors.black
        : (look.customBackground ?? AetherTokens.ink);
    final glow = (look.cinematic ? tint : null) ?? look.accent;
    final reduced = look.reduceEffects || look.backdropStyle == 'plain';
    final k = look.backdropIntensity;
    final strength =
        (look.amoled ? 0.10 : (look.cinematic && tint != null ? 0.40 : 0.26)) *
        k;
    return AnimatedContainer(
      duration: (reduced || !look.animations)
          ? Duration.zero
          : AetherTokens.slow,
      color: base,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (!reduced)
            RepaintBoundary(
              child: _BackdropFx(
                style: look.backdropStyle,
                glow: glow,
                second: look.halos && !look.amoled ? look.secondary : null,
                strength: strength.clamp(0.0, 0.85),
                moving: look.animations,
              ),
            ),
          // Ink (list tiles, switches) paints on the nearest Material: give the page one above the coloured backdrop.
          if (child != null)
            Material(type: MaterialType.transparency, child: child),
        ],
      ),
    );
  }
}

/// The light itself. aurora: two soft lights drifting; flow: slow diagonal waves; spotlight: a cone from above that breathes.
class _BackdropFx extends StatefulWidget {
  const _BackdropFx({
    required this.style,
    required this.glow,
    required this.second,
    required this.strength,
    required this.moving,
  });
  final String style;
  final Color glow;
  final Color? second;
  final double strength;
  final bool moving;

  @override
  State<_BackdropFx> createState() => _BackdropFxState();
}

class _BackdropFxState extends State<_BackdropFx>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 26),
  );

  @override
  void initState() {
    super.initState();
    if (widget.moving) _c.repeat();
  }

  @override
  void didUpdateWidget(_BackdropFx old) {
    super.didUpdateWidget(old);
    if (widget.moving && !_c.isAnimating) _c.repeat();
    if (!widget.moving && _c.isAnimating) _c.stop();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    builder: (context, _) {
      final t = _c.value * 2 * math.pi;
      final a = widget.glow;
      final b = widget.second ?? widget.glow;
      final st = widget.strength;
      switch (widget.style) {
        case 'flow':
          return DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment(-1 + 0.6 * math.sin(t), -1),
                end: Alignment(1, 1 + 0.6 * math.cos(t)),
                colors: [
                  a.withValues(alpha: st * 0.95),
                  Colors.transparent,
                  b.withValues(alpha: st * 0.8),
                  Colors.transparent,
                  a.withValues(alpha: st * 0.5),
                ],
                stops: const [0, 0.28, 0.55, 0.78, 1],
              ),
            ),
          );
        case 'spotlight':
          return DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment(0.15 * math.sin(t), -1.15),
                radius: 1.0 + 0.12 * math.sin(t * 2),
                colors: [
                  Colors.white.withValues(alpha: st * 0.45),
                  a.withValues(alpha: st * 0.55),
                  Colors.transparent,
                ],
                stops: const [0, 0.35, 1],
              ),
            ),
          );
        default:
          return Stack(
            fit: StackFit.expand,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment(
                      0.7 + 0.25 * math.sin(t),
                      -0.9 + 0.2 * math.cos(t),
                    ),
                    radius: 1.25,
                    colors: [
                      a.withValues(alpha: st),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: Alignment(
                      -0.8 + 0.25 * math.cos(t),
                      0.9 - 0.2 * math.sin(t),
                    ),
                    radius: 1.0,
                    colors: [
                      b.withValues(alpha: st * 0.6),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ],
          );
      }
    },
  );
}

/// Presses a control like a drop of glass: it shrinks a little under the finger and springs back.
class _PressScale extends StatefulWidget {
  const _PressScale({required this.child, required this.enabled});
  final Widget child;
  final bool enabled;

  @override
  State<_PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<_PressScale> {
  bool _down = false;

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (_) => widget.enabled ? setState(() => _down = true) : null,
    onPointerUp: (_) => setState(() => _down = false),
    onPointerCancel: (_) => setState(() => _down = false),
    child: AnimatedScale(
      scale: _down ? 0.93 : 1,
      duration: const Duration(milliseconds: 140),
      curve: _down ? Curves.easeOut : Curves.easeOutBack,
      child: widget.child,
    ),
  );
}
