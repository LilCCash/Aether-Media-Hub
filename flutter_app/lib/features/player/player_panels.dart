import 'package:flutter/material.dart';

import '../../design/glass.dart';
import '../../design/tokens.dart';
import 'playback_engine.dart';
import 'player_session.dart';
import 'subtitle_style.dart';

/// A panel at the right edge (not full screen): in landscape the picture stays visible while choosing.
Future<void> showSidePanel(
  BuildContext context,
  Widget Function(BuildContext) builder,
) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Chiudi il pannello',
    barrierColor: Colors.black38,
    transitionDuration: AetherTokens.medium,
    pageBuilder: (c, _, __) => SafeArea(
      child: Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: SizedBox(
            width: 380,
            child: GlassSurface(
              strong: true,
              radius: 26,
              blur: AetherTokens.blurHigh,
              tint: AetherTokens.inkRaised,
              child: Material(color: Colors.transparent, child: builder(c)),
            ),
          ),
        ),
      ),
    ),
    transitionBuilder: (c, anim, _, child) => SlideTransition(
      position: Tween(
        begin: const Offset(1, 0),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: anim, curve: AetherTokens.ease)),
      child: child,
    ),
  );
}

class _PanelFrame extends StatelessWidget {
  const _PanelFrame({required this.title, required this.children});
  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 12, 6),
        child: Row(
          children: [
            Expanded(
              child: Text(title, style: Theme.of(context).textTheme.titleLarge),
            ),
            IconButton(
              tooltip: 'Chiudi',
              icon: const Icon(Icons.close_rounded),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ],
        ),
      ),
      Flexible(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
          children: children,
        ),
      ),
    ],
  );
}

class _Choice extends StatelessWidget {
  const _Choice({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    dense: true,
    title: Text(label, maxLines: 2, overflow: TextOverflow.ellipsis),
    trailing: selected
        ? Icon(Icons.check_rounded, color: AetherLook.of(context).accent)
        : null,
    onTap: onTap,
  );
}

class SubtitlePanel extends StatelessWidget {
  const SubtitlePanel({super.key, required this.session});
  final PlayerSession session;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final s = session;
        return _PanelFrame(
          title: 'Sottotitoli',
          children: [
            _SyncRow(session: s),
            Theme(
              data: Theme.of(context)
                  .copyWith(dividerColor: Colors.transparent),
              child: const ExpansionTile(
                tilePadding: EdgeInsets.symmetric(horizontal: 16),
                leading: Icon(Icons.format_color_text_rounded),
                title: Text('Aspetto dei sottotitoli'),
                children: [SubtitleStyleControls()],
              ),
            ),
            const Divider(),
            _Choice(
              label: 'Disattivati',
              selected: !s.subtitlesOn,
              onTap: s.disableSubtitles,
            ),
            if (s.tracks.subtitles.isNotEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 10, 16, 2),
                child: Text(
                  'Nel file',
                  style: TextStyle(
                    fontSize: 11,
                    color: AetherTokens.textTertiary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            for (final t in s.tracks.subtitles)
              _Choice(
                label: t.label,
                selected: s.embeddedSubtitle?.id == t.id,
                onTap: () => s.selectEmbeddedSubtitle(t),
              ),
            ..._addonGroups(context, s),
            if (s.loadingSubtitle)
              const Padding(
                padding: EdgeInsets.all(16),
                child: LinearProgressIndicator(),
              ),
            if (s.subtitleProblem != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  s.subtitleProblem!,
                  style: const TextStyle(
                    color: AetherTokens.warning,
                    fontSize: 12,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class AudioPanel extends StatelessWidget {
  const AudioPanel({super.key, required this.session});
  final PlayerSession session;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) {
      final tracks = session.tracks.audio;
      return _PanelFrame(
        title: 'Audio',
        children: [
          if (tracks.isEmpty)
            const Padding(
              padding: EdgeInsets.all(20),
              child: Text('Questo video ha una sola traccia audio.'),
            ),
          for (final t in tracks)
            _Choice(
              label: t.label,
              selected: session.audio?.id == t.id,
              onTap: () => session.selectAudio(t),
            ),
        ],
      );
    },
  );
}

class SpeedPanel extends StatelessWidget {
  const SpeedPanel({super.key, required this.session});
  final PlayerSession session;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) => _PanelFrame(
      title: 'Velocità',
      children: [
        for (final v in const [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0])
          _Choice(
            label: v == 1.0 ? 'Normale' : '$v×',
            selected: session.speed == v,
            onTap: () => session.setSpeed(v),
          ),
      ],
    ),
  );
}

class SourcesPanel extends StatelessWidget {
  const SourcesPanel({super.key, required this.session});
  final PlayerSession session;

  @override
  Widget build(BuildContext context) => _PanelFrame(
    title: 'Altre sorgenti',
    children: [
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Text(
          'Si riparte dal punto in cui sei.',
          style: TextStyle(fontSize: 12, color: AetherTokens.textTertiary),
        ),
      ),
      for (final a in session.args.alternatives)
        _Choice(
          label: a.label,
          selected: false,
          onTap: () {
            Navigator.of(context).pop();
            session.switchSource(a);
          },
        ),
    ],
  );
}

/// Subtitles from addons, grouped by language and, inside each language, by addon (the language of the settings first).
List<Widget> _addonGroups(BuildContext context, PlayerSession s) {
  final subs = s.args.externalSubtitles;
  if (subs.isEmpty) return const [];
  final byLang = <String, Map<String, List<ExternalSubtitle>>>{};
  for (final e in subs) {
    final lang = TrackInfo.languageName(e.language ?? 'und');
    byLang
        .putIfAbsent(lang, () => {})
        .putIfAbsent(e.addon ?? 'Addon', () => [])
        .add(e);
  }
  final preferred = TrackInfo.languageName(s.settings.subtitleLanguage);
  final langs = byLang.keys.toList()
    ..sort((a, b) {
      if (a == preferred) return -1;
      if (b == preferred) return 1;
      return a.compareTo(b);
    });
  const head = TextStyle(
    fontSize: 11,
    color: AetherTokens.textTertiary,
    fontWeight: FontWeight.w700,
  );
  return [
    const Padding(
      padding: EdgeInsets.fromLTRB(16, 10, 16, 2),
      child: Text('Da addon', style: head),
    ),
    for (final lang in langs)
      Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          iconColor: Colors.white,
          collapsedIconColor: Colors.white,
          textColor: Colors.white,
          collapsedTextColor: Colors.white,
          initiallyExpanded:
              lang == preferred ||
              byLang[lang]!.values.any(
                (l) => l.any((e) => s.externalSubtitle?.id == e.id),
              ),
          tilePadding: const EdgeInsets.symmetric(horizontal: 16),
          title: Text(
            '$lang · ${byLang[lang]!.values.fold<int>(0, (a, l) => a + l.length)}',
            style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
          ),
          children: [
            for (final addon in byLang[lang]!.keys) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 2, 16, 0),
                child: Text(addon, style: head),
              ),
              for (var i = 0; i < byLang[lang]![addon]!.length; i++)
                _Choice(
                  label: '$lang ${i + 1}',
                  selected:
                      s.externalSubtitle?.id == byLang[lang]![addon]![i].id,
                  onTap: () =>
                      s.selectExternalSubtitle(byLang[lang]![addon]![i]),
                ),
            ],
          ],
        ),
      ),
  ];
}

