import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:xml/xml.dart';

import '../util/app_log.dart';

/// DLNA / UPnP AV "MediaRenderer" control: SSDP discovery, device description, SOAP (AVTransport / RenderingControl) and
/// DIDL-Lite metadata. It sends the television a LINK to the video, which the television then fetches itself: no relay, no
/// conversion. Whether a given television plays a given container or codec is up to it.

class UpnpService {
  const UpnpService(this.serviceType, this.controlUrl);
  final String serviceType;
  final Uri controlUrl;
}

class UpnpDevice {
  const UpnpDevice({
    required this.udn,
    required this.friendlyName,
    required this.location,
    required this.services,
    this.manufacturer,
    this.modelName,
  });
  final String udn;
  final String friendlyName;
  final String? manufacturer;
  final String? modelName;
  final Uri location;
  final List<UpnpService> services;

  String get id => udn.isEmpty ? location.toString() : udn;

  UpnpService? get avTransport => services
      .where((s) => s.serviceType.contains(':service:AVTransport:'))
      .firstOrNull;
  UpnpService? get renderingControl => services
      .where((s) => s.serviceType.contains(':service:RenderingControl:'))
      .firstOrNull;
  bool get isMediaRenderer => avTransport != null;
}

class UpnpException implements Exception {
  const UpnpException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Only devices on the local network are talked to: a response from anywhere else, or a control address on another host than
/// the one that answered, is refused (a stranger on the network must not be able to aim the app at an arbitrary server).
bool isLocalHost(String host) {
  final parts = host.split('.');
  if (parts.length != 4) return false;
  final n = parts.map(int.tryParse).toList();
  if (n.any((e) => e == null || e < 0 || e > 255)) return false;
  final a = n[0]!, b = n[1]!;
  return a == 10 ||
      (a == 172 && b >= 16 && b <= 31) ||
      (a == 192 && b == 168) ||
      (a == 169 && b == 254);
}

class UpnpDescriptionParser {
  const UpnpDescriptionParser._();

  static UpnpDevice parse(String xml, Uri location) {
    final XmlDocument doc;
    try {
      doc = XmlDocument.parse(xml);
    } on XmlException {
      throw const UpnpException('Descrizione del dispositivo non valida.');
    }
    String? text(XmlElement scope, String name) => scope
        .findAllElements(name)
        .map((e) => e.innerText.trim())
        .where((s) => s.isNotEmpty)
        .firstOrNull;
    final root = doc.rootElement;
    final urlBase = text(root, 'URLBase');
    final base = urlBase == null
        ? location
        : (Uri.tryParse(urlBase) ?? location);
    final device = root.findAllElements('device').firstOrNull ?? root;
    final services = <UpnpService>[];
    for (final s in root.findAllElements('service')) {
      final type = text(s, 'serviceType');
      final control = text(s, 'controlURL');
      if (type == null || control == null) continue;
      final resolved = base.resolve(control);
      // Same host as the one that answered, and a LAN address.
      if (resolved.host != location.host || !isLocalHost(resolved.host))
        continue;
      if (resolved.scheme != 'http' && resolved.scheme != 'https') continue;
      services.add(UpnpService(type, resolved));
    }
    final name = text(device, 'friendlyName');
    if (name == null && services.isEmpty) {
      throw const UpnpException('Descrizione del dispositivo non valida.');
    }
    return UpnpDevice(
      udn: text(device, 'UDN') ?? '',
      friendlyName: name ?? 'Dispositivo UPnP',
      manufacturer: text(device, 'manufacturer'),
      modelName: text(device, 'modelName'),
      location: location,
      services: services,
    );
  }
}

class Soap {
  const Soap._();

  static String escape(String v) => v
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');

