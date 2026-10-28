import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../core/debrid/torbox_client.dart';
import '../../core/streams/badge_pack.dart';
import '../../core/model/meta.dart';
import '../../core/streams/stream_analyzer.dart';
import '../../data/prefs_ext.dart';
import '../../data/settings.dart';

import 'package:flutter/services.dart';

import '../../design/glass.dart';
import '../../design/tokens.dart';
import '../../design/widgets.dart';
import '../play/play_flow.dart';
import '../play/play_planner.dart';
import '../player/playback_engine.dart';
import '../player/player_session.dart';

Future<void> showStreamPicker(
  BuildContext context, {
  required MetaItem meta,
  Video? video,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    useSafeArea: true,
    builder: (_) => StreamPickerSheet(meta: meta, video: video),
  );
}

/// All sources of the addons for a film or an episode, ranked, with their facts as badges and a live "in cache" check for
/// torrents when TorBox is configured. Addons answer in parallel: the list grows as they reply.
class StreamPickerSheet extends ConsumerStatefulWidget {
  const StreamPickerSheet({super.key, required this.meta, this.video});
  final MetaItem meta;
  final Video? video;

  @override
  ConsumerState<StreamPickerSheet> createState() => _StreamPickerSheetState();
}

class _StreamPickerSheetState extends ConsumerState<StreamPickerSheet> {
  String? _addon;
  Map<String, bool> _cached = {};
  bool _debrid = false;
  String? _cacheProblem;
  final Set<String> _asked = {};
  bool _autoDone = false;

  @override
  void initState() {
    super.initState();
    final services = ref.read(servicesProvider);
    services.activeDebrid(ref.read(settingsProvider)).then((p) {
      if (mounted) setState(() => _debrid = p != null);
    });
  }

  Future<void> _checkCache(List<RankedStream> ranked) async {
    if (!_debrid) return;
    final hashes = ranked
        .map((r) => r.stream.infoHash)
        .whereType<String>()
        .where((h) => !_asked.contains(h))
        .toList();
    if (hashes.isEmpty) return;
    _asked.addAll(hashes);
    try {
      final services = ref.read(servicesProvider);
      final provider = await services.activeDebrid(ref.read(settingsProvider));
      final result = await provider?.cached(hashes);
      if (result != null && mounted) {
        setState(() => _cached = {..._cached, ...result});
      }
    } on DebridException catch (e) {
      if (mounted) setState(() => _cacheProblem = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final video = widget.video;
    final key = StreamsKey(widget.meta.type, video?.id ?? widget.meta.id);
    final async = ref.watch(streamsProvider(key));
    final settings = ref.watch(settingsProvider);
    final state = async.value ?? const StreamsState();
    final ranker = PlayPlanner.rankerFor(
      ref.read(servicesProvider),
      settings,
      debridConfigured: _debrid,
    );
    final ranked = ranker.rank(state.streams);
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkCache(ranked));
    // «Scegli automaticamente la sorgente migliore»: once the addons have answered, the first source that opens without
    // asking anything starts by itself (a torrent only when it is known to be in cache).
    if (settings.autoSelectStream &&
        !_autoDone &&
        !state.loading &&
        ranked.isNotEmpty) {
      bool sure(RankedStream r) =>
          r.playability == StreamPlayability.direct ||
          (r.playability == StreamPlayability.needsDebrid &&
              _cached[r.stream.infoHash] == true);
      final best = ranked.where(sure).firstOrNull;
      if (best != null) {
        _autoDone = true;
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          if (!mounted) return;
          final ctx = Navigator.of(context).context;
          await playStream(
            ctx,
            ref,
            meta: widget.meta,
            video: video,
            chosen: best,
            all: ranked,
            state: state,
          );
        });
      }
    }
    final addonNames = {for (final r in ranked) r.stream.addonName ?? 'Addon'}
        .toList();
    final shown = ranked
        .where((r) => _addon == null || r.stream.addonName == _addon)
        .toList();
    final offline = video == null
        ? PlayPlanner(
            ref.read(servicesProvider),
            settings,
          ).offlineSource(widget.meta.id)
        : PlayPlanner(
            ref.read(servicesProvider),
            settings,
          ).offlineSource(video.id);

