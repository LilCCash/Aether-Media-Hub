import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_chrome_cast/flutter_chrome_cast.dart';

import '../../design/glass.dart';

/// «Google Cast»: the Chromecasts and Cast-enabled televisions on the Wi-Fi (iPhone and Android). Aether gives the receiver the
/// link of the video, which it fetches itself with the Default Media Receiver: a source that needs special request headers, or
/// a file the receiver cannot play (many MKV), will not open there.
class GoogleCastSection extends StatefulWidget {
  const GoogleCastSection({
    super.key,
    required this.url,
    required this.title,
    this.artwork,
    this.mime,
    this.onCasting,
  });
  final String? mime;
  final Uri url;
  final String title;
  final String? artwork;
  final VoidCallback? onCasting;

  static bool get supported => Platform.isIOS || Platform.isAndroid;

  @override
  State<GoogleCastSection> createState() => _GoogleCastSectionState();
}

bool _contextReady = false;

class _GoogleCastSectionState extends State<GoogleCastSection> {
  List<GoogleCastDevice> _devices = const [];
  StreamSubscription<List<GoogleCastDevice>>? _sub;
  GoogleCastDevice? _active;
  String? _message;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    try {
      if (!_contextReady) {
        const appId = GoogleCastDiscoveryCriteria.kDefaultApplicationId;
        final GoogleCastOptions options = Platform.isIOS
            ? IOSGoogleCastOptions(
                GoogleCastDiscoveryCriteriaInitialize.initWithApplicationID(
                  appId,
                ),
              )
            : GoogleCastOptionsAndroid(appId: appId);
        await GoogleCastContext.instance.setSharedInstanceWithOptions(options);
        _contextReady = true;
      }
      await GoogleCastDiscoveryManager.instance.startDiscovery();
      _sub = GoogleCastDiscoveryManager.instance.devicesStream.listen((d) {
        if (mounted) setState(() => _devices = d);
      });
    } on Object {
      if (mounted) setState(() => _failed = true);
    }
  }

  String get _mime {
    if (widget.mime != null) return widget.mime!;
    final p = widget.url.path.toLowerCase();
    if (p.endsWith('.m3u8')) return 'application/x-mpegURL';
    if (p.endsWith('.mkv')) return 'video/x-matroska';
    if (p.endsWith('.webm')) return 'video/webm';
    return 'video/mp4';
  }

  Future<void> _cast(GoogleCastDevice d) async {
    setState(() => _message = 'Invio a ${d.friendlyName}…');
    try {
      await GoogleCastSessionManager.instance.startSessionWithDevice(d);
      final art = widget.artwork == null ? null : Uri.tryParse(widget.artwork!);
      await GoogleCastRemoteMediaClient.instance.loadMedia(
        GoogleCastMediaInformation(
          contentId: widget.url.toString(),
          streamType: CastMediaStreamType.buffered,
          contentUrl: widget.url,
          contentType: _mime,
          metadata: GoogleCastMovieMediaMetadata(
            title: widget.title,
            images: art == null
                ? null
                : [GoogleCastImage(url: art, height: 480, width: 320)],
          ),
        ),
        autoPlay: true,
      );
      widget.onCasting?.call();
      if (mounted) {
        setState(() {
          _active = d;
          _message = null;
        });
      }
    } on Object {
      if (mounted) {
        setState(() => _message = 'Il ricevitore non ha aperto questo video.');
      }
    }
  }

  Future<void> _stop() async {
    try {
      await GoogleCastSessionManager.instance.endSessionAndStopCasting();
    } on Object {
      // already ended
    }
    if (mounted) setState(() => _active = null);
  }

  @override
  Widget build(BuildContext context) {
    final active = _active;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Google Cast', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        if (_failed)
          const Text('Google Cast non è disponibile su questo dispositivo.')
        else if (active != null) ...[
          Text('Su ${active.friendlyName}'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              GlassButton(
                icon: Icons.play_arrow_rounded,
                tooltip: 'Riproduci sul ricevitore',
                onPressed: () => GoogleCastRemoteMediaClient.instance.play(),
              ),
              GlassButton(
                icon: Icons.pause_rounded,
                tooltip: 'Pausa sul ricevitore',
                onPressed: () => GoogleCastRemoteMediaClient.instance.pause(),
              ),
              GlassButton(
                icon: Icons.stop_rounded,
                tooltip: 'Ferma la trasmissione',
                onPressed: _stop,
              ),
            ],
          ),
        ] else ...[
          for (final d in _devices)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.cast_rounded),
              title: Text(d.friendlyName),
              subtitle: d.modelName == null ? null : Text(d.modelName!),
              onTap: () => _cast(d),
            ),
          if (_devices.isEmpty)
            const Text(
              'Cerco i dispositivi Cast sulla rete… Il telefono e il ricevitore devono essere sulla stessa rete Wi-Fi.',
            ),
        ],
        if (_message != null) ...[const SizedBox(height: 6), Text(_message!)],
      ],
    );
  }
}