  static String envelope(
    String serviceType,
    String action,
    List<(String, String)> args,
  ) {
    final b = StringBuffer(
      '<?xml version="1.0" encoding="utf-8"?>'
      '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
      's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>'
      '<u:$action xmlns:u="$serviceType">',
    );
    for (final (name, value) in args) {
      b.write('<$name>${escape(value)}</$name>');
    }
    b.write('</u:$action></s:Body></s:Envelope>');
    return b.toString();
  }

  static Map<String, String> headers(String serviceType, String action) => {
    'Content-Type': 'text/xml; charset="utf-8"',
    'SOAPAction': '"$serviceType#$action"',
    'Accept': 'text/xml',
  };

  /// Leaf element name → text; a fault is reported in [SoapReply.fault].
  static SoapReply parseResponse(String xml) {
    try {
      final doc = XmlDocument.parse(xml);
      final values = <String, String>{};
      for (final e in doc.findAllElements('*')) {
        if (e.childElements.isEmpty) values[e.name.local] = e.innerText;
      }
      final fault = doc.findAllElements('UPnPError').firstOrNull;
      if (fault != null) {
        return SoapReply(
          values,
          fault: [
            fault.findElements('errorCode').firstOrNull?.innerText,
            fault.findElements('errorDescription').firstOrNull?.innerText,
          ].whereType<String>().join(' · '),
        );
      }
      return SoapReply(values);
    } on XmlException {
      return const SoapReply({});
    }
  }
}

class SoapReply {
  const SoapReply(this.values, {this.fault});
  final Map<String, String> values;
  final String? fault;
}

class Didl {
  const Didl._();

  static String mimeType(String extension) => switch (extension.toLowerCase()) {
    'mp4' || 'm4v' => 'video/mp4',
    'mkv' => 'video/x-matroska',
    'avi' => 'video/x-msvideo',
    'mov' => 'video/quicktime',
    'webm' => 'video/webm',
    'ts' || 'mpg' || 'mpeg' => 'video/mpeg',
    'wmv' => 'video/x-ms-wmv',
    'm3u8' => 'application/vnd.apple.mpegurl',
    _ => 'video/mp4',
  };

  static String metadata({
    required String title,
    required Uri url,
    required String mime,
    String? artwork,
  }) =>
      '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
      'xmlns:dc="http://purl.org/dc/elements/1.1/" '
      'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
      '<item id="0" parentID="-1" restricted="1">'
      '<dc:title>${Soap.escape(title)}</dc:title>'
      '<upnp:class>object.item.videoItem</upnp:class>'
      '${artwork == null ? '' : '<upnp:albumArtURI>${Soap.escape(artwork)}</upnp:albumArtURI>'}'
      '<res protocolInfo="http-get:*:${Soap.escape(mime)}:*">${Soap.escape(url.toString())}</res>'
      '</item></DIDL-Lite>';

  /// 3725.5 → "1:02:05"
  static String formatTime(double seconds) {
    final t = seconds.isFinite && seconds > 0 ? seconds.floor() : 0;
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t ~/ 3600}:${two(t % 3600 ~/ 60)}:${two(t % 60)}';
  }

  /// "1:02:05" / "01:02:05.500" → seconds; null for "NOT_IMPLEMENTED" and the like.
  static double? parseTime(String? text) {
    final parts = (text ?? '').split(':');
    if (parts.length != 3) return null;
    final h = double.tryParse(parts[0]);
    final m = double.tryParse(parts[1]);
    final s = double.tryParse(parts[2]);
    return (h == null || m == null || s == null) ? null : h * 3600 + m * 60 + s;
  }
}

class Ssdp {
  const Ssdp._();
  static const address = '239.255.255.250';
  static const port = 1900;
  static const mediaRenderer = 'urn:schemas-upnp-org:device:MediaRenderer:1';

  static List<int> searchRequest({
    String target = mediaRenderer,
    int mx = 2,
  }) => utf8.encode(
    'M-SEARCH * HTTP/1.1\r\nHOST: $address:$port\r\nMAN: "ssdp:discover"\r\n'
    'MX: $mx\r\nST: $target\r\nUSER-AGENT: Aether/1.0 UPnP/1.1\r\n\r\n',
  );

