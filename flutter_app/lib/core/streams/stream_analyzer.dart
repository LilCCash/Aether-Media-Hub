import '../model/stream.dart';

enum VideoQuality { unknown, p480, p720, p1080, p1440, p2160 }

enum HdrFormat { dolbyVision, hdr10Plus, hdr10, hlg }

extension on VideoQuality {
  String get label => switch (this) {
    VideoQuality.unknown => '',
    VideoQuality.p480 => '480p',
    VideoQuality.p720 => '720p',
    VideoQuality.p1080 => '1080p',
    VideoQuality.p1440 => '1440p',
    VideoQuality.p2160 => '4K',
  };
}

extension HdrLabel on HdrFormat {
  String get label => switch (this) {
    HdrFormat.dolbyVision => 'Dolby Vision',
    HdrFormat.hdr10Plus => 'HDR10+',
    HdrFormat.hdr10 => 'HDR10',
    HdrFormat.hlg => 'HLG',
  };
}

extension QualityLabel on VideoQuality {
  String get text => label;
}

/// What the name of a source says about it. These are claims in the name of the file, not measurements: the player is the
/// only one that knows the real codec, so the UI marks HDR as "dal nome".
class StreamInfo {
  const StreamInfo({
    required this.quality,
    this.codec,
    this.hdr = const [],
    this.audio,
    this.languages = const [],
    this.sizeBytes,
    this.format,
    this.release,
  });

  final VideoQuality quality;
  final String? codec;
  final List<HdrFormat> hdr;
  final String? audio;
  final List<String> languages;
  final int? sizeBytes;
  final String? format;
  final String? release;

  String? get sizeLabel {
    final size = sizeBytes;
    if (size == null || size <= 0) return null;
    final gb = size / 1073741824;
    return gb >= 1
        ? '${gb.toStringAsFixed(1)} GB'
        : '${(size / 1048576).round()} MB';
  }
}

class StreamAnalyzer {
  const StreamAnalyzer._();

  static StreamInfo analyze(AddonStream stream) {
    final text = stream.searchText;
    final lower = text.toLowerCase();
    return StreamInfo(
      quality: _quality(lower),
      codec: _codec(lower),
      hdr: _hdr(lower),
      audio: _audio(lower),
      languages: _languages(text),
      sizeBytes: stream.videoSize ?? _size(text),
      format: _format(stream, lower),
      release: _release(lower),
    );
  }

  static bool _has(String text, String pattern) => RegExp(
    '(?<![a-z0-9])(?:$pattern)(?![a-z0-9])',
    caseSensitive: false,
  ).hasMatch(text);

  static VideoQuality _quality(String t) {
    if (_has(t, r'2160p?|4k|uhd')) return VideoQuality.p2160;
    if (_has(t, r'1440p?|2k')) return VideoQuality.p1440;
    if (_has(t, r'1080p?|fhd|fullhd')) return VideoQuality.p1080;
    if (_has(t, r'720p?|hd')) return VideoQuality.p720;
    if (_has(t, r'480p?|576p?|sd|dvdrip')) return VideoQuality.p480;
    return VideoQuality.unknown;
  }

  static String? _codec(String t) {
    if (_has(t, r'av1')) return 'AV1';
    if (_has(t, r'hevc|x265|h\.?265')) return 'HEVC';
    if (_has(t, r'avc|x264|h\.?264')) return 'H.264';
    if (_has(t, r'vp9')) return 'VP9';
    if (_has(t, r'xvid|divx')) return 'MPEG-4';
    return null;
  }

  static List<HdrFormat> _hdr(String t) {
    final result = <HdrFormat>[];
    if (_has(t, r'dolby[ .\-]?vision|dovi|dv'))
      result.add(HdrFormat.dolbyVision);
    if (_has(t, r'hdr10\+|hdr10plus')) result.add(HdrFormat.hdr10Plus);
    if (RegExp(
      r'hdr10(?!\+|plus)|(?<![a-z0-9])hdr(?![a-z0-9])',
      caseSensitive: false,
    ).hasMatch(t))
      result.add(HdrFormat.hdr10);
    if (_has(t, r'hlg')) result.add(HdrFormat.hlg);
    return result;
  }

  static String? _audio(String t) {
    if (_has(t, r'atmos')) return 'Dolby Atmos';
    if (_has(t, r'truehd')) return 'TrueHD';
    if (_has(t, r'dts[\-. ]?hd(?:[\-. ]?ma)?|dts[\-. ]?x')) return 'DTS-HD';
    if (_has(t, r'dts')) return 'DTS';
    if (_has(t, r'e[\-. ]?ac[\-. ]?3|dd\+|ddp(?:5[. ]1)?'))
      return 'Dolby Digital+';
    if (_has(t, r'ac[\-. ]?3|dd5[. ]1|dolby digital')) return 'Dolby Digital';
    if (_has(t, r'aac')) return 'AAC';
    if (_has(t, r'opus')) return 'Opus';
    return null;
  }

