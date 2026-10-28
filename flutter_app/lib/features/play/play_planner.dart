import 'package:dio/dio.dart';

import '../../app/services.dart';
import '../../core/debrid/debrid_resolver.dart';
import '../../core/debrid/torbox_client.dart';
import '../../core/model/meta.dart';
import '../../core/model/stream.dart';
import '../../core/streams/stream_analyzer.dart';
import '../../data/settings.dart';
import '../../data/stores.dart';
import '../player/playback_engine.dart';
import '../player/player_session.dart';

/// Turns "the viewer chose this source" into something the player can open: a direct link, or a TorBox link for a torrent.
/// Also finds the next episode and the alternative sources. No widgets here, so all of it is testable.
class PlayPlanner {
  PlayPlanner(this.services, this.settings, {DebridResolver? resolver})
    : resolver = resolver ?? DebridResolver(services.torbox);

  final AppServices services;
  final AppSettings settings;
  final DebridResolver resolver;

  Future<bool> get debridConfigured async =>
      ((await services.secrets.serviceKey(ServiceKey.torbox)) ?? '').isNotEmpty;

  StreamRanker get ranker =>
      StreamRanker(preferredLanguage: settings.preferredStreamLanguage);

  /// The local file of a finished download for this video, as a source (offline playback), or null.
  PlaybackSource? offlineSource(String videoId) {
    final path = services.downloads.localPath(videoId);
    return path == null ? null : PlaybackSource(uri: path, isLocalFile: true);
  }

  Future<PlaybackSource> sourceFor(
    AddonStream stream, {
    bool allowDownload = false,
    int? season,
    int? episode,
    void Function(ResolveStatus)? onStatus,
    CancelToken? cancel,
  }) async {
    if (stream.isDirect)
      return PlaybackSource(uri: stream.url!, headers: stream.proxyHeaders);
    if (stream.isTorrent) {
      final link = await resolver.resolve(
        stream,
        allowDownload: allowDownload,
        season: season,
        episode: episode,
        onStatus: onStatus,
        cancel: cancel,
      );
      return PlaybackSource(uri: link.uri.toString());
    }
    throw const DebridException(
      DebridFailure.unknown,
      'Questa sorgente non si può aprire nel player.',
    );
  }

  List<ExternalSubtitle> subtitlesFor(
    AddonStream stream,
    List<AddonSubtitle> fromAddons,
  ) {
    final all = [...stream.subtitles, ...fromAddons];
    final seen = <String>{};
    final result = <ExternalSubtitle>[];
    for (final s in all) {
      if (!seen.add(s.url)) continue;
      final lang = TrackInfo.languageName(s.lang);
      result.add(
        ExternalSubtitle(
          id: s.id,
          label: '$lang${s.addonName == null ? '' : ' · ${s.addonName}'}',
          language: s.lang,
          url: s.url,
        ),
      );
    }
    return result;
  }

  PlayerArgs buildArgs({
    required MetaItem meta,
    required Video? video,
    required AddonStream stream,
    required PlaybackSource source,
    List<AddonSubtitle> addonSubtitles = const [],
    List<RankedStream> others = const [],
  }) {
    final season = video?.season;
    final episode = video?.episode;
    final alternatives = [
      for (final o
          in others
              .where(
                (o) =>
                    o.stream != stream &&
                    (o.playability == StreamPlayability.direct ||
                        o.playability == StreamPlayability.needsDebrid),
              )
              .take(6))
        PlayerAlternative(
          label:
              '${o.stream.addonName ?? 'Addon'} · ${[o.info.quality.text, o.info.release].whereType<String>().where((e) => e.isNotEmpty).join(' ')}',
          open: () => sourceFor(o.stream, season: season, episode: episode),
        ),
    ];
    return PlayerArgs(
      title: meta.name,
      metaId: meta.id,
      videoId: video?.id ?? meta.id,
      type: meta.type,
      poster: meta.poster,
      season: season,
      episode: episode,
      episodeTitle: video?.title,
      source: source,
      externalSubtitles: subtitlesFor(stream, addonSubtitles),
      alternatives: alternatives,
      onNext: video == null ? null : () => nextEpisode(meta, video, stream),
    );
  }

  /// The episode after [current] (same season, then the next season), with its best source that plays without asking
  /// anything: a direct link, or a torrent already in TorBox's cache. Null when there is none.
  Future<PlayerArgs?> nextEpisode(
    MetaItem meta,
    Video current,
    AddonStream playedWith,
  ) async {
    final ordered =
        meta.videos.where((v) => v.isEpisode && v.season != 0).toList()..sort(
          (a, b) => a.season != b.season
              ? a.season!.compareTo(b.season!)
              : a.episode!.compareTo(b.episode!),
        );
    final index = ordered.indexWhere((v) => v.id == current.id);
    if (index < 0 || index + 1 >= ordered.length) return null;
    final next = ordered[index + 1];
    final addons = services.addons.providers('stream', meta.type, next.id);
    final streams = <AddonStream>[];
    for (final a in addons) {
      try {
        streams.addAll(
          await services.addonClient.streams(
            a.base,
            meta.type,
            next.id,
            addonId: a.id,
            addonName: a.displayName,
          ),
        );
      } on Object {
        continue; // a broken addon never blocks the next episode
      }
    }
    if (streams.isEmpty) return null;
    final debrid = await debridConfigured;
    final ranked = StreamRanker(
      preferredLanguage: settings.preferredStreamLanguage,
      debridConfigured: debrid,
    ).rank(streams);
    // Same release group first (binge group), then the best.
    final preferred =
        [
          ...ranked.where(
            (r) =>
                playedWith.bingeGroup != null &&
                r.stream.bingeGroup == playedWith.bingeGroup,
          ),
          ...ranked,
        ].where(
          (r) =>
              r.playability == StreamPlayability.direct ||
              (debrid && r.playability == StreamPlayability.needsDebrid),
        );
    for (final candidate in preferred.take(3)) {
      try {
        final source = await sourceFor(
          candidate.stream,
          season: next.season,
          episode: next.episode,
        );
        return buildArgs(
          meta: meta,
          video: next,
          stream: candidate.stream,
          source: source,
          others: ranked,
        );
      } on Object {
        continue; // not in cache: never start a download without asking
      }
    }
    return null;
  }
}
