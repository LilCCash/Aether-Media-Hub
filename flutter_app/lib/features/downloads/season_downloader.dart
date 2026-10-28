import 'package:flutter/foundation.dart';

import '../../app/services.dart';
import '../../core/model/meta.dart';
import '../../core/model/stream.dart';
import '../../core/streams/stream_analyzer.dart';
import '../../data/prefs_ext.dart';
import '../../data/settings.dart';
import '../play/play_planner.dart';
import 'download_manager.dart';

class SeasonDownloadSummary {
  const SeasonDownloadSummary({
    this.queued = 0,
    this.skipped = 0,
    this.alreadyPresent = 0,
    this.cancelled = false,
    this.empty = false,
  });
  final int queued;
  final int skipped;
  final int alreadyPresent;
  final bool cancelled;
  final bool empty;

  String get message {
    if (empty) return 'Non ci sono episodi già disponibili in questa stagione.';
    if (cancelled) {
      return 'Download della stagione annullato. I file già completati sono stati conservati.';
    }
    final b = StringBuffer('Download stagione: $queued episodi accodati');
    if (alreadyPresent > 0) b.write(', $alreadyPresent già presenti');
    if (skipped > 0) b.write(', $skipped non disponibili o non compatibili');
    b.write('.');
    return b.toString();
  }
}

const _langNames = {
  'ita': 'Italiano',
  'eng': 'Inglese',
  'fra': 'Francese',
  'spa': 'Spagnolo',
  'deu': 'Tedesco',
  'por': 'Portoghese',
  'jpn': 'Giapponese',
};

int _height(VideoQuality q) => switch (q) {
  VideoQuality.p480 => 480,
  VideoQuality.p720 => 720,
  VideoQuality.p1080 => 1080,
  VideoQuality.p1440 => 1440,
  VideoQuality.p2160 => 2160,
  VideoQuality.unknown => 0,
};

/// The sources of one episode that may be downloaded, best candidate first, following the season policy of the iOS app:
/// 1. only what plays (a direct link, or a torrent when a debrid service is set up);
/// 2. the pool in the wanted language if any source states it, else everything playable (an episode is not skipped for that);
/// 3. the quality limit, strictly (an unknown quality passes);
/// 4. not above the quality chosen for the first episode, so the season is consistent;
/// 5. lighter files first (unknown size last), or best score first.
List<RankedStream> seasonCandidates(
  List<RankedStream> ranked, {
  required bool debrid,
  required int capHeight,
  required bool preferSmaller,
  String? language,
  int? targetHeight,
}) {
  final playable = ranked
      .where(
        (r) =>
            r.playability == StreamPlayability.direct ||
            (debrid && r.playability == StreamPlayability.needsDebrid),
      )
      .toList();
  if (playable.isEmpty) return const [];
  final byLanguage = language == null
      ? playable
      : playable
            .where(
              (r) =>
                  r.info.languages.contains(language) ||
                  r.info.languages.contains('Multi'),
            )
            .toList();
  final pool = byLanguage.isEmpty ? playable : byLanguage;
  final withinCap = pool.where((r) {
    final h = _height(r.info.quality);
    return capHeight <= 0 || h == 0 || h <= capHeight;
  }).toList();
  final consistent = withinCap.where((r) {
    final h = _height(r.info.quality);
    return targetHeight == null || h == 0 || h <= targetHeight;
  }).toList();
  final chosen = consistent.isEmpty ? withinCap : consistent;
  final ordered = [...chosen];
  if (preferSmaller) {
    ordered.sort((a, b) {
      final x = a.info.sizeBytes ?? 1 << 62;
      final y = b.info.sizeBytes ?? 1 << 62;
      return x != y ? x.compareTo(y) : b.score.compareTo(a.score);
    });
  } else {
    ordered.sort((a, b) => b.score.compareTo(a.score));
  }
  return ordered;
}

/// Queues every released episode of a season with one consistent language/quality policy. A missing source only skips that
/// episode; it never aborts the rest of the season.
class SeasonDownloader {
  SeasonDownloader(this.services, this.settings);
  final AppServices services;
  final AppSettings settings;

