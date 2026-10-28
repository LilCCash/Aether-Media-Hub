import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/providers.dart';
import '../../core/debrid/torbox_client.dart';
import '../../core/model/meta.dart';
import '../../core/streams/stream_analyzer.dart';
import '../../data/stores.dart';
import '../../design/glass.dart';
import '../../design/tokens.dart';
import '../../design/widgets.dart';
import '../play/play_flow.dart';
import '../play/play_planner.dart';
import '../player/playback_engine.dart';
import '../player/player_session.dart';

Future<void> showStreamPicker(BuildContext context, {required MetaItem meta, Video? video}) {
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

  @override
  void initState() {
    super.initState();
    ref.read(servicesProvider).secrets.serviceKey(ServiceKey.torbox).then((k) {
      if (mounted) setState(() => _debrid = (k ?? '').isNotEmpty);
    });
  }

  Future<void> _checkCache(List<RankedStream> ranked) async {
    if (!_debrid) return;
    final hashes = ranked.map((r) => r.stream.infoHash).whereType<String>().where((h) => !_asked.contains(h)).toList();
    if (hashes.isEmpty) return;
    _asked.addAll(hashes);
    try {
      final result = await ref.read(servicesProvider).torbox.checkCached(hashes);
      if (mounted) setState(() => _cached = {..._cached, ...result});
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
    final ranker = StreamRanker(preferredLanguage: settings.preferredStreamLanguage, debridConfigured: _debrid);
    final ranked = ranker.rank(state.streams);
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkCache(ranked));
    final addonNames = {for (final r in ranked) r.stream.addonName ?? 'Addon'}.toList();
    final shown = ranked.where((r) => _addon == null || r.stream.addonName == _addon).toList();
    final offline = video == null ? PlayPlanner(ref.read(servicesProvider), settings).offlineSource(widget.meta.id) : PlayPlanner(ref.read(servicesProvider), settings).offlineSource(video.id);

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
        child: Column(children: [
          const SizedBox(height: 10),
          Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.white30, borderRadius: BorderRadius.circular(2))),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
            child: Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Scegli la sorgente', style: Theme.of(context).textTheme.titleLarge),
                Text(video == null ? widget.meta.name : '${widget.meta.name} · ${video.label}', maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
              ])),
              if (state.loading) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
            ]),
          ),
          if (addonNames.length > 1)
            SizedBox(height: 46, child: ListView(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4), scrollDirection: Axis.horizontal, children: [
              Padding(padding: const EdgeInsets.only(right: 8), child: GlassButton(label: 'Tutti', size: 34, selected: _addon == null, onPressed: () => setState(() => _addon = null))),
              for (final n in addonNames) Padding(padding: const EdgeInsets.only(right: 8), child: GlassButton(label: n, size: 34, selected: _addon == n, onPressed: () => setState(() => _addon = n))),
            ])),
          Expanded(
            child: ListView(controller: scroll, padding: const EdgeInsets.fromLTRB(14, 6, 14, 24), children: [
              if (offline != null)
                _OfflineRow(onTap: () {
                  final router = GoRouter.of(context);
                  Navigator.pop(context);
                  _playOffline(router, offline);
                }),
              if (_cacheProblem != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text('Controllo della cache TorBox non riuscito: $_cacheProblem', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AetherTokens.warning))),
              for (final r in shown)
                _StreamRow(
                  ranked: r,
                  cached: r.stream.infoHash == null ? null : _cached[r.stream.infoHash],
                  debridConfigured: _debrid,
                  onTap: () async {
                    final navigator = Navigator.of(context);
                    final ctx = navigator.context;
                    await playStream(ctx, ref, meta: widget.meta, video: video, chosen: r, all: ranked, state: state);
                  },
                  onDownload: r.playability == StreamPlayability.direct ? () => _download(r) : null,
                ),
              if (shown.isEmpty && !state.loading)
                EmptyState(icon: Icons.sensors_off_rounded, title: 'Nessuna sorgente', message: state.errors.isEmpty ? 'Gli addon non hanno restituito sorgenti per questo titolo.' : 'Alcuni addon non hanno risposto: ${state.errors.keys.join(', ')}.'),
              if (state.errors.isNotEmpty && shown.isNotEmpty)
                Padding(padding: const EdgeInsets.only(top: 10), child: Text('Non hanno risposto: ${state.errors.keys.join(', ')}', style: Theme.of(context).textTheme.bodySmall)),
              if (state.loading && state.pending.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 10), child: Text('In attesa di: ${state.pending.join(', ')}', style: Theme.of(context).textTheme.bodySmall)),
            ]),
          ),
        ]),
      ),
    );
  }

  void _playOffline(GoRouter router, PlaybackSource source) {
    final meta = widget.meta;
    final video = widget.video;
    router.push('/player', extra: PlayerArgs(
      title: meta.name, metaId: meta.id, videoId: video?.id ?? meta.id, type: meta.type, poster: meta.poster,
      season: video?.season, episode: video?.episode, episodeTitle: video?.title, source: source,
    ));
  }

  Future<void> _download(RankedStream r) async {
    final dl = ref.read(servicesProvider).downloads;
    try {
      await dl.enqueue(
        metaId: widget.meta.id,
        videoId: widget.video?.id ?? widget.meta.id,
        type: widget.meta.type,
        title: widget.video == null ? widget.meta.name : '${widget.meta.name} · ${widget.video!.label}',
        url: r.stream.url!,
        poster: widget.meta.poster,
        season: widget.video?.season,
        episode: widget.video?.episode,
        fileName: r.stream.filename,
      );
      if (mounted) showProblem(context, 'Download avviato: lo trovi in Altro ▸ Download.');
    } on FormatException catch (e) {
      if (mounted) showProblem(context, e.message);
    }
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
            child: const Row(children: [Icon(Icons.download_done_rounded, color: AetherTokens.success), SizedBox(width: 12), Expanded(child: Text('Guarda dal file scaricato (senza rete)', style: TextStyle(fontWeight: FontWeight.w700)))]),
          ),
        ),
      );
}

