import 'dart:async';

import 'package:flutter/material.dart';

import '../../data/settings.dart';
import '../../core/metadata/tmdb_client.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/mood.dart';
import '../../app/providers.dart';
import '../../app/router.dart';
import '../../core/metadata/tvdb_client.dart';
import '../../core/model/meta.dart';
import '../../design/glass.dart';
import '../../design/tokens.dart';
import '../../design/widgets.dart';
import '../../data/library_repository.dart';
import '../../data/prefs_ext.dart';
import 'stream_picker.dart';

class DetailScreen extends ConsumerStatefulWidget {
  const DetailScreen({
    super.key,
    required this.type,
    required this.id,
    this.preview,
  });
  final String type;
  final String id;
  final MetaItem? preview;

  @override
  ConsumerState<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends ConsumerState<DetailScreen> {
  int? _season;
  bool _expanded = false;

  Future<void> _downloadSeason(MetaItem meta, int season) async {
    final services = ref.read(servicesProvider);
    final settings = ref.read(settingsProvider);
    if (await services.activeDebrid(settings) != null) {
      if (!mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: const Text('Scaricare tutta la stagione?'),
          content: const Text(
            'Per i torrent verrà usato il tuo servizio debrid, che può avviare download sul tuo account e contare sui tuoi limiti. Aether non cancella mai nulla dal tuo account.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Annulla'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Scarica'),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    unawaited(services.seasonJobs.start(services, settings, meta, season));
  }

  @override
  Widget build(BuildContext context) {
    final key = MetaKey(widget.type, widget.id);
    final async = ref.watch(metaProvider(key));
    final base =
        widget.preview ??
        MetaItem(id: widget.id, type: widget.type, name: widget.id);
    final meta = base.mergedWith(async.value);
    final library = ref.watch(servicesProvider).library;
    ref.watch(libraryVersionProvider);
    final settings = ref.watch(settingsProvider);
    final tint = ref
        .watch(moodColorProvider(meta.background ?? meta.poster))
        .value;
    final rich = ref.watch(tmdbDetailsProvider(meta.id)).value;
    // The logo is fetched and decoded as soon as the title opens, so choosing a source and the player find it ready.
    ref.listen(
      logoProvider((metaId: meta.id, isMovie: meta.type != 'series')),
      (_, next) {
        final url = next.value;
        if (url != null) precacheImage(NetworkImage(url), context);
      },
    );
    final logo = ref
        .watch(logoProvider((metaId: meta.id, isMovie: meta.type != 'series')))
        .value;
    final ratings = ref.watch(ratingsProvider(meta.id)).value ?? const [];
    final tvdb = meta.isSeries
        ? (ref.watch(tvdbEpisodesProvider(meta.id)).value ?? const {})
        : const <String, TvdbEpisode>{};
    final seasons = meta.seasons.where((s) => s != 0).toList()
      ..addAll(meta.seasons.contains(0) ? [0] : const []);
    final selectedSeason =
        _season ??
        (seasons.isEmpty ? null : _pickSeason(meta, library, seasons));
    final next = _nextVideo(meta, library);
    final reduce = settings.reduceEffects;

    return Scaffold(
      body: AetherBackdrop(
        tint: tint,
        child: Stack(
          children: [
            CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: _Hero(meta: meta, tint: tint),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AetherTokens.pageMargin,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (logo == null)
                          Text(
                            meta.name,
                            style: Theme.of(context).textTheme.displaySmall,
                          ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 6,
                          children: [
                            if (meta.releaseInfo != null)
                              Pill(meta.releaseInfo!),
                            if (meta.runtime != null) Pill(meta.runtime!),
                            if (meta.imdbRating != null)
                              Pill(
                                '★ ${meta.imdbRating}',
                                color: AetherTokens.warning,
                              ),
                            for (final g in meta.genres.take(4)) Pill(g),
                          ],
                        ),
                        const SizedBox(height: 18),
                        Row(
                          children: [
                            Expanded(
                              child: GlassButton(
                                icon: Icons.play_arrow_rounded,
                                label: meta.isSeries
                                    ? (next == null
                                          ? 'Guarda'
                                          : 'Guarda ${next.label}')
                                    : (library.progressOf(meta.id)?.resumable ??
                                              false
                                          ? 'Riprendi'
                                          : 'Guarda'),
                                prominent: true,
                                size: 52,
                                onPressed: () => showStreamPicker(
                                  context,
                                  meta: meta,
                                  video: meta.isSeries ? next : null,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            GlassButton(
                              icon: library.isInWatchlist(meta.id)
                                  ? Icons.bookmark_added_rounded
                                  : Icons.bookmark_add_outlined,
                              tooltip: library.isInWatchlist(meta.id)
                                  ? 'Rimuovi dalla watchlist'
                                  : 'Aggiungi alla watchlist',
                              size: 52,
                              onPressed: () async {
                                await library.toggleWatchlist(meta);
                                ref
                                    .read(libraryVersionProvider.notifier)
                                    .bump();
                              },
                            ),
                            const SizedBox(width: 10),
                            GlassButton(
                              icon: library.isFavorite(meta.id)
                                  ? Icons.favorite_rounded
                                  : Icons.favorite_border_rounded,
                              tooltip: library.isFavorite(meta.id)
                                  ? 'Rimuovi dai preferiti'
                                  : 'Aggiungi ai preferiti',
                              size: 52,
                              onPressed: () async {
                                await library.toggleFavorite(meta);
                                ref
                                    .read(libraryVersionProvider.notifier)
                                    .bump();
                              },
                            ),
                          ],
                        ),
                        if (settings.modTrailers &&
                            (meta.trailerYoutubeIds.isNotEmpty ||
                                (rich?.trailers.isNotEmpty ?? false)))
                          Padding(
                            padding: const EdgeInsets.only(top: 10),
                            child: GlassButton(
                              icon: Icons.movie_creation_outlined,
                              label: 'Trailer',
                              onPressed: () => launchUrl(
                                Uri.parse(
                                  'https://www.youtube.com/watch?v=${meta.trailerYoutubeIds.firstOrNull ?? rich!.trailers.first}',
                                ),
                                mode: LaunchMode.externalApplication,
                              ),
                            ),
                          ),
                        if (settings.modFacts &&
                            (rich?.tagline ?? '').isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 16),
                            child: Text(
                              '“${rich!.tagline}”',
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(
                                    fontStyle: FontStyle.italic,
                                    color: AetherTokens.textSecondary,
                                  ),
                            ),
                          ),
                        if ((meta.description ?? rich?.overview) != null) ...[
                          const SizedBox(height: 14),
                          GestureDetector(
                            onTap: () => setState(() => _expanded = !_expanded),
                            child: AnimatedSize(
                              duration: reduce
                                  ? Duration.zero
                                  : AetherTokens.medium,
                              alignment: Alignment.topCenter,
                              child: Text(
                                meta.description ?? rich!.overview!,
                                maxLines: _expanded ? null : 4,
                                overflow: _expanded
                                    ? null
                                    : TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodyLarge,
                              ),
                            ),
                          ),
                        ],
                        if (async.isLoading)
                          const Padding(
                            padding: EdgeInsets.only(top: 12),
                            child: LinearProgressIndicator(minHeight: 2),
                          ),
                        if (async.hasError ||
                            (async.hasValue &&
                                async.value == null &&
                                widget.preview == null))
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Text(
                              'Nessun addon ha i dettagli completi di questo titolo.',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                if (meta.isSeries && selectedSeason != null) ...[
                  const SliverToBoxAdapter(
                    child: SectionHeader(title: 'Episodi'),
                  ),
                  SliverToBoxAdapter(
                    child: SizedBox(
                      height: 50,
                      child: ListView(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 6,
                        ),
                        scrollDirection: Axis.horizontal,
                        children: [
                          for (final s in seasons)
                            Padding(
                              padding: const EdgeInsets.only(right: 8),
                              child: GlassButton(
                                label: s == 0 ? 'Speciali' : 'Stagione $s',
                                size: 38,
                                selected: s == selectedSeason,
                                onPressed: () => setState(() => _season = s),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ListenableBuilder(
                            listenable: ref.read(servicesProvider).seasonJobs,
                            builder: (context, _) {
                              final jobs = ref
                                  .read(servicesProvider)
                                  .seasonJobs;
                              final busy = jobs.busy(meta.id, selectedSeason);
                              final msg = jobs.message(meta.id, selectedSeason);
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Wrap(
                                    spacing: 8,
                                    crossAxisAlignment:
                                        WrapCrossAlignment.center,
                                    children: [
                                      GlassButton(
                                        icon: Icons.download_rounded,
                                        label:
                                            'Scarica ${selectedSeason == 0 ? 'gli speciali' : 'la stagione $selectedSeason'}',
                                        size: 38,
                                        onPressed: busy
                                            ? null
                                            : () => _downloadSeason(
                                                meta,
                                                selectedSeason,
                                              ),
                                      ),
                                      if (busy)
                                        GlassButton(
                                          icon: Icons.close_rounded,
                                          label: 'Annulla',
                                          size: 38,
                                          onPressed: () => jobs.cancel(
                                            meta.id,
                                            selectedSeason,
                                          ),
                                        ),
                                    ],
                                  ),
                                  if (msg != null && msg.isNotEmpty)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 6),
                                      child: Text(
                                        msg,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall,
                                      ),
                                    ),
                                ],
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                  SliverList.builder(
                    itemCount: meta.episodesOf(selectedSeason).length,
                    itemBuilder: (context, i) {
                      final v = _translated(
                        meta.episodesOf(selectedSeason)[i],
                        tvdb,
                      );
                      return _EpisodeTile(
                        meta: meta,
                        video: v,
                        library: library,
                        onChanged: () =>
                            ref.read(libraryVersionProvider.notifier).bump(),
                      );
                    },
                  ),
                ],
                SliverToBoxAdapter(
                  child: _RatingTiles(
                    ratings: [
                      for (final r in ratings)
                        if (settings.ratingSources.contains(r.source))
                          ('${r.display}', r.title),
                      if (ratings.isEmpty && meta.imdbRating != null)
                        (meta.imdbRating!, 'IMDb'),
                    ],
                  ),
                ),
                if (rich != null && rich.cast.isNotEmpty && settings.modCast)
                  SliverToBoxAdapter(child: _CastRow(cast: rich.cast))
                else if (meta.cast.isNotEmpty)
                  SliverToBoxAdapter(
                    child: _NamesBlock(
                      title: 'Cast',
                      names: meta.cast.take(12).toList(),
                    ),
                  ),
                if (meta.directors.isNotEmpty)
                  SliverToBoxAdapter(
                    child: _NamesBlock(title: 'Regia', names: meta.directors),
                  ),
                if (settings.modTrailers &&
                    rich != null &&
                    rich.videos.isNotEmpty)
                  SliverToBoxAdapter(child: _TrailerList(videos: rich.videos)),
                if (settings.modCompanies &&
                    rich != null &&
                    rich.companyCards.isNotEmpty)
                  SliverToBoxAdapter(
                    child: _CompanyRow(companies: rich.companyCards),
                  ),
                if (settings.modFinancials &&
                    rich != null &&
                    ((rich.budget ?? 0) > 0 || (rich.revenue ?? 0) > 0))
                  SliverToBoxAdapter(
                    child: _MoneyCards(
                      budget: rich.budget ?? 0,
                      revenue: rich.revenue ?? 0,
                    ),
                  ),
                if (rich != null && factRows(rich, settings).isNotEmpty)
                  SliverToBoxAdapter(
                    child: _Facts(rows: factRows(rich, settings)),
                  ),
                if (settings.modSameActors &&
                    rich != null &&
                    rich.tmdbId != null &&
                    rich.cast.any((c) => c.tmdbId != null))
                  SliverToBoxAdapter(
                    child: _SameActors(
                      keyString:
                          '${rich.tmdbId}:${rich.cast.map((c) => c.tmdbId).whereType<int>().take(3).join(',')}',
                    ),
                  ),
                if (settings.modSimilar &&
                    rich != null &&
                    rich.similarTitles.isNotEmpty)
                  SliverToBoxAdapter(
                    child: _SimilarRow(titles: rich.similarTitles),
                  ),
                if (rich != null)
                  const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.fromLTRB(20, 20, 20, 0),
                      child: Text(
                        'Questo prodotto usa le API di TMDB ma non è approvato né certificato da TMDB.',
                        style: TextStyle(
                          fontSize: 11,
                          color: AetherTokens.textTertiary,
                        ),
                      ),
                    ),
                  ),
                const SliverToBoxAdapter(child: SizedBox(height: 120)),
              ],
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: GlassButton(
                  icon: Icons.arrow_back_ios_new_rounded,
                  tooltip: 'Indietro',
                  onPressed: () => context.pop(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The episode with the title and overview TheTVDB translated, when it has them.
  static Video _translated(Video v, Map<String, TvdbEpisode> tvdb) {
    final t = (v.season == null || v.episode == null)
        ? null
        : tvdb['${v.season}:${v.episode}'];
    if (t == null || (t.name == null && t.overview == null)) return v;
    return Video(
      id: v.id,
      title: t.name ?? v.title,
      season: v.season,
      episode: v.episode,
      released: v.released,
      thumbnail: v.thumbnail ?? t.image,
      overview: t.overview ?? v.overview,
    );
  }

  /// The season to open on: the one of the last watched episode, else the first regular season.
  int _pickSeason(MetaItem meta, dynamic library, List<int> seasons) {
    final history = (library.history as List<WatchProgress>).where(
      (p) => p.metaId == meta.id && p.season != null,
    );
    if (history.isNotEmpty && seasons.contains(history.first.season))
      return history.first.season!;
    return seasons.firstWhere((s) => s != 0, orElse: () => seasons.first);
  }

  /// The episode to play: the first not finished one after the latest watched one, else the first.
  Video? _nextVideo(MetaItem meta, dynamic library) {
    final eps = meta.videos.where((v) => v.isEpisode && v.season != 0).toList()
      ..sort(
        (a, b) => a.season != b.season
            ? a.season!.compareTo(b.season!)
            : a.episode!.compareTo(b.episode!),
      );
    if (eps.isEmpty) return null;
    final lib = library as dynamic;
    final inProgress = eps.where(
      (v) => (lib.progressOf(v.id) as WatchProgress?)?.resumable ?? false,
    );
    if (inProgress.isNotEmpty) return inProgress.last;
    final lastWatched = eps.lastIndexWhere((v) => lib.isWatched(v.id) as bool);
    final index = lastWatched + 1;
    return eps[index >= eps.length ? eps.length - 1 : index];
  }
}

/// «Cambia locandina»: the posters TMDB has for the title; the choice is remembered and shown everywhere the poster appears.
Future<void> _pickPoster(BuildContext context, WidgetRef ref, MetaItem meta) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: AetherTokens.inkRaised,
    isScrollControlled: true,
    builder: (ctx) => Consumer(
      builder: (ctx, ref, _) {
        final async = ref.watch(alternatePostersProvider(meta.id));
        final original = meta.poster ?? '';
        void choose(String? url) {
          final map = {...ref.read(settingsProvider).posterOverrides};
          if (url == null) {
            map.remove(original);
          } else {
            map[original] = url;
          }
          ref
              .read(settingsProvider.notifier)
              .update(
                (x) => x.withExt('posterOverrides', map.isEmpty ? null : map),
              );
          PosterImage.overrides = map;
          Navigator.of(ctx).pop();
        }

        return SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(ctx).height * 0.6,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Cambia locandina',
                          style: Theme.of(ctx).textTheme.titleLarge,
                        ),
                      ),
                      TextButton(
                        onPressed: () => choose(null),
                        child: const Text('Originale'),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: async.when(
                    loading: () =>
                        const Center(child: CircularProgressIndicator()),
                    error: (_, __) =>
                        const Center(child: Text('Non disponibili')),
                    data: (list) => list.isEmpty
                        ? const Center(
                            child: Text('Nessuna locandina alternativa'),
                          )
                        : GridView.builder(
                            padding: const EdgeInsets.all(16),
                            gridDelegate:
                                const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 3,
                                  mainAxisSpacing: 10,
                                  crossAxisSpacing: 10,
                                  childAspectRatio: 2 / 3,
                                ),
                            itemCount: list.length,
                            itemBuilder: (_, i) => GestureDetector(
                              onTap: () => choose(list[i]),
                              child: PosterImage(
                                url: list[i],
                                title: meta.name,
                                radius: 10,
                                cacheWidth: 300,
                              ),
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

class _Hero extends ConsumerWidget {
  const _Hero({required this.meta, required this.tint});
  final MetaItem meta;
  final Color? tint;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final look = AetherLook.of(context);
    final logo = ref
        .watch(logoProvider((metaId: meta.id, isMovie: meta.type != 'series')))
        .value;
    final height = (MediaQuery.sizeOf(context).height * 0.5).clamp(
      300.0,
      480.0,
    );
    final backdrop = AetherTokens.ink;
    return SizedBox(
      height: height,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ShaderMask(
            // Cinematic: the artwork itself dissolves into the page (a mask), so the film's colour flows into the background.
            shaderCallback: (rect) => LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.white,
                Colors.white,
                look.cinematic
                    ? Colors.transparent
                    : backdrop.withValues(alpha: 0.2),
              ],
              stops: const [0, 0.55, 1],
            ).createShader(rect),
            blendMode: BlendMode.dstIn,
            child: KenBurns(
              enabled: ref.watch(
                settingsProvider.select(
                  (s) => s.animatedBackdrop && !look.reduceEffects,
                ),
              ),
              child: PosterImage(
                url: meta.poster ?? meta.background,
                title: meta.name,
                radius: 0,
                alignment: Alignment.topCenter,
                cacheWidth: 1600,
              ),
            ),
          ),
          if (ref.watch(settingsProvider.select((s) => s.alternatePosters)) &&
              meta.id.startsWith('tt'))
            Positioned(
              right: AetherTokens.pageMargin,
              top: 56,
              child: SafeArea(
                child: GlassButton(
                  icon: Icons.photo_library_rounded,
                  tooltip: 'Cambia locandina',
                  onPressed: () => _pickPoster(context, ref, meta),
                ),
              ),
            ),
          // The title's own logo (fanart.tv) sits at the foot of the artwork, in place of the plain title.
          if (logo != null)
            Positioned(
              left: AetherTokens.pageMargin,
              bottom: 10,
              child: LogoImage(
                url: logo,
                maxWidth: 270,
                maxHeight: 120,
                alignment: Alignment.bottomLeft,
              ),
            ),
        ],
      ),
    );
  }
}

class _EpisodeTile extends StatelessWidget {
  const _EpisodeTile({
    required this.meta,
    required this.video,
    required this.library,
    required this.onChanged,
  });
  final MetaItem meta;
  final Video video;
  final dynamic library;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final lib = library as dynamic;
    final progress = lib.progressOf(video.id) as WatchProgress?;
    final watched = lib.isWatched(video.id) as bool;
    final future =
        video.released != null && video.released!.isAfter(DateTime.now());
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: Opacity(
        opacity: future ? 0.5 : 1,
        child: GestureDetector(
          onTap: future
              ? null
              : () => showStreamPicker(context, meta: meta, video: video),
          child: GlassSurface(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                SizedBox(
                  width: 112,
                  height: 63,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      PosterImage(
                        url: video.thumbnail ?? meta.background,
                        title: video.title,
                        radius: 10,
                      ),
                      if (progress != null && !watched)
                        Positioned(
                          left: 6,
                          right: 6,
                          bottom: 5,
                          child: LinearProgressIndicator(
                            value: progress.fraction,
                            minHeight: 3,
                            backgroundColor: Colors.white24,
                          ),
                        ),
                      if (watched)
                        const Positioned(
                          top: 4,
                          right: 4,
                          child: Icon(
                            Icons.check_circle_rounded,
                            size: 18,
                            color: AetherTokens.success,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${video.episode ?? ''}. ${video.title}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                      if (future)
                        Text(
                          'Esce il ${video.released!.day}/${video.released!.month}/${video.released!.year}',
                          style: const TextStyle(
                            fontSize: 11,
                            color: AetherTokens.warning,
                          ),
                        )
                      else if (video.overview != null)
                        Text(
                          video.overview!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      if (RegExp(r'^tt\d+').hasMatch(meta.id) &&
                          video.season != null)
                        GestureDetector(
                          onTap: () => launchUrl(
                            Uri.parse(
                              'https://www.imdb.com/title/${meta.id.split(':').first}/episodes/?season=${video.season}',
                            ),
                            mode: LaunchMode.externalApplication,
                          ),
                          child: const Padding(
                            padding: EdgeInsets.only(top: 3),
                            child: Text(
                              'Apri la puntata su IMDb ↗',
                              style: TextStyle(
                                fontSize: 11,
                                color: AetherTokens.textTertiary,
                                decoration: TextDecoration.underline,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: watched
                      ? 'Segna come non visto'
                      : 'Segna come visto',
                  icon: Icon(
                    watched
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    size: 20,
                  ),
                  onPressed: () async {
                    await lib.markWatched(
                      meta.id,
                      video.id,
                      type: meta.type,
                      name: meta.name,
                      poster: meta.poster,
                      season: video.season,
                      episode: video.episode,
                      watched: !watched,
                    );
                    onChanged();
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CastRow extends StatelessWidget {
  const _CastRow({required this.cast});
  final List cast;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(
          title: 'Cast',
          subtitle: 'Tocca un attore per vedere la sua filmografia',
        ),
        SizedBox(
          height: 128,
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(
              horizontal: AetherTokens.pageMargin,
            ),
            scrollDirection: Axis.horizontal,
            itemCount: cast.length,
            separatorBuilder: (_, __) => const SizedBox(width: 14),
            itemBuilder: (context, i) {
              final c = cast[i];
              return GestureDetector(
                onTap: c.tmdbId == null
                    ? null
                    : () => context.push(
                        '/person/${c.tmdbId}?name=${Uri.encodeQueryComponent(c.name)}',
                      ),
                child: SizedBox(
                  width: 84,
                  child: Column(
                    children: [
                      ClipOval(
                        child: SizedBox(
                          width: 72,
                          height: 72,
                          child: PosterImage(
                            url: c.photo,
                            title: c.name,
                            radius: 40,
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        c.name,
                        maxLines: 2,
                        textAlign: TextAlign.center,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (c.role != null)
                        Text(
                          c.role!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _NamesBlock extends StatelessWidget {
  const _NamesBlock({required this.title, required this.names});
  final String title;
  final List<String> names;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          names.join(', '),
          style: Theme.of(context).textTheme.bodyMedium
              ?.copyWith(color: AetherTokens.textSecondary),
        ),
      ],
    ),
  );
}

/// The TMDB facts shown on the title page, as label/value rows; each group follows its switch in Settings ▸ Cataloghi e metadati.
List<(String, String)> factRows(RichDetails r, AppSettings s) {
  String lang(String code) =>
      const {
        'it': 'Italiano',
        'en': 'Inglese',
        'fr': 'Francese',
        'es': 'Spagnolo',
        'de': 'Tedesco',
        'ja': 'Giapponese',
        'ko': 'Coreano',
        'zh': 'Cinese',
        'pt': 'Portoghese',
        'ru': 'Russo',
      }[code] ??
      code;
  return [
    if (s.modFacts) ...[
      if (r.originalTitle != null) ('Titolo originale', r.originalTitle!),
      if (r.status != null) ('Stato', r.status!),
      if (r.releaseDate != null) ('Uscita', r.releaseDate!),
      if ((r.runtime ?? 0) > 0)
        (
          'Durata',
          '${r.runtime! ~/ 60 > 0 ? '${r.runtime! ~/ 60} h ' : ''}${r.runtime! % 60} min',
        ),
      if (r.seasons != null)
        (
          'Stagioni',
          '${r.seasons}${r.episodes == null ? '' : ' · ${r.episodes} episodi'}',
        ),
      if (r.originalLanguage != null)
        ('Lingua originale', lang(r.originalLanguage!)),
      if (r.spokenLanguages.isNotEmpty)
        ('Lingue', r.spokenLanguages.join(', ')),
      if (r.countries.isNotEmpty) ('Paesi', r.countries.join(', ')),
      if (r.voteAverage != null && r.voteAverage! > 0)
        (
          'Voto TMDB',
          '${r.voteAverage!.toStringAsFixed(1)}${r.voteCount == null ? '' : ' (${r.voteCount} voti)'}',
        ),
      if (r.homepage != null) ('Sito ufficiale', r.homepage!),
    ],
    if (s.modCertification && r.certification != null)
      ('Classificazione', r.certification!),
    if (s.modProviders && r.providers.isNotEmpty)
      ('Dove guardarlo', r.providers.join(', ')),
    if (s.modCrew && r.creators.isNotEmpty)
      ('Ideata da', r.creators.join(', ')),
    if (s.modCrew && r.crew.isNotEmpty) ('Troupe', r.crew.join('\n')),
    if (s.modCollection && r.collectionName != null)
      ('Saga', r.collectionName!),
    if (s.modCompanies && r.networks.isNotEmpty)
      ('Rete', r.networks.join(', ')),
    if (s.modKeywords && r.keywords.isNotEmpty)
      ('Parole chiave', r.keywords.join(', ')),
  ];
}

class _Facts extends StatelessWidget {
  const _Facts({required this.rows});
  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(title: 'Dettagli'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: GlassSurface(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            child: Column(
              children: [
                for (var i = 0; i < rows.length; i++) ...[
                  if (i > 0) const Divider(height: 1),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 112,
                          child: Text(
                            rows[i].$1,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                        Expanded(
                          child: Text(
                            rows[i].$2,
                            textAlign: TextAlign.right,
                            style: const TextStyle(fontSize: 14),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// «Voti»: one tile per rating source, the value large and the source under it.
class _RatingTiles extends StatelessWidget {
  const _RatingTiles({required this.ratings});
  final List<(String, String)> ratings;

  @override
  Widget build(BuildContext context) {
    if (ratings.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(title: 'Voti'),
        SizedBox(
          height: 78,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              for (final r in ratings)
                Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: GlassSurface(
                    radius: 14,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          r.$1,
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(
                          r.$2,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// «Trailer»: every trailer and teaser TMDB lists, opened on YouTube.
class _TrailerList extends StatelessWidget {
  const _TrailerList({required this.videos});
  final List<TmdbVideo> videos;

  static String _lang(String? c) =>
      const {
        'it': 'Italiano',
        'en': 'Inglese',
        'fr': 'Francese',
        'es': 'Spagnolo',
        'de': 'Tedesco',
      }[c] ??
      (c ?? '');

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(title: 'Trailer'),
        for (final v in videos.take(8))
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: GestureDetector(
              onTap: () => launchUrl(
                Uri.parse('https://www.youtube.com/watch?v=${v.key}'),
                mode: LaunchMode.externalApplication,
              ),
              child: GlassSurface(
                radius: 14,
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Container(
                      width: 38,
                      height: 30,
                      decoration: BoxDecoration(
                        color: AetherLook.of(context).accent,
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: const Icon(
                        Icons.play_arrow_rounded,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            v.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                            ),
                          ),
                          Text(
                            [
                              v.type,
                              if (_lang(v.language).isNotEmpty)
                                _lang(v.language),
                              if (v.official) 'Ufficiale',
                            ].join(' · '),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    const Icon(
                      Icons.north_east_rounded,
                      size: 18,
                      color: AetherTokens.textSecondary,
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// «Produzione»: the companies' logos on light cards, the name under each.
class _CompanyRow extends StatelessWidget {
  const _CompanyRow({required this.companies});
  final List<CompanyCard> companies;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SectionHeader(title: 'Produzione'),
        SizedBox(
          height: 118,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              for (final c in companies.take(12))
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: SizedBox(
                    width: 124,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          height: 82,
                          width: 124,
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: const Color(0xFFF4F4F6),
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: c.logo == null
                              ? Center(
                                  child: Text(
                                    c.name,
                                    textAlign: TextAlign.center,
                                    maxLines: 3,
                                    style: const TextStyle(
                                      color: Color(0xFF222226),
                                      fontWeight: FontWeight.w800,
                                      fontSize: 12,
                                    ),
                                  ),
                                )
                              : Image.network(
                                  c.logo!,
                                  fit: BoxFit.contain,
                                  errorBuilder: (_, __, ___) => Center(
                                    child: Text(
                                      c.name,
                                      textAlign: TextAlign.center,
                                      style: const TextStyle(
                                        color: Color(0xFF222226),
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                                ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          c.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// «Budget» and «Incassi» side by side.
class _MoneyCards extends StatelessWidget {
  const _MoneyCards({required this.budget, required this.revenue});
  final int budget;
  final int revenue;

  static String _fmt(int v) {
    final s = v.toString();
    final b = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) b.write('.');
      b.write(s[i]);
    }
    return '$b \$';
  }

  @override
  Widget build(BuildContext context) {
    Widget card(String label, int v) => Expanded(
      child: GlassSurface(
        radius: 14,
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 4),
            Text(
              v > 0 ? _fmt(v) : '—',
              style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800),
            ),
          ],
        ),
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
      child: Row(
        children: [
          card('Budget', budget),
          const SizedBox(width: 10),
          card('Incassi', revenue),
        ],
      ),
    );
  }
}

/// «Titoli simili»: the posters of similar and recommended titles; a tap opens that title.
class _SimilarRow extends ConsumerWidget {
  const _SimilarRow({required this.titles, this.heading = 'Titoli simili'});
  final List<SimilarTitle> titles;
  final String heading;

  Future<void> _open(
    BuildContext context,
    WidgetRef ref,
    SimilarTitle t,
  ) async {
    final imdb = await ref
        .read(servicesProvider)
        .tmdb
        .imdbIdOf(t.tmdbId, isMovie: t.isMovie);
    if (imdb == null || !context.mounted) return;
    openTitle(
      context,
      MetaItem(
        id: imdb,
        type: t.isMovie ? 'movie' : 'series',
        name: t.title,
        poster: t.poster,
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SectionHeader(title: heading),
        SizedBox(
          height: 262,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: titles.length,
            separatorBuilder: (_, __) => const SizedBox(width: 12),
            itemBuilder: (context, i) {
              final t = titles[i];
              return GestureDetector(
                onTap: () => _open(context, ref, t),
                child: SizedBox(
                  width: 128,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        height: 192,
                        child: PosterImage(
                          url: t.poster,
                          title: t.title,
                          radius: 14,
                          cacheWidth: 400,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        t.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                      ),
                      Text(
                        [
                          if (t.year != null) t.year!,
                          if ((t.rating ?? 0) > 0)
                            '★ ${t.rating!.toStringAsFixed(1)}',
                        ].join('  '),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// «Con gli stessi attori»: the poster row of [sameActorsProvider].
class _SameActors extends ConsumerWidget {
  const _SameActors({required this.keyString});
  final String keyString;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final titles = ref.watch(sameActorsProvider(keyString)).value;
    if (titles == null || titles.isEmpty) return const SizedBox.shrink();
    return _SimilarRow(titles: titles, heading: 'Con gli stessi attori');
  }
}
