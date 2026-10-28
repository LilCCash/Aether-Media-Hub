import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../design/tokens.dart';
import '../theater/theater_prefs.dart';

enum TapOutcome { ignored, heat, pop }

/// Counts quick taps: [threshold] in a row (each less than [window] after the last) is a «pop»; after a pop it rests for
/// [cooldown] so hammering cannot pop twice at once. Pure logic, the clock is passed in, so it is tested without a screen.
class TapTracker {
  TapTracker({
    this.threshold = 7,
    this.window = const Duration(milliseconds: 1500),
    this.cooldown = const Duration(milliseconds: 3600),
  });

  final int threshold;
  final Duration window;
  final Duration cooldown;
  int taps = 0;
  int pops = 0;
  Duration? _last;
  Duration? _restUntil;

  TapOutcome register(Duration now) {
    final rest = _restUntil;
    if (rest != null) {
      if (now < rest && now >= (_last ?? now)) return TapOutcome.ignored;
      _restUntil = null;
      taps = 0;
    }
    final last = _last;
    if (last != null && (now < last || now - last >= window)) taps = 0;
    taps++;
    _last = now;
    if (taps >= threshold) {
      taps = 0;
      pops++;
      _restUntil = now + cooldown;
      return TapOutcome.pop;
    }
    return TapOutcome.heat;
  }
}

/// A burst over the whole screen: falling emoji and a line of text; optionally cinema bars that close in and open again.
void showBurst(
  BuildContext context, {
  required List<String> emoji,
  required String banner,
  bool bars = false,
  Duration duration = const Duration(milliseconds: 2800),
}) {
  final overlay = Overlay.of(context, rootOverlay: true);
  final reduce = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (_) => _Burst(
      emoji: emoji,
      banner: banner,
      bars: bars,
      still: reduce,
      duration: duration,
      onDone: () => entry.remove(),
    ),
  );
  overlay.insert(entry);
}

class _Burst extends StatefulWidget {
  const _Burst({
    required this.emoji,
    required this.banner,
    required this.bars,
    required this.still,
    required this.duration,
    required this.onDone,
  });
  final List<String> emoji;
  final String banner;
  final bool bars;
  final bool still;
  final Duration duration;
  final VoidCallback onDone;

  @override
  State<_Burst> createState() => _BurstState();
}