/// Subtitle timing, forwards and backwards, for subtitles from addons and for the ones inside the file.
class _SyncRow extends StatelessWidget {
  const _SyncRow({required this.session});
  final PlayerSession session;

  @override
  Widget build(BuildContext context) {
    final ms = session.subtitleOffsetMs;
    Widget step(String label, int d, String tip) => Padding(
      padding: const EdgeInsets.symmetric(horizontal: 3),
      child: ActionChip(
        label: Text(label),
        tooltip: tip,
        visualDensity: VisualDensity.compact,
        onPressed: () => session.setSubtitleOffset(ms + d),
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(child: Text('Sincronia')),
              Text(
                '${ms >= 0 ? '+' : ''}${(ms / 1000).toStringAsFixed(2)} s',
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
              IconButton(
                tooltip: 'Azzera la sincronia',
                icon: const Icon(Icons.restart_alt_rounded),
                onPressed: ms == 0 ? null : () => session.setSubtitleOffset(0),
              ),
            ],
          ),
          Text(
            ms == 0
                ? 'Compaiono troppo presto? Posticipali. Troppo tardi? Anticipali.'
                : (ms > 0
                      ? 'Compaiono più tardi di ${ms / 1000} s.'
                      : 'Compaiono più presto di ${-ms / 1000} s.'),
            style: const TextStyle(
              fontSize: 11,
              color: AetherTokens.textTertiary,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            children: [
              step('−0,5 s', -500, 'Anticipa di mezzo secondo'),
              step('−0,1 s', -100, 'Anticipa di un decimo'),
              step('+0,1 s', 100, 'Posticipa di un decimo'),
              step('+0,5 s', 500, 'Posticipa di mezzo secondo'),
            ],
          ),
        ],
      ),
    );
  }
}

/// A short list of choices in the side panel (the sleep timer…); picking one closes the panel.
class ChoicePanel<T> extends StatelessWidget {
  const ChoicePanel({
    super.key,
    required this.title,
    required this.options,
    required this.onPick,
  });
  final String title;
  final Map<T, String> options;
  final ValueChanged<T> onPick;

