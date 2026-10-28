import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// Where the last title was tapped, so the page can grow out of that poster (the «Zoom dalla locandina» transition).
class TitleOrigin {
  TitleOrigin._();
  static Rect? rect;

  static void capture(BuildContext context) {
    final box = context.findRenderObject();
    if (box is RenderBox && box.hasSize && box.attached) {
      rect = box.localToGlobal(Offset.zero) & box.size;
    } else {
      rect = null;
    }
  }
}

/// The ways a page can appear. `auto` is the zoom while Dynamic Cinematic is on, else the slide.
enum PageTransitionKind { auto, zoom, fade, slide, none }

PageTransitionKind transitionKindOf(String? name) => PageTransitionKind.values
    .firstWhere((k) => k.name == name, orElse: () => PageTransitionKind.auto);

/// A page with the app's own transition and the left-edge swipe to go back (which works on iOS and Android alike).
class AetherPage<T> extends CustomTransitionPage<T> {
  AetherPage({
    super.key,
    required Widget child,
    required PageTransitionKind Function() kind,
    bool swipeBack = true,
  }) : super(
         child: swipeBack ? EdgeSwipeBack(child: child) : child,
         transitionDuration: const Duration(milliseconds: 420),
         reverseTransitionDuration: const Duration(milliseconds: 320),
         transitionsBuilder: (context, animation, secondary, child) {
           final k = kind();
           if (k == PageTransitionKind.none) return child;
           final curved = CurvedAnimation(
             parent: animation,
             curve: Curves.easeOutCubic,
             reverseCurve: Curves.easeInCubic,
           );
           switch (k) {
             case PageTransitionKind.zoom:
               final size = MediaQuery.sizeOf(context);
               final r = TitleOrigin.rect;
               final align = r == null
                   ? Alignment.center
                   : Alignment(
                       ((r.center.dx / size.width) * 2 - 1).clamp(-1.0, 1.0),
                       ((r.center.dy / size.height) * 2 - 1).clamp(-1.0, 1.0),
                     );
               return FadeTransition(
                 opacity: CurvedAnimation(
                   parent: animation,
                   curve: const Interval(0, 0.7),
                 ),
                 child: ScaleTransition(
                   alignment: align,
                   scale: Tween(begin: 0.55, end: 1.0).animate(curved),
                   child: child,
                 ),
               );
             case PageTransitionKind.fade:
               return FadeTransition(opacity: curved, child: child);
             default:
               return SlideTransition(
                 position: Tween(
                   begin: const Offset(1, 0),
                   end: Offset.zero,
                 ).animate(curved),
                 child: child,
               );
           }
         },
       );
}

/// Drag from the left edge to the right to go back: the page follows the finger and pops past a third of the width or a flick.
class EdgeSwipeBack extends StatefulWidget {
  const EdgeSwipeBack({super.key, required this.child});
  final Widget child;

  @override
  State<EdgeSwipeBack> createState() => _EdgeSwipeBackState();
}

class _EdgeSwipeBackState extends State<EdgeSwipeBack>
    with SingleTickerProviderStateMixin {
  double _dx = 0;
  late final AnimationController _back = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );

  @override
  void dispose() {
    _back.dispose();
    super.dispose();
  }

  void _end(double width, double velocity) {
    final pop = _dx > width * 0.33 || velocity > 700;
    if (pop) {
      Navigator.of(context).maybePop();
      setState(() => _dx = 0);
      return;
    }
    final from = _dx;
    _back
      ..reset()
      ..addListener(() => setState(() => _dx = from * (1 - _back.value)))
      ..forward();
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return Stack(
      children: [
        Transform.translate(offset: Offset(_dx, 0), child: widget.child),
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: 24,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onHorizontalDragStart: (_) => _back.stop(),
            onHorizontalDragUpdate: (d) =>
                setState(() => _dx = (_dx + d.delta.dx).clamp(0.0, width)),
            onHorizontalDragEnd: (d) => _end(width, d.primaryVelocity ?? 0),
          ),
        ),
      ],
    );
  }
}