class _StreamRow extends StatelessWidget {
  const _StreamRow({required this.ranked, required this.cached, required this.debridConfigured, required this.onTap, this.onDownload});
  final RankedStream ranked;
  final bool? cached;
  final bool debridConfigured;
  final VoidCallback onTap;
  final VoidCallback? onDownload;

  @override
  Widget build(BuildContext context) {
    final info = ranked.info;
    final s = ranked.stream;
    final title = (s.name ?? 'Sorgente').replaceAll('\n', ' · ');
    final detail = s.description?.split('\n').firstWhere((l) => l.trim().isNotEmpty, orElse: () => '') ?? '';
    final badges = <Widget>[
      if (info.quality != VideoQuality.unknown) Pill(info.quality.text, color: const Color(0xFF7FB2FF)),
      for (final h in info.hdr) Pill('${h.label} (dal nome)', color: AetherTokens.warning),
      if (info.codec != null) Pill(info.codec!),
      if (info.audio != null) Pill(info.audio!, color: const Color(0xFFC59BFF)),
      for (final l in info.languages) Pill(l, color: AetherTokens.success),
      if (info.sizeLabel != null) Pill(info.sizeLabel!),
      if (info.format != null) Pill(info.format!),
      if (info.release != null) Pill(info.release!),
      if (ranked.playability == StreamPlayability.needsDebrid) Pill(cached == null ? (debridConfigured ? 'TorBox · verifico…' : 'Torrent · serve TorBox') : (cached! ? 'TorBox · in cache' : 'TorBox · non in cache'), color: cached == true ? AetherTokens.success : (cached == false ? AetherTokens.warning : Colors.white)),
      if (ranked.playability == StreamPlayability.external) const Pill('Si apre fuori da Aether', color: AetherTokens.warning),
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Semantics(
        button: true,
        label: title,
        child: GestureDetector(
          onTap: onTap,
          child: GlassSurface(
            padding: const EdgeInsets.all(14),
            child: Row(children: [
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14))),
                  if (s.addonName != null) Padding(padding: const EdgeInsets.only(left: 8), child: Text(s.addonName!, style: Theme.of(context).textTheme.bodySmall)),
                ]),
                if (detail.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 3), child: Text(detail, maxLines: 2, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall)),
                if (badges.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Wrap(spacing: 6, runSpacing: 6, children: badges)),
              ])),
              if (onDownload != null) IconButton(tooltip: 'Scarica per guardarlo offline', icon: const Icon(Icons.download_rounded), onPressed: onDownload),
            ]),
          ),
        ),
      ),
    );
  }
}
