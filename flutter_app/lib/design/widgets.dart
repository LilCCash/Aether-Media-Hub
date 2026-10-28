import '../core/catalog/result_filters.dart';
import '../core/streams/badge_pack.dart';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/model/meta.dart';
import 'glass.dart';
import 'image_cache.dart';
import 'tokens.dart';

/// A poster (or 16:9 card) with a graceful placeholder: initials on a gradient when there is no picture or it fails.
class PosterImage extends StatelessWidget {
  /// Widget tests switch pictures off (no platform cache is available there).
  static bool disableNetwork = false;

  const PosterImage({
    super.key,
    required this.url,
    required this.title,
    this.radius,
    this.fit = BoxFit.cover,
    this.alignment = Alignment.center,
    this.cacheWidth = 600,
  });

  /// Where a cropped picture is anchored (top for posters, so heads are not cut) and the decoded width (big for hero art).
  final Alignment alignment;
  final int cacheWidth;

  /// Cinemeta serves art in sizes; the small ones look grainy when stretched over a hero, so ask for the large one.
  static String sharper(String url) => url
      .replaceFirst('/poster/small/', '/poster/large/')
      .replaceFirst('/poster/medium/', '/poster/large/')
      .replaceFirst('/background/small/', '/background/large/')
      .replaceFirst('/background/medium/', '/background/large/');
  final String? url;
  final String title;
  final double? radius;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    final initials = title.trim().isEmpty
        ? '?'
        : title
              .trim()
              .split(RegExp(r'\s+'))
              .take(2)
              .map((w) => w[0])
              .join()
              .toUpperCase();
    Widget placeholder() => DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AetherTokens.inkRaised,
            Colors.white.withValues(alpha: 0.10),
          ],
        ),
      ),
      child: Center(
        child: Text(
          initials,
          style: const TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w800,
            color: AetherTokens.textTertiary,
          ),
        ),
      ),
    );
    return ClipRRect(
      borderRadius: BorderRadius.circular(
        radius ?? AetherLook.of(context).corner,
      ),
      child: url == null || url!.isEmpty || disableNetwork
          ? placeholder()
          : CachedNetworkImage(
              cacheManager: AetherImageCache.manager,
              imageUrl: cacheWidth > 600 ? sharper(url!) : url!,
              fit: fit,
              alignment: alignment,
              filterQuality: FilterQuality.high,
              fadeInDuration: AetherTokens.medium,
              placeholder: (_, __) => placeholder(),
              errorWidget: (_, __, ___) => placeholder(),
              memCacheWidth: cacheWidth,
            ),
    );
  }
}

/// A catalog card: poster, a title below, optional rating chip.
/// The frame a card gets from the «Cornice» setting.
BoxDecoration _chrome(AetherLook look) {
  final r = BorderRadius.circular(look.corner);
  switch (look.chrome) {
    case 'outline':
      return BoxDecoration(
        borderRadius: r,
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.35),
          width: 1.2,
        ),
      );
    case 'shadow':
      return BoxDecoration(
        borderRadius: r,
        boxShadow: const [
          BoxShadow(
            color: Colors.black87,
            blurRadius: 14,
            offset: Offset(0, 6),
          ),
        ],
      );
    case 'glow':
      return BoxDecoration(
        borderRadius: r,
        boxShadow: [
          BoxShadow(color: look.accent.withValues(alpha: 0.55), blurRadius: 16),
        ],
      );
    default:
      return BoxDecoration(borderRadius: r);
  }
}

class PosterCard extends StatelessWidget {
  const PosterCard({
    super.key,
    required this.item,
    required this.onTap,
    this.width = 120,
    this.showRating = true,
  });
  final MetaItem item;
  final VoidCallback onTap;
  final double width;
  final bool showRating;