    return DraggableScrollableSheet(
      initialChildSize: 0.86,
      minChildSize: 0.5,
      maxChildSize: 0.96,
      expand: false,
      builder: (context, scroll) => GlassSurface(
        strong: true,
        radius: 28,
        blur: AetherTokens.blurHigh,
        tint: AetherTokens.inkRaised,
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white30,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Scegli la sorgente',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        Text(
                          video == null
                              ? widget.meta.name
                              : '${widget.meta.name} · ${video.label}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  if (state.loading)
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                ],
              ),
            ),
            if (addonNames.length > 1)
              SizedBox(
                height: 46,
                child: ListView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 4,
                  ),
                  scrollDirection: Axis.horizontal,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: GlassButton(
                        label: 'Tutti',
                        size: 34,
                        selected: _addon == null,
                        onPressed: () => setState(() => _addon = null),
                      ),
                    ),
                    for (final n in addonNames)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: GlassButton(
                          label: n,
                          size: 34,
                          selected: _addon == n,
                          onPressed: () => setState(() => _addon = n),
                        ),
                      ),
                  ],
                ),
              ),
            Expanded(
              child: ListView(
                controller: scroll,
                padding: const EdgeInsets.fromLTRB(14, 6, 14, 24),
                children: [
                  if (offline != null)
                    _OfflineRow(
                      onTap: () {
                        final router = GoRouter.of(context);
                        Navigator.pop(context);
                        _playOffline(router, offline);
                      },
                    ),
                  if (_cacheProblem != null)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        'Controllo della cache TorBox non riuscito: $_cacheProblem',
                        style: Theme.of(context).textTheme.bodySmall
                            ?.copyWith(color: AetherTokens.warning),
                      ),
                    ),
                  for (final r in shown)
                    _StreamRow(
                      ranked: r,
                      cached: r.stream.infoHash == null
                          ? null
                          : _cached[r.stream.infoHash],
                      debridConfigured: _debrid,
                      settings: settings,
                      onPlay: () async {
                        final ctx = Navigator.of(context).context;
                        await playStream(
                          ctx,
                          ref,
                          meta: widget.meta,
                          video: video,
                          chosen: r,
                          all: ranked,
                          state: state,
                        );
                      },
                      onCopy: () => _copy(r),
                      customBadges: CustomBadgePack.badgesFor(
                        r.stream,
                        settings.customBadges,
                      ),
                      onTap: () async {
                        final navigator = Navigator.of(context);
                        final ctx = navigator.context;
                        await playStream(
                          ctx,
                          ref,
                          meta: widget.meta,
                          video: video,
                          chosen: r,
                          all: ranked,
                          state: state,
                        );
                      },
                      onDownload:
                          (r.playability == StreamPlayability.direct ||
                              (r.playability == StreamPlayability.needsDebrid &&
                                  _debrid))
                          ? () => _download(r, ranked, state)
                          : null,
                    ),
                  if (shown.isEmpty && !state.loading)
                    EmptyState(
                      icon: Icons.sensors_off_rounded,
                      title: 'Nessuna sorgente',
                      message: state.errors.isEmpty
                          ? 'Gli addon non hanno restituito sorgenti per questo titolo.'
                          : 'Alcuni addon non hanno risposto: ${state.errors.keys.join(', ')}.',
                    ),
                  if (state.errors.isNotEmpty && shown.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(
                        'Non hanno risposto: ${state.errors.keys.join(', ')}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  if (state.loading && state.pending.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Text(
                        'In attesa di: ${state.pending.join(', ')}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _playOffline(GoRouter router, PlaybackSource source) {
    final meta = widget.meta;
    final video = widget.video;
    router.push(
      '/player',
      extra: PlayerArgs(
        title: meta.name,
        metaId: meta.id,
        videoId: video?.id ?? meta.id,
        type: meta.type,
        poster: meta.poster,
        season: video?.season,
        episode: video?.episode,
        episodeTitle: video?.title,
        source: source,
      ),
    );
  }

  Future<void> _copy(RankedStream r) async {
    final text = r.stream.url ?? r.stream.magnet;
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) showProblem(context, 'Copiato negli appunti.');
  }

  /// Direct links are queued as they are; a torrent is first resolved through the debrid service (with the usual confirmation).
  Future<void> _download(
    RankedStream r,
    List<RankedStream> ranked,
    StreamsState state,
  ) async {
    final dl = ref.read(servicesProvider).downloads;
    Future<void> queue(String url) async {
      try {
        await dl.enqueue(
          metaId: widget.meta.id,
          videoId: widget.video?.id ?? widget.meta.id,
          type: widget.meta.type,
          title: widget.video == null
              ? widget.meta.name
              : '${widget.meta.name} · ${widget.video!.label}',
          url: url,
          poster: widget.meta.poster,
          season: widget.video?.season,
          episode: widget.video?.episode,
          fileName: r.stream.filename,
        );
        if (mounted) {
          showProblem(
            context,
            'Download avviato: lo trovi in Altro ▸ Download.',
          );
        }
      } on FormatException catch (e) {
        if (mounted) showProblem(context, e.message);
      }
    }

    if (r.playability == StreamPlayability.direct) {
      await queue(r.stream.url!);
      return;
    }
    await playStream(
      context,
      ref,
      meta: widget.meta,
      video: widget.video,
      chosen: r,
      all: ranked,
      state: state,
      onResolved: (source) => queue(source.uri),
    );
  }
}