  @override
  Widget build(BuildContext context) => _PanelFrame(
    title: title,
    children: [
      for (final e in options.entries)
        _Choice(
          label: e.value,
          selected: false,
          onTap: () {
            onPick(e.key);
            Navigator.of(context).pop();
          },
        ),
    ],
  );
}

/// «Informazioni sulla sorgente»: what is playing and what the engine found in the file.
class InfoPanel extends StatelessWidget {
  const InfoPanel({super.key, required this.session, required this.engine});
  final PlayerSession session;
  final PlaybackEngine engine;

  static String _dur(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '${d.inMinutes}:$s';
  }

  static String _range(String? gamma) => switch (gamma) {
    'pq' => 'HDR10 / Dolby Vision (PQ)',
    'hlg' => 'HLG',
    null => 'Non rilevata',
    _ => 'SDR',
  };

  Widget _section(String title) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
    child: Text(
      title.toUpperCase(),
      style: const TextStyle(
        fontSize: 11,
        letterSpacing: 0.6,
        color: AetherTokens.textTertiary,
        fontWeight: FontWeight.w800,
      ),
    ),
  );

  Widget _row(String k, String? v) => v == null || v.isEmpty
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 118,
                child: Text(
                  k,
                  style: const TextStyle(
                    fontSize: 13,
                    color: AetherTokens.textSecondary,
                  ),
                ),
              ),
              Expanded(child: Text(v, style: const TextStyle(fontSize: 13))),
            ],
          ),
        );

  @override
  Widget build(BuildContext context) => _PanelFrame(
    title: 'Informazioni sulla sorgente',
    children: [
      FutureBuilder<Map<String, String>>(
        future: engine.probe(),
        builder: (context, snap) {
          final p = snap.data ?? const <String, String>{};
          final w = p['video-params/w'];
          final h = p['video-params/h'];
          final fps = double.tryParse(p['container-fps'] ?? '');
          final a = session.args;
          final audio = session.tracks.audio;
          final subs = session.tracks.subtitles;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _section('Riproduzione'),
              _row('Motore', 'libmpv (media_kit)'),
              _row('Risoluzione', w != null && h != null ? '$w×$h' : null),
              _row(
                'Durata',
                session.duration > Duration.zero
                    ? _dur(session.duration)
                    : null,
              ),
              _row(
                'Velocità',
                session.speed == 1 ? 'Normale' : '${session.speed}×',
              ),
              _row('Schermo', session.aspect.label),
              _section('Sorgente'),
              _row('Titolo', a.title),
              _row(
                'Nome del file',
                a.source.title.isEmpty ? null : a.source.title,
              ),
              _row(
                'Origine',
                a.source.isLocalFile
                    ? 'File scaricato sul dispositivo'
                    : 'Rete',
              ),
              _section('Formato rilevato dal motore'),
              _row('Contenitore', p['file-format']?.toUpperCase()),
              _row(
                'Video',
                [
                  if (p['video-codec'] != null)
                    p['video-codec']!.split(' ').first
                  else
                    p['video-format'],
                  if (fps != null)
                    '${fps.toStringAsFixed(fps.truncateToDouble() == fps ? 0 : 3)} fps',
                ].whereType<String>().join(' · '),
              ),
              _row('Pixel', p['video-params/pixelformat']),
              _row(
                'Gamma dinamica',
                snap.hasData ? _range(p['video-params/gamma']) : null,
              ),
              _row(
                'Colore',
                [
                  p['video-params/primaries'],
                  p['video-params/colormatrix'],
                ].whereType<String>().join(' · '),
              ),
              _row(
                'Decodifica',
                p['hwdec-current'] == null
                    ? null
                    : (p['hwdec-current'] == 'no'
                          ? 'Software'
                          : 'Hardware (${p['hwdec-current']})'),
              ),
              _row(
                'Audio attivo',
                [
                  p['audio-codec-name'],
                  if (p['audio-params/channel-count'] != null)
                    '${p['audio-params/channel-count']} canali',
                ].whereType<String>().join(' · '),
              ),
              if (audio.isNotEmpty) _section('Tracce audio'),
              for (final t in audio) _row(' ', t.label),
              if (subs.isNotEmpty) _section('Sottotitoli nel file'),
              for (final t in subs) _row(' ', t.label),
              if (a.externalSubtitles.isNotEmpty)
                _row(
                  'Da addon',
                  '${a.externalSubtitles.length} sottotitoli disponibili',
                ),
              if (!snap.hasData)
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: LinearProgressIndicator(),
                ),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 14, 16, 8),
                child: Text(
                  '«Rilevato» viene dal decoder del motore in uso. Gli stream adattivi (HLS) cambiano qualità in base alla rete.',
                  style: TextStyle(
                    fontSize: 11,
                    color: AetherTokens.textTertiary,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    ],
  );
}
