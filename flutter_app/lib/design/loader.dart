import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'tokens.dart';

/// The loading animation of the player: a ring of dots that swell and fade one after the other, in the accent colour.
class AetherLoader extends StatefulWidget {
  const AetherLoader({super.key, this.size = 44});
  final double size;

  @override
  State<AetherLoader> createState() => _AetherLoaderState();
}

class _AetherLoaderState extends State<AetherLoader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1300),
  )..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = AetherLook.of(context).accent;
    return RepaintBoundary(
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: AnimatedBuilder(
          animation: _c,
          builder: (_, __) =>
              CustomPaint(painter: _DotsPainter(_c.value, accent)),
        ),
      ),
    );
  }
}

class _DotsPainter extends CustomPainter {
  _DotsPainter(this.t, this.color);
  final double t;
  final Color color;
  static const _dots = 8;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final ring = size.width / 2 - size.width * 0.09;
    for (var i = 0; i < _dots; i++) {
      // Every dot peaks a little after the one before it; the peak travels around the ring.
      final phase = (t - i / _dots) % 1.0;
      final k = math.pow(1 - phase, 2).toDouble();
      final angle = -math.pi / 2 + i * 2 * math.pi / _dots;
      final radius = size.width * (0.04 + 0.05 * k);
      canvas.drawCircle(
        c + Offset(math.cos(angle), math.sin(angle)) * ring,
        radius,
        Paint()..color = color.withValues(alpha: 0.18 + 0.82 * k),
      );
    }
  }

  @override
  bool shouldRepaint(_DotsPainter old) => old.t != t || old.color != color;
}
