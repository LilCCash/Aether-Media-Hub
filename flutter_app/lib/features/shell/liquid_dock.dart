import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:liquid_glass_renderer/liquid_glass_renderer.dart';

import '../../design/liquid.dart';
import '../../design/tokens.dart';

/// The floating tab bar: a Liquid Glass capsule with a lens under the current tab. Tap a tab, or press anywhere on the bar and
/// slide: the lens follows the finger (stretching a little) and the tab under it opens when you let go.
class LiquidDock extends StatefulWidget {
  const LiquidDock({
    super.key,
    required this.items,
    required this.index,
    required this.onSelect,
    this.opacity = 0.12,
  });

  final List<(IconData, String)> items;
  final int index;
  final ValueChanged<int> onSelect;

  /// How dense the bar's glass is (0 clear … 1 tinted).
  final double opacity;

  @override
  State<LiquidDock> createState() => _LiquidDockState();
}

class _LiquidDockState extends State<LiquidDock> {
  double? _drag; // fractional tab position while a finger is sliding
  double _stretch =
      0; // 0..1: how fast the lens is moving, it squashes and stretches with it
  int _lastHaptic = -1;
  bool _pressed = false;

  /// A quick squash-and-stretch each time the lens jumps to another tab, then it settles back.
  void _pulse() {
    setState(() => _stretch = 0.9);
    Future<void>.delayed(const Duration(milliseconds: 160), () {
      if (mounted && _drag == null) setState(() => _stretch = 0);
    });
  }

  double _pos(double x, double itemW) =>
      ((x - 6) / itemW - 0.5).clamp(0.0, widget.items.length - 1.0);

  @override
  Widget build(BuildContext context) {
    final look = AetherLook.of(context);
    final n = widget.items.length;
    final moving = look.animations && !look.reduceEffects;
    return LayoutBuilder(
      builder: (context, c) {
        final itemW = (c.maxWidth - 12) / n;
        final shown = _drag ?? widget.index.toDouble();
        final dragging = _drag != null;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: (d) {
            setState(() => _drag = _pos(d.localPosition.dx, itemW));
          },
          onHorizontalDragUpdate: (d) {
            final p = _pos(d.localPosition.dx, itemW);
            if (p.round() != _lastHaptic) {
              _lastHaptic = p.round();
              HapticFeedback.selectionClick();
            }
            setState(() {
              _drag = p;
              _stretch = (_stretch * 0.5 + (d.delta.dx.abs() / 14) * 0.5).clamp(
                0.0,
                1.0,
              );
            });
          },
          onHorizontalDragEnd: (_) {
            final target = (_drag ?? widget.index.toDouble()).round();
            setState(() {
              _drag = null;
              _stretch = 0;
            });
            _lastHaptic = -1;
            if (target != widget.index) widget.onSelect(target);
          },
          onHorizontalDragCancel: () => setState(() => _drag = null),
          onTapDown: (_) => setState(() => _pressed = true),
          onTapCancel: () => setState(() => _pressed = false),
          onTapUp: (d) {
            final target = _pos(d.localPosition.dx, itemW).round();
            HapticFeedback.selectionClick();
            setState(() => _pressed = false);
            if (target != widget.index) _pulse();
            widget.onSelect(target);
          },
          child: AnimatedScale(
            scale: _pressed || dragging ? 1.03 : 1,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutBack,
            child: LiquidSurface(
              radius: 34,
              strong: true,
              child: SizedBox(
                height: 68,
                child: Stack(
                  children: [
                    // The lens.
                    AnimatedPositioned(
                      duration: (dragging || !moving)
                          ? Duration.zero
                          : const Duration(milliseconds: 380),
                      curve: Curves.easeOutBack,
                      left: 6 + shown * itemW,
                      width: itemW,
                      top: 6,
                      bottom: 6,
                      child: AnimatedScale(
                        scale: dragging ? 1.16 : 1,
                        duration: const Duration(milliseconds: 180),
                        curve: Curves.easeOutBack,
                        child: TweenAnimationBuilder<double>(
                          // Squash and stretch along the movement, like a drop of liquid being dragged.
                          tween: Tween(end: _stretch),
                          duration: const Duration(milliseconds: 140),
                          curve: Curves.easeOut,
                          builder: (context, st, child) => Transform.scale(
                            scaleX: 1 + 0.3 * st,
                            scaleY: 1 - 0.14 * st,
                            child: child,
                          ),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              // Clear glass, no colour: a thin bright edge and a very faint lift, the page shows through.
                              DecoratedBox(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(28),
                                  color: Colors.white.withValues(
                                    alpha: dragging ? 0.05 : 0.08,
                                  ),
                                  border: Border.all(
                                    color: Colors.white.withValues(
                                      alpha: dragging ? 0.5 : 0.3,
                                    ),
                                    width: 1,
                                  ),
                                ),
                              ),
                              // While it is held the lens becomes a second piece of glass that refracts the bar and the page.
                              if (liquidAvailable(context))
                                LiquidGlass.withOwnLayer(
                                  settings: LiquidGlassSettings.ios27Regular(
                                    brightness: Brightness.dark,
                                    tintAmount: 0.0,
                                  ),
                                  shape: LiquidRoundedSuperellipse(
                                    borderRadius: 28,
                                  ),
                                  child: const SizedBox.expand(),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Row(
                        children: [
                          for (var i = 0; i < n; i++)
                            Expanded(
                              child: Semantics(
                                button: true,
                                selected: widget.index == i,
                                label: widget.items[i].$2,
                                excludeSemantics: true,
                                child: _Tab(
                                  icon: widget.items[i].$1,
                                  label: widget.items[i].$2,
                                  near: (shown - i).abs().clamp(0.0, 1.0),
                                  accent: look.accent,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.icon,
    required this.label,
    required this.near,
    required this.accent,
  });
  final IconData icon;
  final String label;

  /// 0 when the lens is on this tab, 1 when it is a tab away or more.
  final double near;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final on = 1 - near;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Transform.scale(
          scale: 1 + 0.12 * on,
          child: Icon(
            icon,
            size: 25,
            color: Color.lerp(
              AetherTokens.textSecondary,
              Color.lerp(accent, Colors.white, 0.2),
              on,
            ),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            color: Color.lerp(
              AetherTokens.textTertiary,
              Color.lerp(accent, Colors.white, 0.2),
              on,
            ),
          ),
        ),
      ],
    );
  }
}