  /// The LOCATION of a response, or null when it is not a usable answer from a LAN device.
  static Uri? parseLocation(String message) {
    final lines = message.split(RegExp(r'\r?\n'));
    if (lines.isEmpty ||
        !(lines.first.toUpperCase().startsWith('HTTP/1.1 200') ||
            lines.first.toUpperCase().startsWith('NOTIFY'))) {
      return null;
    }
    for (final l in lines.skip(1)) {
      final i = l.indexOf(':');
      if (i < 0 || l.substring(0, i).trim().toUpperCase() != 'LOCATION')
        continue;
      final u = Uri.tryParse(l.substring(i + 1).trim());
      if (u != null &&
          (u.scheme == 'http' || u.scheme == 'https') &&
          isLocalHost(u.host)) {
        return u;
      }
    }
    return null;
  }
}

enum UpnpTransportState { playing, paused, stopped, transitioning, other }

class UpnpPosition {
  const UpnpPosition(this.position, this.duration);
  final double? position;
  final double? duration;
}

class UpnpClient {
  UpnpClient({Dio? dio}) : _dio = dio ?? Dio() {
    _dio.options.connectTimeout = const Duration(seconds: 5);
    _dio.options.receiveTimeout = const Duration(seconds: 8);
    _dio.options.validateStatus = (_) => true;
  }

  final Dio _dio;

  Future<UpnpDevice> fetchDevice(Uri location) async {
    if (!isLocalHost(location.host)) {
      throw const UpnpException('Il dispositivo non è sulla rete locale.');
    }
    try {
      final r = await _dio.getUri<String>(
        location,
        options: Options(responseType: ResponseType.plain),
      );
      if ((r.statusCode ?? 0) ~/ 100 != 2) {
        throw UpnpException(
          'Il dispositivo ha risposto con errore ${r.statusCode}.',
        );
      }
      final device = UpnpDescriptionParser.parse(r.data ?? '', location);
      if (!device.isMediaRenderer) {
        throw const UpnpException('Il dispositivo non può riprodurre video.');
      }
      return device;
    } on DioException {
      throw const UpnpException('Il dispositivo non risponde.');
    }
  }

  Future<Map<String, String>> _call(
    UpnpService service,
    String action,
    List<(String, String)> args,
  ) async {
    try {
      final r = await _dio.postUri<String>(
        service.controlUrl,
        data: Soap.envelope(service.serviceType, action, args),
        options: Options(
          headers: Soap.headers(service.serviceType, action),
          responseType: ResponseType.plain,
        ),
      );
      final parsed = Soap.parseResponse(r.data ?? '');
      if (parsed.fault != null) {
        throw UpnpException(
          'Il televisore ha rifiutato il comando (${parsed.fault}).',
        );
      }
      if ((r.statusCode ?? 0) ~/ 100 != 2) {
        throw UpnpException(
          'Il televisore ha risposto con errore ${r.statusCode}.',
        );
      }
      return parsed.values;
    } on DioException {
      throw const UpnpException('Il televisore non risponde.');
    }
  }

  UpnpService _av(UpnpDevice d) {
    final s = d.avTransport;
    if (s == null)
      throw const UpnpException('Il dispositivo non può riprodurre video.');
    return s;
  }

  /// Gives the television the link and starts it. Only http(s) links: a local file or a header-protected stream cannot be
  /// fetched by the television.
  Future<void> cast(
    UpnpDevice d,
    Uri url,
    String title, {
    String? artwork,
  }) async {
    if (url.scheme != 'http' && url.scheme != 'https') {
      throw const UpnpException('Si possono trasmettere solo link http/https.');
    }
    final ext = url.pathSegments.isEmpty
        ? ''
        : (url.pathSegments.last.contains('.')
              ? url.pathSegments.last.split('.').last
              : '');
    await _call(_av(d), 'SetAVTransportURI', [
      ('InstanceID', '0'),
      ('CurrentURI', url.toString()),
      (
        'CurrentURIMetaData',
        Didl.metadata(
          title: title,
          url: url,
          mime: Didl.mimeType(ext),
          artwork: artwork,
        ),
      ),
    ]);
    await play(d);
  }