  @override
  Widget build(BuildContext context) {
    final look = AetherLook.of(context);
    return Semantics(
      button: true,
      label: item.name,
      child: GestureDetector(
        onTap: onTap,
        child: SizedBox(
          width: width * look.posterScale,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    DecoratedBox(
                      position: DecorationPosition.foreground,
                      decoration: _chrome(look),
                      child: PosterImage(
                        url: item.poster ?? item.background,
                        title: item.name,
                      ),
                    ),
                    if (showRating &&
                        look.posterRatings &&
                        item.imdbRating != null)
                      Positioned(
                        top: 6,
                        right: 6,
                        child: GlassSurface(
                          radius: 10,
                          blur: 8,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 3,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.star_rounded,
                                size: 12,
                                color: AetherTokens.warning,
                              ),
                              const SizedBox(width: 2),
                              Text(
                                item.imdbRating!,
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Text(
                item.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  height: 1.2,
                ),
              ),
              if (item.releaseInfo != null)
                Text(
                  item.releaseInfo!,
                  maxLines: 1,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
  });
  final String title;
  final String? subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AetherTokens.pageMargin,
        22,
        AetherTokens.pageMargin,
        10,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  header: true,
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleLarge,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: Theme.of(context).textTheme.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
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

class _SkeletonState extends State<Skeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final animate =
        !AetherLook.of(context).reduceEffects &&
        !(MediaQuery.maybeOf(context)?.disableAnimations ?? false);
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) => Container(
        width: widget.width,
        height: widget.height,
        decoration: BoxDecoration(
          color: Colors.white.withValues(
            alpha: animate ? 0.05 + 0.05 * _c.value : 0.07,
          ),
          borderRadius: BorderRadius.circular(widget.radius),
        ),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
  });
  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: AetherTokens.textTertiary),
            const SizedBox(height: 14),
            Text(
              title,
              style: Theme.of(context).textTheme.titleMedium,
              textAlign: TextAlign.center,
            ),
            if (message != null) ...[
              const SizedBox(height: 6),
              Text(
                message!,
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ],
            if (action != null) ...[const SizedBox(height: 18), action!],
          ],
        ),
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
    action: onRetry == null
        ? null
        : GlassButton(
            icon: Icons.refresh_rounded,
            label: 'Riprova',
            onPressed: onRetry,
          ),
  );
}

/// A small pill used for quality / HDR / language badges.
class Pill extends StatelessWidget {
  const Pill(this.text, {super.key, this.color, this.style = 'filled'});
  final String text;
  final Color? color;

  /// `filled`, `outline` or `plain` (the «Stile dei badge» setting).
  final String style;

  @override
  Widget build(BuildContext context) {
    final c = color ?? Colors.white;
    return Container(
      padding: style == 'plain'
          ? const EdgeInsets.symmetric(vertical: 1)
          : const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
      decoration: BoxDecoration(
        gradient: style == 'filled'
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [c.withValues(alpha: 0.24), c.withValues(alpha: 0.10)],
              )
            : null,
        borderRadius: BorderRadius.circular(6),
        border: style == 'plain'
            ? null
            : Border.all(
                color: c.withValues(alpha: style == 'outline' ? 0.65 : 0.30),
                width: 0.6,
              ),
      ),
      child: Text(
        text,
        maxLines: 1,
        style: TextStyle(
          fontSize: 9.5,
          height: 1.25,
          letterSpacing: 0.25,
          fontWeight: FontWeight.w700,
          color: c.withValues(alpha: 0.95),
        ),
      ),
    );
  }
}

/// A badge imported from a link: its own picture when it has one (the name is the fallback), else a coloured pill.
class ImportedBadge extends StatelessWidget {
  const ImportedBadge({super.key, required this.rule});
  final CustomBadgeRule rule;

  static Color? _hex(String? hex) {
    if (hex == null || !RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(hex)) return null;
    return Color(int.parse('FF${hex.substring(1)}', radix: 16));
  }

  @override
  Widget build(BuildContext context) {
    final pill = _pill();
    final url = rule.imageUrl;
    if (url == null) return pill;
    return Semantics(
      label: rule.label,
      child: SizedBox(
        height: 20,
        child: Image.network(
          url,
          fit: BoxFit.contain,
          errorBuilder: (_, __, ___) => pill,
          loadingBuilder: (_, child, progress) =>
              progress == null ? child : pill,
        ),
      ),
    );
  }

