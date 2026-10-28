import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';

import '../../design/glass.dart';
import '../../design/tokens.dart';
import 'playback_engine.dart';
import 'player_session.dart';

/// The player check that needs no network, no addon and no account: it plays original test clips bundled in the app (generated
/// by `tool/make_test_media.sh`), with a second audio track and subtitles to exercise the real controls. It also opens when the
/// device is in airplane mode. (Streams from the internet are, of course, not available offline: only downloaded files are.)
class OfflineTestScreen extends StatefulWidget {
  const OfflineTestScreen({super.key});

  @override
  State<OfflineTestScreen> createState() => _OfflineTestScreenState();
}

class _OfflineTestScreenState extends State<OfflineTestScreen> {
  bool _busy = false;
  String? _error;

  static const _clips = [
    ('assets/test/aether_test.mp4', 'MP4 · H.264 + AAC', 'Un solo audio, nessun sottotitolo incluso: prova controlli, seek e velocità.'),
    ('assets/test/aether_multitrack.mkv', 'MKV · 2 tracce audio + 2 sottotitoli', 'Italiano e inglese incorporati: prova la scelta di audio e sottotitoli.'),
  ];

  Future<void> _open(String asset, String title) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final data = await rootBundle.load(asset);
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/${asset.split('/').last}');
      await file.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
      final ita = await rootBundle.loadString('assets/test/aether_test_ita.srt');
      final eng = await rootBundle.loadString('assets/test/aether_test_eng.srt');
      if (!mounted) return;
      await context.push('/player', extra: PlayerArgs(
        title: 'Prova: $title',
        saveProgress: false,
        source: PlaybackSource(uri: file.path, isLocalFile: true),
        externalSubtitles: asset.endsWith('.mp4')
            ? [ExternalSubtitle(id: 'ita', label: 'Italiano (file di prova)', language: 'ita', text: ita), ExternalSubtitle(id: 'eng', label: 'Inglese (file di prova)', language: 'eng', text: eng)]
            : const [],
      ));
    } on Object {
      setState(() => _error = 'Non riesco a preparare il file di prova.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AetherBackdrop(
        child: SafeArea(
          child: ListView(padding: const EdgeInsets.all(20), children: [
            Row(children: [GlassButton(icon: Icons.arrow_back_ios_new_rounded, tooltip: 'Indietro', onPressed: () => context.pop()), const SizedBox(width: 12), Expanded(child: Text('Player di prova', style: Theme.of(context).textTheme.headlineMedium))]),
            const SizedBox(height: 16),
            Text('Funziona senza connessione: i video sono inclusi nell’app.', style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 20),
            for (final c in _clips)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: GestureDetector(
                  onTap: _busy ? null : () => _open(c.$1, c.$2),
                  child: GlassSurface(padding: const EdgeInsets.all(16), child: Row(children: [
                    const Icon(Icons.play_circle_fill_rounded, size: 40),
                    const SizedBox(width: 14),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(c.$2, style: Theme.of(context).textTheme.titleMedium), const SizedBox(height: 2), Text(c.$3, style: Theme.of(context).textTheme.bodySmall)])),
                  ])),
                ),
              ),
            if (_busy) const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator())),
            if (_error != null) Text(_error!, style: const TextStyle(color: AetherTokens.warning)),
          ]),
        ),
      ),
    );
  }
}