  Future<void> play(UpnpDevice d) =>
      _call(_av(d), 'Play', [('InstanceID', '0'), ('Speed', '1')]);
  Future<void> pause(UpnpDevice d) =>
      _call(_av(d), 'Pause', [('InstanceID', '0')]);
  Future<void> stop(UpnpDevice d) =>
      _call(_av(d), 'Stop', [('InstanceID', '0')]);
  Future<void> seek(UpnpDevice d, double seconds) => _call(_av(d), 'Seek', [
    ('InstanceID', '0'),
    ('Unit', 'REL_TIME'),
    ('Target', Didl.formatTime(seconds)),
  ]);

  Future<UpnpPosition> position(UpnpDevice d) async {
    final v = await _call(_av(d), 'GetPositionInfo', [('InstanceID', '0')]);
    return UpnpPosition(
      Didl.parseTime(v['RelTime']),
      Didl.parseTime(v['TrackDuration']),
    );
  }

  Future<UpnpTransportState> state(UpnpDevice d) async {
    final v = await _call(_av(d), 'GetTransportInfo', [('InstanceID', '0')]);
    return switch ((v['CurrentTransportState'] ?? '').toUpperCase()) {
      'PLAYING' => UpnpTransportState.playing,
      'PAUSED_PLAYBACK' || 'PAUSED_RECORDING' => UpnpTransportState.paused,
      'STOPPED' || 'NO_MEDIA_PRESENT' => UpnpTransportState.stopped,
      'TRANSITIONING' => UpnpTransportState.transitioning,
      _ => UpnpTransportState.other,
    };
  }

  Future<void> setVolume(UpnpDevice d, int percent) async {
    final s = d.renderingControl;
    if (s == null)
      throw const UpnpException(
        'Il televisore non permette di cambiare il volume.',
      );
    await _call(s, 'SetVolume', [
      ('InstanceID', '0'),
      ('Channel', 'Master'),
      ('DesiredVolume', '${percent.clamp(0, 100)}'),
    ]);
  }
}

/// Finds MediaRenderers with SSDP: a search is sent to the multicast group and the (unicast) answers are collected for a few
/// seconds. iOS only allows this to apps that hold Apple's multicast entitlement, which a sideloaded app cannot have, so
/// discovery is offered on Android only (see docs/LIMITATIONS.md).
class UpnpDiscovery {
  UpnpDiscovery({UpnpClient? client}) : _client = client ?? UpnpClient();
  final UpnpClient _client;

  static bool get supported => Platform.isAndroid;

  Stream<UpnpDevice> discover({
    Duration timeout = const Duration(seconds: 5),
  }) async* {
    if (!supported) return;
    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    final seen = <String>{};
    final found = StreamController<Uri>();
    final sub = socket.listen((e) {
      if (e != RawSocketEvent.read) return;
      final d = socket.receive();
      if (d == null) return;
      final loc = Ssdp.parseLocation(utf8.decode(d.data, allowMalformed: true));
      if (loc != null && seen.add(loc.toString())) found.add(loc);
    });
    // UDP can be lost: ask twice.
    for (var i = 0; i < 2; i++) {
      socket.send(
        Ssdp.searchRequest(),
        InternetAddress(Ssdp.address),
        Ssdp.port,
      );
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    Timer(timeout, () {
      sub.cancel();
      socket.close();
      found.close();
    });
    await for (final loc in found.stream) {
      try {
        yield await _client.fetchDevice(loc);
      } on UpnpException catch (e) {
        AppLog.instance.add('upnp', e.message);
      }
    }
  }
}
