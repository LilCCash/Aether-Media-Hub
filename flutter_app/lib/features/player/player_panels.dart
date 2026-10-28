import 'package:flutter/material.dart';

import '../../design/glass.dart';
import '../../design/tokens.dart';
import 'player_session.dart';

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
            if (s.args.externalSubtitles.isNotEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 10, 16, 2),
                child: Text(
                  'Da addon',
                  style: TextStyle(
                    fontSize: 11,
                    color: AetherTokens.textTertiary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            for (final e in s.args.externalSubtitles)
              _Choice(
                label: e.label,
                selected: s.externalSubtitle?.id == e.id,
                onTap: () => s.selectExternalSubtitle(e),
              ),
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
            if (s.externalSubtitle != null) ...[
              const Divider(),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    const Expanded(child: Text('Sincronia')),
                    IconButton(
                      tooltip: 'Anticipa di 0,25 s',
                      icon: const Icon(Icons.remove_circle_outline_rounded),
                      onPressed: () =>
                          s.setSubtitleOffset(s.subtitleOffsetMs - 250),
                    ),
                    SizedBox(
                      width: 74,
                      child: Text(
                        '${s.subtitleOffsetMs >= 0 ? '+' : ''}${(s.subtitleOffsetMs / 1000).toStringAsFixed(2)} s',
                        textAlign: TextAlign.center,
                      ),
                    ),
                    IconButton(
                      tooltip: 'Posticipa di 0,25 s',
                      icon: const Icon(Icons.add_circle_outline_rounded),
                      onPressed: () =>
                          s.setSubtitleOffset(s.subtitleOffsetMs + 250),
                    ),
                  ],
                ),
              ),
            ] else if (s.embeddedSubtitle != null)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'La sincronia si regola solo sui sottotitoli da addon.',
                  style: TextStyle(
                    fontSize: 11,
                    color: AetherTokens.textTertiary,
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
