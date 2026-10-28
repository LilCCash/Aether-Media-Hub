import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
  });

  final List<(IconData, String)> items;
  final int index;
  final ValueChanged<int> onSelect;

  @override
  State<LiquidDock> createState() => _LiquidDockState();
}

class _LiquidDockState extends State<LiquidDock> {
  double? _drag; // fractional tab position while a finger is sliding
  int _lastHaptic = -1;

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
            setState(() => _drag = p);
          },
          onHorizontalDragEnd: (_) {
            final target = (_drag ?? widget.index.toDouble()).round();
            setState(() => _drag = null);
            _lastHaptic = -1;
            if (target != widget.index) widget.onSelect(target);
          },
          onHorizontalDragCancel: () => setState(() => _drag = null),
          onTapUp: (d) {
            final target = _pos(d.localPosition.dx, itemW).round();
            HapticFeedback.selectionClick();
            widget.onSelect(target);
          },
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
                      scale: dragging ? 1.14 : 1,
                      duration: const Duration(milliseconds: 160),
                      curve: Curves.easeOut,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(28),
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.white.withValues(
                                alpha: dragging ? 0.30 : 0.20,
                              ),
                              look.accent.withValues(
                                alpha: dragging ? 0.34 : 0.22,
                              ),
                            ],
                          ),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.30),
                            width: 0.8,
                          ),
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
            color: Color.lerp(AetherTokens.textSecondary, Colors.white, on),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            color: Color.lerp(AetherTokens.textTertiary, Colors.white, on),
          ),
        ),
      ],
    );
  }
}