  static final Map<String, RegExp> _langs = {
    'Italiano': RegExp(
      r'(?<![a-z0-9])(ita|italian[oa]?|🇮🇹)(?![a-z0-9])',
      caseSensitive: false,
    ),
    'Inglese': RegExp(
      r'(?<![a-z0-9])(eng|english|🇬🇧|🇺🇸)(?![a-z0-9])',
      caseSensitive: false,
    ),
    'Francese': RegExp(
      r'(?<![a-z0-9])(fre|fra|french|vff|🇫🇷)(?![a-z0-9])',
      caseSensitive: false,
    ),
    'Spagnolo': RegExp(
      r'(?<![a-z0-9])(spa|spanish|esp|🇪🇸)(?![a-z0-9])',
      caseSensitive: false,
    ),
    'Tedesco': RegExp(
      r'(?<![a-z0-9])(ger|deu|german|🇩🇪)(?![a-z0-9])',
      caseSensitive: false,
    ),
    'Multi': RegExp(
      r'(?<![a-z0-9])(multi|multilang)(?![a-z0-9])',
      caseSensitive: false,
    ),
  };

  static List<String> _languages(String text) => [
    for (final e in _langs.entries)
      if (e.value.hasMatch(text)) e.key,
  ];

  static int? _size(String text) {
    final m = RegExp(
      r'(\d+(?:[.,]\d+)?)\s*(GB|GiB|MB|MiB)',
      caseSensitive: false,
    ).firstMatch(text);
    if (m == null) return null;
    final value = double.tryParse(m.group(1)!.replaceAll(',', '.'));
    if (value == null) return null;
    final unit = m.group(2)!.toLowerCase();
    return (value * (unit.startsWith('g') ? 1073741824 : 1048576)).round();
  }

  static String? _format(AddonStream stream, String lower) {
    final names = [
      stream.filename,
      stream.url,
    ].whereType<String>().join(' ').toLowerCase();
    for (final ext in [
      'mkv',
      'mp4',
      'avi',
      'webm',
      'ts',
      'm3u8',
      'mov',
      'wmv',
    ]) {
      if (RegExp('\\.$ext(?:\\?|\$|\\s|/)').hasMatch(names) ||
          RegExp('(?<![a-z0-9])$ext(?![a-z0-9])').hasMatch(lower))
        return ext.toUpperCase();
    }
    return null;
  }

  static String? _release(String t) {
    if (_has(t, r'remux')) return 'Remux';
    if (_has(t, r'blu[\-. ]?ray|bdrip|brrip')) return 'BluRay';
    if (_has(t, r'web[\-. ]?dl')) return 'WEB-DL';
    if (_has(t, r'webrip')) return 'WEBRip';
    if (_has(t, r'hdtv')) return 'HDTV';
    if (_has(t, r'cam|hdcam|telesync|ts')) return 'CAM';
    return null;
  }
}

/// Where a source can be played from.
enum StreamPlayability { direct, needsDebrid, external, unsupported }

class RankedStream {
  RankedStream(this.stream, this.info, this.playability, this.score);
  final AddonStream stream;
  final StreamInfo info;
  final StreamPlayability playability;
  final int score;
  bool get isPlayableHere => playability == StreamPlayability.direct;
}

class StreamRanker {
  const StreamRanker({this.preferredLanguage, this.debridConfigured = false});

  /// "Italiano", "Inglese"... as the analyzer names them.
  final String? preferredLanguage;
  final bool debridConfigured;

  StreamPlayability playability(AddonStream s) {
    if (s.isDirect) return StreamPlayability.direct;
    if (s.isTorrent) return StreamPlayability.needsDebrid;
    if (s.externalUrl != null || s.ytId != null)
      return StreamPlayability.external;
    return StreamPlayability.unsupported;
  }

  /// Best first: playable here, then quality, release kind, preferred language, size sanity. Stable for ties (addon priority).
  List<RankedStream> rank(List<AddonStream> streams) {
    final ranked = <RankedStream>[];
    for (final s in streams) {
      final info = StreamAnalyzer.analyze(s);
      final play = playability(s);
      var score = info.quality.index * 100;
      score += switch (info.release) {
        'Remux' => 30,
        'BluRay' => 25,
        'WEB-DL' => 20,
        'WEBRip' => 12,
        'HDTV' => 5,
        'CAM' => -300,
        _ => 0,
      };
      if (info.hdr.isNotEmpty) score += 10;
      if (preferredLanguage != null &&
          (info.languages.contains(preferredLanguage) ||
              info.languages.contains('Multi')))
        score += 60;
      if (play == StreamPlayability.direct) score += 1000;
      if (play == StreamPlayability.needsDebrid)
        score += debridConfigured ? 800 : -500;
      if (play == StreamPlayability.external ||
          play == StreamPlayability.unsupported)
        score -= 1000;
      ranked.add(RankedStream(s, info, play, score));
    }
    final indexed = [for (var i = 0; i < ranked.length; i++) (i, ranked[i])];
    indexed.sort((a, b) {
      final c = b.$2.score.compareTo(a.$2.score);
      return c != 0 ? c : a.$1.compareTo(b.$1);
    });
    return indexed.map((e) => e.$2).toList();
  }
}