  Widget _pill() {
    final accent = _hex(rule.colorHex) ?? Colors.white;
    final fill = _hex(rule.fillHex) ?? Colors.grey;
    final border = _hex(rule.borderHex);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: fill.withValues(alpha: rule.fillAlpha),
        borderRadius: BorderRadius.circular(AetherTokens.rPill),
        border: border == null ? null : Border.all(color: border, width: 1),
      ),
      child: Text(
        rule.label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w800,
          color: accent,
        ),
      ),
    );
  }
}

/// A row of three filter buttons (type, genre, decade) that open a list to pick from, plus "Azzera" when one is set.
class FilterBar extends StatelessWidget {
  const FilterBar({
    super.key,
    required this.filters,
    required this.types,
    required this.genres,
    required this.decades,
    required this.onChanged,
    this.typeName = _plain,
  });

  final ResultFilters filters;
  final List<String> types;
  final List<String> genres;
  final List<int> decades;
  final ValueChanged<ResultFilters> onChanged;
  final String Function(String) typeName;

  static String _plain(String s) => s;

  Future<T?> _pick<T>(
    BuildContext context,
    String title,
    List<T> options,
    String Function(T) label,
  ) {
    return showModalBottomSheet<T>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text(title, style: Theme.of(c).textTheme.titleMedium),
            ),
            for (final o in options)
              ListTile(title: Text(label(o)), onTap: () => Navigator.pop(c, o)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        children: [
          if (types.length > 1)
            _chip(
              context,
              filters.type == null ? 'Tipo' : typeName(filters.type!),
              filters.type != null,
              () async {
                final v = await _pick<String>(context, 'Tipo', types, typeName);
                if (v != null) onChanged(filters.copyWith(type: v));
              },
            ),
          if (genres.isNotEmpty)
            _chip(
              context,
              filters.genre ?? 'Genere',
              filters.genre != null,
              () async {
                final v = await _pick<String>(
                  context,
                  'Genere',
                  genres,
                  (s) => s,
                );
                if (v != null) onChanged(filters.copyWith(genre: v));
              },
            ),
          if (decades.isNotEmpty)
            _chip(
              context,
              filters.decade == null ? 'Anno' : '${filters.decade}',
              filters.decade != null,
              () async {
                final v = await _pick<int>(
                  context,
                  'Decennio',
                  decades,
                  (d) => '$d – ${d + 9}',
                );
                if (v != null) onChanged(filters.copyWith(decade: v));
              },
            ),
          if (filters.active)
            _chip(
              context,
              'Azzera',
              false,
              () => onChanged(ResultFilters.none),
            ),
        ],
      ),
    );
  }

  Widget _chip(
    BuildContext context,
    String label,
    bool selected,
    VoidCallback onTap,
  ) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: GlassButton(
      label: label,
      size: 36,
      selected: selected,
      onPressed: onTap,
    ),
  );
}

/// A dropdown: a glass chip showing the current choice and a caret; tapping opens a menu right under it.
class DropChip<T> extends StatelessWidget {
  const DropChip({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onSelected,
    this.icon,
  });

  /// Shown before the value ("Genere").
  final String label;
  final T? value;
  final Map<T, String> options;
  final ValueChanged<T> onSelected;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final look = AetherLook.of(context);
    final active = value != null && options.containsKey(value);
    return PopupMenuButton<T>(
      tooltip: label,
      color: AetherTokens.inkRaised,
      constraints: const BoxConstraints(maxHeight: 420, minWidth: 160),
      offset: const Offset(0, 36),
      onSelected: onSelected,
      itemBuilder: (_) => [
        for (final e in options.entries)
          PopupMenuItem<T>(
            value: e.key,
            child: Row(
              children: [
                Expanded(child: Text(e.value)),
                if (e.key == value)
                  Icon(Icons.check_rounded, size: 18, color: look.accent),
              ],
            ),
          ),
      ],
      child: GlassSurface(
        radius: 16,
        tint: active ? look.accent : null,
        strong: active,
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 13, color: AetherTokens.textSecondary),
              const SizedBox(width: 4),
            ],
            Flexible(
              child: Text(
                active ? options[value]! : label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const Icon(Icons.keyboard_arrow_down_rounded, size: 15),
          ],
        ),
      ),
    );
  }
}
