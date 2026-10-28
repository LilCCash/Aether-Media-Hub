import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/mood.dart';
import '../../app/providers.dart';
import '../../core/metadata/tvdb_client.dart';
import '../../core/model/meta.dart';
import '../../design/glass.dart';
import '../../design/tokens.dart';
import '../../design/widgets.dart';
import '../../data/library_repository.dart';
import '../../data/prefs_ext.dart';
import '../downloads/season_downloader.dart';
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
  bool _seasonBusy = false;
  bool _seasonCancel = false;
  String? _seasonMessage;

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
    setState(() {
      _seasonBusy = true;
      _seasonCancel = false;
      _seasonMessage = 'Cerco le sorgenti…';
    });
    final summary = await SeasonDownloader(services, settings).run(
      meta,
      season,
      onMessage: (m) {
        if (mounted) setState(() => _seasonMessage = m);
      },
      cancelled: () => _seasonCancel || !mounted,
    );
    if (mounted) {
      setState(() {
        _seasonBusy = false;
        _seasonMessage = summary.message;
      });
    }
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
                        if (ratings.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 6,
                            children: [
                              for (final r in ratings)
                                if (settings.ratingSources.contains(r.source))
                                  Pill('${r.title} ${r.display}'),
                            ],
                          ),
                        ],
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
                          Wrap(
                            spacing: 8,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              GlassButton(
                                icon: Icons.download_rounded,
                                label:
                                    'Scarica ${selectedSeason == 0 ? 'gli speciali' : 'la stagione $selectedSeason'}',
                                size: 38,
                                onPressed: _seasonBusy
                                    ? null
                                    : () =>
                                          _downloadSeason(meta, selectedSeason),
                              ),
                              if (_seasonBusy)
                                GlassButton(
                                  icon: Icons.close_rounded,
                                  label: 'Annulla',
                                  size: 38,
                                  onPressed: () =>
                                      setState(() => _seasonCancel = true),
                                ),
                            ],
                          ),
                          if (_seasonMessage != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Text(
                                _seasonMessage!,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
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
                if (rich != null &&
                    ((settings.modCompanies && rich.companies.isNotEmpty) ||
                        (settings.modFinancials && rich.budget != null) ||
                        (settings.modCollection &&
                            rich.collectionName != null)))
                  SliverToBoxAdapter(
                    child: _Facts(
                      rich: rich,
                      companies: settings.modCompanies,
                      financials: settings.modFinancials,
                      collection: settings.modCollection,
                    ),
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
                const SliverToBoxAdapter(child: SizedBox(height: 60)),
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

class _Hero extends StatelessWidget {
  const _Hero({required this.meta, required this.tint});
  final MetaItem meta;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final look = AetherLook.of(context);
    final height = (MediaQuery.sizeOf(context).height * 0.5).clamp(
      300.0,
      480.0,
    );
    final backdrop = AetherTokens.ink;
    return SizedBox(
      height: height,
      child: ShaderMask(
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
        child: PosterImage(
          url: meta.background ?? meta.poster,
          title: meta.name,
          radius: 0,
        ),
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

class _Facts extends StatelessWidget {
  const _Facts({
    required this.rich,
    this.companies = true,
    this.financials = true,
    this.collection = true,
  });
  final dynamic rich;
  final bool companies;
  final bool financials;
  final bool collection;

  @override
  Widget build(BuildContext context) {
    String money(int v) =>
        '\$${(v / 1000000).toStringAsFixed(v >= 100000000 ? 0 : 1)} M';
    final rows = <(String, String)>[
      if (collection && rich.collectionName != null)
        ('Saga', rich.collectionName as String),
      if (companies && (rich.companies as List).isNotEmpty)
        ('Produzione', (rich.companies as List).take(4).join(', ')),
      if (financials && rich.budget != null && (rich.budget as int) > 0)
        ('Budget', money(rich.budget as int)),
      if (financials && rich.revenue != null && (rich.revenue as int) > 0)
        ('Incassi', money(rich.revenue as int)),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
      child: GlassSurface(
        padding: const EdgeInsets.all(14),
        child: Column(
          children: [
            for (final r in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 90,
                      child: Text(
                        r.$1,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    Expanded(
                      child: Text(r.$2, style: const TextStyle(fontSize: 13)),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