class _OfflineRow extends StatelessWidget {
  const _OfflineRow({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: GestureDetector(
      onTap: onTap,
      child: GlassSurface(
        tint: AetherTokens.success,
        padding: const EdgeInsets.all(14),
        child: const Row(
          children: [
            Icon(Icons.download_done_rounded, color: AetherTokens.success),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                'Guarda dal file scaricato (senza rete)',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _StreamRow extends StatelessWidget {
  const _StreamRow({
    required this.ranked,
    required this.cached,
    required this.debridConfigured,
    required this.onTap,
    this.onDownload,
    this.customBadges = const [],
    required this.settings,
    this.onPlay,
    this.onCopy,
  });
  final AppSettings settings;
  final VoidCallback? onPlay;
  final VoidCallback? onCopy;
  final List<CustomBadgeRule> customBadges;
  final RankedStream ranked;
  final bool? cached;
  final bool debridConfigured;
  final VoidCallback onTap;
  final VoidCallback? onDownload;

  List<PopupMenuEntry<String>> _items(BuildContext _) => [
    if (onPlay != null)
      const PopupMenuItem(
        value: 'play',
        child: ListTile(
          leading: Icon(Icons.play_arrow_rounded),
          title: Text('Riproduci'),
        ),
      ),
    if (onDownload != null)
      const PopupMenuItem(
        value: 'download',
        child: ListTile(
          leading: Icon(Icons.download_rounded),
          title: Text('Scarica per guardarlo offline'),
        ),
      ),
    if (onCopy != null)
      PopupMenuItem(
        value: 'copy',
        child: ListTile(
          leading: const Icon(Icons.copy_rounded),
          title: Text(
            ranked.stream.url != null ? 'Copia il link' : 'Copia il magnet',
          ),
        ),
      ),
  ];

  void _run(String v) => switch (v) {
    'play' => onPlay?.call(),
    'download' => onDownload?.call(),
    'copy' => onCopy?.call(),
    _ => null,
  };

  /// Long press: the same actions as the ⋮ button, next to the finger.
  Future<void> _menu(BuildContext context, Offset at) async {
    final v = await showMenu<String>(
      context: context,
      color: AetherTokens.inkRaised,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx, at.dy),
      items: _items(context),
    );
    if (v != null) _run(v);
  }

  @override
  Widget build(BuildContext context) {
    final info = ranked.info;
    final s = ranked.stream;
    final title = (s.name ?? 'Sorgente').replaceAll('\n', ' · ');
    final detail =
        s.description
            ?.split('\n')
            .firstWhere((l) => l.trim().isNotEmpty, orElse: () => '') ??
        '';
    final st = settings.badgeStyle;
    final hide = settings.hiddenBadges.toSet();
    final badges = <Widget>[
      if (info.quality != VideoQuality.unknown && !hide.contains('quality'))
        Pill(style: st, info.quality.text, color: const Color(0xFF7FB2FF)),
      if (!hide.contains('hdr'))
        for (final h in info.hdr)
          Pill(style: st, '${h.label} (dal nome)', color: AetherTokens.warning),
      if (info.codec != null && !hide.contains('codec'))
        Pill(style: st, info.codec!),
      if (info.audio != null && !hide.contains('audio'))
        Pill(style: st, info.audio!, color: const Color(0xFFC59BFF)),
      if (!hide.contains('language'))
        for (final l in info.languages)
          Pill(style: st, l, color: AetherTokens.success),
      if (info.sizeLabel != null && !hide.contains('size'))
        Pill(style: st, info.sizeLabel!),
      if (info.format != null && !hide.contains('format'))
        Pill(style: st, info.format!),
      if (info.release != null) Pill(style: st, info.release!),
      for (final b in customBadges) ImportedBadge(rule: b),
      if (ranked.playability == StreamPlayability.needsDebrid)
        Pill(
          style: st,
          cached == null
              ? (debridConfigured
                    ? 'TorBox · verifico…'
                    : 'Torrent · serve TorBox')
              : (cached! ? 'TorBox · in cache' : 'TorBox · non in cache'),
          color: cached == true
              ? AetherTokens.success
              : (cached == false ? AetherTokens.warning : Colors.white),
        ),
      if (ranked.playability == StreamPlayability.external)
        Pill(style: st, 'Si apre fuori da Aether', color: AetherTokens.warning),
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Semantics(
        button: true,
        label: title,
        child: GestureDetector(
          onTap: onTap,
          onLongPressStart: (d) => _menu(context, d.globalPosition),
          child: GlassSurface(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 14,
                              ),
                            ),
                          ),
                          if (s.addonName != null && settings.showAddonLogo)
                            Padding(
                              padding: const EdgeInsets.only(left: 8),
                              child: Text(
                                s.addonName!,
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                        ],
                      ),
                      if (detail.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: Text(
                            detail,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      if (badges.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: badges,
                          ),
                        ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  tooltip: 'Altre azioni',
                  icon: const Icon(Icons.more_vert_rounded),
                  color: AetherTokens.inkRaised,
                  onSelected: _run,
                  itemBuilder: _items,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