class _BurstState extends State<_Burst> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: widget.duration,
  )..forward().whenComplete(widget.onDone);
  final _rnd = math.Random();
  late final List<({double x, double delay, double speed, double spin, int e})>
  _drops = [
    for (var i = 0; i < 26; i++)
      (
        x: _rnd.nextDouble(),
        delay: _rnd.nextDouble() * 0.45,
        speed: 0.7 + _rnd.nextDouble() * 0.5,
        spin: (_rnd.nextDouble() - 0.5) * 6,
        e: _rnd.nextInt(widget.emoji.length),
      ),
  ];

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return IgnorePointer(
      child: Semantics(
        liveRegion: true,
        label: widget.banner,
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) {
            final t = _c.value;
            final fade = t < 0.1 ? t / 0.1 : (t > 0.85 ? (1 - t) / 0.15 : 1.0);
            // The bars close in for the first third and open for the last third.
            final bar = widget.bars
                ? (t < 0.3 ? t / 0.3 : (t > 0.7 ? (1 - t) / 0.3 : 1.0)) *
                      size.height *
                      0.18
                : 0.0;
            return Stack(
              fit: StackFit.expand,
              children: [
                if (widget.bars) ...[
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    height: bar,
                    child: const ColoredBox(color: Colors.black),
                  ),
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    height: bar,
                    child: const ColoredBox(color: Colors.black),
                  ),
                ],
                if (!widget.still)
                  for (final d in _drops)
                    Positioned(
                      left: d.x * (size.width - 30),
                      top:
                          -40 +
                          ((t - d.delay).clamp(0.0, 1.0) / (1 - d.delay)) *
                              d.speed *
                              (size.height + 80),
                      child: Opacity(
                        opacity: t < d.delay ? 0 : fade,
                        child: Transform.rotate(
                          angle: t * d.spin,
                          child: Text(
                            widget.emoji[d.e],
                            style: const TextStyle(fontSize: 28),
                          ),
                        ),
                      ),
                    ),
                Align(
                  alignment: const Alignment(0, 0.15),
                  child: Opacity(
                    opacity: fade,
                    child: Material(
                      color: Colors.transparent,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.72),
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: Text(
                          widget.banner,
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// The app icon in «Informazioni». It warms up with every tap.
class AboutLogo extends StatefulWidget {
  const AboutLogo({super.key});

  @override
  State<AboutLogo> createState() => _AboutLogoState();
}

class _AboutLogoState extends State<AboutLogo> {
  final _tracker = TapTracker();
  final _clock = Stopwatch()..start();
  int _heat = 0;
  double _turns = 0;
  static const _lines = [
    'Pop! 🍿',
    'Il chicco è scoppiato!',
    'Pronti per il film?',
    'Burro e sale, grazie.',
  ];

  void _tap() {
    final out = _tracker.register(_clock.elapsed);
    switch (out) {
      case TapOutcome.ignored:
        return;
      case TapOutcome.heat:
        HapticFeedback.lightImpact();
        setState(() => _heat = _tracker.taps);
        Future<void>.delayed(const Duration(milliseconds: 1600), () {
          if (mounted && _tracker.taps == _heat) setState(() => _heat = 0);
        });
      case TapOutcome.pop:
        HapticFeedback.heavyImpact();
        setState(() {
          _heat = 0;
          _turns += 1;
        });
        showBurst(
          context,
          emoji: const ['🍿', '🍿', '✨'],
          banner: _lines[(_tracker.pops - 1) % _lines.length],
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final warm = Color.lerp(
      Colors.transparent,
      const Color(0xFFFF9500),
      _heat / 8,
    )!;
    return Semantics(
      button: true,
      label: 'Logo di Aether',
      child: GestureDetector(
        onTap: _tap,
        child: AnimatedRotation(
          turns: _turns,
          duration: const Duration(milliseconds: 800),
          curve: Curves.easeInOutBack,
          child: AnimatedScale(
            scale: 1 + _heat * 0.035,
            duration: const Duration(milliseconds: 150),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(26),
              child: ColorFiltered(
                colorFilter: ColorFilter.mode(warm, BlendMode.srcATop),
                child: Image.asset(
                  'assets/brand/icon.png',
                  width: 104,
                  height: 104,
                  excludeFromSemantics: true,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The «Theater Mode» badge of the About page, as on iOS.
class TheaterLogo extends StatefulWidget {
  const TheaterLogo({super.key});

  @override
  State<TheaterLogo> createState() => _TheaterLogoState();
}

class _TheaterLogoState extends State<TheaterLogo> {
  final _tracker = TapTracker(threshold: 5);
  final _clock = Stopwatch()..start();
  int _flash = 0;
  static const _lines = [
    'Ciak! Si gira. 🎬',
    'Azione!',
    'Silenzio in sala.',
    'Questa scena è perfetta.',
  ];

  void _tap() {
    final out = _tracker.register(_clock.elapsed);
    if (out == TapOutcome.ignored) return;
    HapticFeedback.selectionClick();
    setState(() => _flash = out == TapOutcome.pop ? 0 : _tracker.taps);
    if (out == TapOutcome.pop) {
      HapticFeedback.mediumImpact();
      showBurst(
        context,
        emoji: const ['🎬', '🎞️', '⭐'],
        banner: _lines[(_tracker.pops - 1) % _lines.length],
        bars: true,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final accent = TheaterPalette.gold.color;
    return Semantics(
      button: true,
      label: 'Theater Mode, versione ${TheaterPrefs.version}',
      child: GestureDetector(
        onTap: _tap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: accent.withValues(alpha: 0.4 + _flash * 0.1),
              width: 1.2,
            ),
            boxShadow: [
              BoxShadow(
                color: accent.withValues(alpha: _flash * 0.09),
                blurRadius: 6.0 + _flash * 4,
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.theaters_rounded, color: accent, size: 20),
              const SizedBox(width: 10),
              Text(
                'THEATER MODE',
                style: TextStyle(
                  fontSize: 12,
                  letterSpacing: 4,
                  fontWeight: FontWeight.w800,
                  color: accent,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                TheaterPrefs.version,
                style: const TextStyle(
                  fontSize: 11,
                  color: AetherTokens.textTertiary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
