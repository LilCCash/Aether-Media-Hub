import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/model/meta.dart';
import 'glass.dart';
import 'tokens.dart';

/// A poster (or 16:9 card) with a graceful placeholder: initials on a gradient when there is no picture or it fails.
class PosterImage extends StatelessWidget {
  const PosterImage({super.key, required this.url, required this.title, this.radius = AetherTokens.rMedium, this.fit = BoxFit.cover});
  final String? url;
  final String title;
  final double radius;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final initials = title.trim().isEmpty ? '?' : title.trim().split(RegExp(r'\s+')).take(2).map((w) => w[0]).join().toUpperCase();
    Widget placeholder() => DecoratedBox(
          decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [AetherTokens.inkRaised, Colors.white.withValues(alpha: 0.10)])),
          child: Center(child: Text(initials, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: AetherTokens.textTertiary))),
        );
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: url == null || url!.isEmpty
          ? placeholder()
          : CachedNetworkImage(
              imageUrl: url!,
              fit: fit,
              fadeInDuration: AetherTokens.medium,
              placeholder: (_, __) => placeholder(),
              errorWidget: (_, __, ___) => placeholder(),
              memCacheWidth: 600,
            ),
    );
  }
}

/// A catalog card: poster, a title below, optional rating chip.
class PosterCard extends StatelessWidget {
  const PosterCard({super.key, required this.item, required this.onTap, this.width = 120, this.showRating = true});
  final MetaItem item;
  final VoidCallback onTap;
  final double width;
  final bool showRating;

  @override
  Widget build(BuildContext context) {
    final height = item.landscape ? width * 9 / 16 : width * 1.5;
    return Semantics(
      button: true,
      label: item.name,
      child: GestureDetector(
        onTap: onTap,
        child: SizedBox(
          width: width,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              height: height,
              child: Stack(fit: StackFit.expand, children: [
                PosterImage(url: item.poster ?? item.background, title: item.name),
                if (showRating && item.imdbRating != null)
                  Positioned(top: 6, right: 6, child: GlassSurface(radius: 10, blur: 8, padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3), child: Row(mainAxisSize: MainAxisSize.min, children: [const Icon(Icons.star_rounded, size: 12, color: AetherTokens.warning), const SizedBox(width: 2), Text(item.imdbRating!, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700))]))),
              ]),
            ),
            const SizedBox(height: 6),
            Text(item.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, height: 1.2)),
            if (item.releaseInfo != null) Text(item.releaseInfo!, maxLines: 1, style: Theme.of(context).textTheme.bodySmall),
          ]),
        ),
      ),
    );
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader({super.key, required this.title, this.subtitle, this.trailing});
  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AetherTokens.pageMargin, 22, AetherTokens.pageMargin, 10),
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Semantics(header: true, child: Text(title, style: Theme.of(context).textTheme.titleLarge, maxLines: 1, overflow: TextOverflow.ellipsis)),
            if (subtitle != null) Text(subtitle!, style: Theme.of(context).textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
          ]),
        ),
        if (trailing != null) trailing!,
      ]),
    );
  }
}

/// Loading placeholder (no animation when effects are reduced).
class Skeleton extends StatefulWidget {
  const Skeleton({super.key, this.width, this.height = 16, this.radius = 10});
  final double? width;
  final double height;
  final double radius;

  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final animate = !AetherLook.of(context).reduceEffects && !(MediaQuery.maybeOf(context)?.disableAnimations ?? false);
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) => Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(color: Colors.white.withValues(alpha: animate ? 0.05 + 0.05 * _c.value : 0.07), borderRadius: BorderRadius.circular(widget.radius)),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.message, this.action});
  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 44, color: AetherTokens.textTertiary),
          const SizedBox(height: 14),
          Text(title, style: Theme.of(context).textTheme.titleMedium, textAlign: TextAlign.center),
          if (message != null) ...[const SizedBox(height: 6), Text(message!, style: Theme.of(context).textTheme.bodySmall, textAlign: TextAlign.center)],
          if (action != null) ...[const SizedBox(height: 18), action!],
        ]),
      ),
    );
  }
}

class ErrorState extends StatelessWidget {
  const ErrorState({super.key, required this.message, this.onRetry});
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => EmptyState(
        icon: Icons.cloud_off_rounded,
        title: 'Qualcosa non ha funzionato',
        message: message,
        action: onRetry == null ? null : GlassButton(icon: Icons.refresh_rounded, label: 'Riprova', onPressed: onRetry),
      );
}

/// A small pill used for quality / HDR / language badges.
class Pill extends StatelessWidget {
  const Pill(this.text, {super.key, this.color});
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Colors.white;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.16), borderRadius: BorderRadius.circular(AetherTokens.rPill), border: Border.all(color: c.withValues(alpha: 0.35), width: 0.7)),
      child: Text(text, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: c.withValues(alpha: 0.95))),
    );
  }
}