  Future<SeasonDownloadSummary> run(
    MetaItem meta,
    int season, {
    required void Function(String) onMessage,
    required bool Function() cancelled,
  }) async {
    final now = DateTime.now();
    final episodes = meta
        .episodesOf(season)
        .where((v) => v.released == null || !v.released!.isAfter(now))
        .toList();
    if (episodes.isEmpty) return const SeasonDownloadSummary(empty: true);
    final debrid = await services.activeDebrid(settings);
    var cap = settings.seasonQuality;
    if (settings.seasonSizePolicy == 'preferSmaller' && cap == 0) cap = 1080;
    final lang = switch (settings.seasonLanguage) {
      'any' => null,
      'preferred' => settings.preferredStreamLanguage,
      final code => _langNames[code],
    };
    final disabled = settings.seasonDisabledAddons.toSet();
    final ranker = PlayPlanner.rankerFor(
      services,
      settings,
      debridConfigured: debrid != null,
    );
    var queued = 0, skipped = 0, present = 0;
    int? target;
    for (var i = 0; i < episodes.length; i++) {
      if (cancelled()) break;
      final v = episodes[i];
      onMessage('Cerco sorgenti · episodio ${i + 1} di ${episodes.length}…');
      final existing = services.downloads.byVideo(v.id);
      if (existing != null && existing.status.name != 'failed') {
        present++;
        continue;
      }
      final streams = <AddonStream>[];
      for (final a in services.addons.providers('stream', meta.type, v.id)) {
        if (disabled.contains(a.id)) continue;
        try {
          streams.addAll(
            await services.addonClient.streams(
              a.base,
              meta.type,
              v.id,
              addonId: a.id,
              addonName: a.displayName,
            ),
          );
        } on Object {
          continue; // a broken addon never blocks the season
        }
      }
      if (cancelled()) break;
      final candidates = seasonCandidates(
        ranker.rank(streams),
        debrid: debrid != null,
        capHeight: cap,
        preferSmaller: settings.seasonSizePolicy == 'preferSmaller',
        language: lang,
        targetHeight: target,
      );
      if (candidates.isEmpty) {
        skipped++;
        continue;
      }
      target ??= candidates
          .map((c) => _height(c.info.quality))
          .where((h) => h > 0)
          .fold<int?>(null, (a, h) => a == null || h > a ? h : a);
      var done = false;
      for (var ci = 0; ci < candidates.length; ci++) {
        final c = candidates[ci];
        if (cancelled()) break;
        try {
          var url = c.stream.url;
          String? fileName = c.stream.filename;
          if (c.playability == StreamPlayability.needsDebrid) {
            final link = await debrid!.resolve(
              c.stream,
              allowDownload: true,
              season: v.season,
              episode: v.episode,
            );
            url = link.uri.toString();
            fileName = link.fileName ?? fileName;
          }
          if (url == null) continue;
          await services.downloads.enqueue(
            metaId: meta.id,
            videoId: v.id,
            type: meta.type,
            title: '${meta.name} · ${v.label}',
            url: url,
            poster: meta.poster,
            season: v.season,
            episode: v.episode,
            fileName: fileName,
            headers: c.playability == StreamPlayability.direct
                ? c.stream.proxyHeaders
                : const {},
            // Direct http(s) alternatives wait in case this source fails later; a torrent cannot be a fallback.
            fallbacks: [
              for (final alt in candidates.skip(ci + 1))
                if (alt.playability == StreamPlayability.direct &&
                    (alt.stream.url ?? '').startsWith('http'))
                  DownloadFallback(
                    alt.stream.url!,
                    headers: alt.stream.proxyHeaders,
                  ),
            ],
          );
          queued++;
          done = true;
          break;
        } on Object {
          continue; // this source failed: try the next one for the same episode
        }
      }
      if (!done && !cancelled()) skipped++;
    }
    return SeasonDownloadSummary(
      queued: queued,
      skipped: skipped,
      alreadyPresent: present,
      cancelled: cancelled(),
    );
  }
}

/// Season downloads that live in the app, not in the page that started them: leaving the title keeps the search going,
/// and coming back shows the same progress instead of offering the button again.
class SeasonJobs extends ChangeNotifier {
  final Map<String, ({String message, bool busy, bool cancel})> _jobs = {};

  static String keyOf(String metaId, int season) => '$metaId#$season';

  bool busy(String metaId, int season) =>
      _jobs[keyOf(metaId, season)]?.busy ?? false;
  String? message(String metaId, int season) =>
      _jobs[keyOf(metaId, season)]?.message;

  void _set(String k, {String? message, bool? busy, bool? cancel}) {
    final old = _jobs[k];
    _jobs[k] = (
      message: message ?? old?.message ?? '',
      busy: busy ?? old?.busy ?? false,
      cancel: cancel ?? old?.cancel ?? false,
    );
    notifyListeners();
  }

  void cancel(String metaId, int season) {
    final k = keyOf(metaId, season);
    if (_jobs[k]?.busy != true) return;
    _set(k, cancel: true, message: 'Annullamento in corso…');
  }

  Future<void> start(
    AppServices services,
    AppSettings settings,
    MetaItem meta,
    int season,
  ) async {
    final k = keyOf(meta.id, season);
    if (_jobs[k]?.busy == true) return;
    _set(k, busy: true, cancel: false, message: 'Cerco le sorgenti…');
    SeasonDownloadSummary summary;
    try {
      summary = await SeasonDownloader(services, settings).run(
        meta,
        season,
        onMessage: (m) => _set(k, message: m),
        cancelled: () => _jobs[k]?.cancel ?? false,
      );
    } on Object catch (e) {
      _set(k, busy: false, message: 'Download della stagione interrotto: $e');
      return;
    }
    _set(k, busy: false, cancel: false, message: summary.message);
  }
}
