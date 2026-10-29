import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/casting/upnp.dart';
import '../../design/glass.dart';
import '../../design/widgets.dart';
import 'google_cast_section.dart';

/// «Trasmetti sulla TV» (DLNA): finds the televisions on the Wi-Fi, gives the chosen one the link of the video and offers
/// play/pause/stop and volume. The picture is not mirrored and nothing is converted: the television fetches the link itself.
class CastSheet extends StatefulWidget {
  const CastSheet({
    super.key,
    required this.url,
    required this.title,
    this.artwork,
    this.mime,
    this.hasHeaders = false,
    this.onCasting,
    this.discovery,
    this.client,
  });

  final Uri url;
  final String title;
  final String? artwork;

  /// The content type when it is not the file's own (a converted MKV is HLS).
  final String? mime;

  /// The source needs request headers the television cannot send.
  final bool hasHeaders;

  /// Called when the television starts (the local player pauses).
  final VoidCallback? onCasting;
  final UpnpDiscovery? discovery;
  final UpnpClient? client;

  @override
  State<CastSheet> createState() => _CastSheetState();
}

class _CastSheetState extends State<CastSheet> {
  late final UpnpClient _client = widget.client ?? UpnpClient();
  late final UpnpDiscovery _discovery =
      widget.discovery ?? UpnpDiscovery(client: _client);
  final List<UpnpDevice> _devices = [];
  StreamSubscription<UpnpDevice>? _sub;
  bool _searching = false;
  UpnpDevice? _active;
  UpnpTransportState? _state;
  String? _message;
  Timer? _poll;
  double _volume = 30;

  @override
  void initState() {
    super.initState();
    if (UpnpDiscovery.supported) _search();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _poll?.cancel();
    super.dispose();
  }

  void _search() {
    setState(() {
      _devices.clear();
      _searching = true;
      _message = null;
    });
    _sub?.cancel();
    _sub = _discovery.discover().listen(
      (d) {
        if (mounted && !_devices.any((e) => e.id == d.id)) {
          setState(() => _devices.add(d));
        }
      },
      onError: (_) {
        if (mounted) {
          setState(() {
            _searching = false;
            _message = 'Impossibile cercare i dispositivi sulla rete.';
          });
        }
      },
      onDone: () {
        if (mounted) setState(() => _searching = false);
      },
    );
  }

  Future<void> _cast(UpnpDevice d) async {
    setState(() => _message = 'Invio a ${d.friendlyName}…');
    try {
      await _client.cast(d, widget.url, widget.title, artwork: widget.artwork);
      widget.onCasting?.call();
      if (!mounted) return;
      setState(() {
        _active = d;
        _message = null;
      });
      _poll = Timer.periodic(const Duration(seconds: 3), (_) async {
        try {
          final st = await _client.state(d);
          if (mounted) setState(() => _state = st);
        } on UpnpException {
          // the next tick tries again
        }
      });
    } on UpnpException catch (e) {
      if (mounted) setState(() => _message = e.message);
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } on UpnpException catch (e) {
      if (mounted) setState(() => _message = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final active = _active;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Trasmetti sulla TV',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 6),
            Text(
              'Aether dà alla TV il link del video (DLNA): la TV lo scarica da sola, quindi deve poterlo aprire. Non è lo specchio dello schermo e non converte nulla.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (widget.hasHeaders) ...[
              const SizedBox(height: 8),
              const Pill(
                'Questa sorgente richiede intestazioni: la TV potrebbe non aprirla',
              ),
            ],
            const SizedBox(height: 12),
            if (Platform.isIOS) ...[
              Row(
                children: [
                  const SizedBox(
                    width: 44,
                    height: 44,
                    child: UiKitView(viewType: 'aether/airplay'),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'AirPlay: sceglie dove esce l’audio (e lo schermo, se il dispositivo lo consente). Con il motore libmpv AirPlay porta solo l’audio: per il video usa Google Cast.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
            ],
            if (GoogleCastSection.supported) ...[
              GoogleCastSection(
                url: widget.url,
                title: widget.title,
                artwork: widget.artwork,
                mime: widget.mime,
                onCasting: widget.onCasting,
              ),
              const SizedBox(height: 14),
            ],
            if (!UpnpDiscovery.supported)
              const SizedBox.shrink()
            else if (active != null) ...[
              Text(
                'Su ${active.friendlyName}',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              Text(switch (_state) {
                UpnpTransportState.playing => 'In riproduzione',
                UpnpTransportState.paused => 'In pausa',
                UpnpTransportState.stopped => 'Fermo',
                UpnpTransportState.transitioning => 'Caricamento…',
                _ => 'In attesa della TV…',
              }),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                children: [
                  GlassButton(
                    icon: Icons.play_arrow_rounded,
                    tooltip: 'Riproduci sulla TV',
                    onPressed: () => _run(() => _client.play(active)),
                  ),
                  GlassButton(
                    icon: Icons.pause_rounded,
                    tooltip: 'Pausa sulla TV',
                    onPressed: () => _run(() => _client.pause(active)),
                  ),
                  GlassButton(
                    icon: Icons.stop_rounded,
                    tooltip: 'Ferma la trasmissione',
                    onPressed: () => _run(() async {
                      await _client.stop(active);
                      _poll?.cancel();
                      if (mounted) setState(() => _active = null);
                    }),
                  ),
                ],
              ),
              if (active.renderingControl != null)
                Slider(
                  value: _volume,
                  min: 0,
                  max: 100,
                  divisions: 20,
                  label: 'Volume TV ${_volume.round()}',
                  onChanged: (v) => setState(() => _volume = v),
                  onChangeEnd: (v) =>
                      _run(() => _client.setVolume(active, v.round())),
                ),
            ] else ...[
              if (_searching)
                const Row(
                  children: [
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 10),
                    Text('Cerco le TV sulla rete…'),
                  ],
                ),
              for (final d in _devices)
                ListTile(
                  leading: const Icon(Icons.tv_rounded),
                  title: Text(d.friendlyName),
                  subtitle: Text(
                    [d.manufacturer, d.modelName].whereType<String>().join(' '),
                  ),
                  onTap: () => _cast(d),
                ),
              if (!_searching && _devices.isEmpty)
                const Text(
                  'Nessuna TV trovata. Il telefono e la TV devono essere sulla stessa rete Wi-Fi e la TV deve avere DLNA/«Miracast e streaming» attivo.',
                ),
              if (!_searching)
                TextButton.icon(
                  onPressed: _search,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Cerca di nuovo'),
                ),
            ],
            if (_message != null) ...[
              const SizedBox(height: 8),
              Text(_message!),
            ],
          ],
        ),
      ),
    );
  }
}
