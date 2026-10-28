import 'dart:ui';

import '../../core/util/lenient.dart';

/// The accent colour of Theater Mode (same five as the iOS app).
enum TheaterPalette {
  gold('Oro', 0xFFFFD173),
  velvet('Rosso velluto', 0xFFED4D57),
  midnight('Blu notte', 0xFF73A6FF),
  emerald('Smeraldo', 0xFF59DB9E),
  silver('Argento', 0xFFD9E0ED);

  const TheaterPalette(this.title, this._color);
  final String title;
  final int _color;
  Color get color => Color(_color);
}

/// What the viewer chose for Theater Mode (they matter only there). Stored inside the app settings.
class TheaterPrefs {
  const TheaterPrefs({
    this.palette = 0,
    this.background = 1,
    this.cardSize = 1,
    this.portraitCards = false,
    this.titles = true,
    this.details = true,
    this.railLabels = false,
    this.sprockets = false,
    this.intro = true,
    this.sound = true,
    this.corners = 1,
    this.border = 1,
    this.glow = true,
    this.rowStyle = 0,
  });

  final int palette; // TheaterPalette index
  final int background; // 0 pure black, 1 gradient, 2 beam of light
  final int cardSize; // 0 small, 1 medium, 2 large
  final bool portraitCards;
  final bool titles;
  final bool details;
  final bool railLabels;
  final bool sprockets;
  final bool intro;
  final bool sound;
  final int corners; // 0 sharp, 1 soft, 2 round
  final int border; // 0 none, 1 thin, 2 accent
  final bool glow; // light around the selected card
  final int rowStyle; // row titles: 0 normal, 1 serif, 2 small caps

  double get radius => const [4.0, 14.0, 22.0][corners];

  /// Version of the Theater interface (not of the app).
  static const version = '0.1.0';

  TheaterPalette get accent => TheaterPalette.values[palette];

  /// Height of a row of cards, and the width of one card for the chosen shape.
  double get rowHeight => const [92.0, 112.0, 140.0][cardSize];
  double get cardWidth =>
      portraitCards ? rowHeight * 0.68 : rowHeight * (190 / 112);

  TheaterPrefs copyWith({
    int? palette,
    int? background,
    int? cardSize,
    bool? portraitCards,
    bool? titles,
    bool? details,
    bool? railLabels,
    bool? sprockets,
    bool? intro,
    bool? sound,
    int? corners,
    int? border,
    bool? glow,
    int? rowStyle,
  }) => TheaterPrefs(
    palette: palette ?? this.palette,
    background: background ?? this.background,
    cardSize: cardSize ?? this.cardSize,
    portraitCards: portraitCards ?? this.portraitCards,
    titles: titles ?? this.titles,
    details: details ?? this.details,
    railLabels: railLabels ?? this.railLabels,
    sprockets: sprockets ?? this.sprockets,
    intro: intro ?? this.intro,
    sound: sound ?? this.sound,
    corners: corners ?? this.corners,
    border: border ?? this.border,
    glow: glow ?? this.glow,
    rowStyle: rowStyle ?? this.rowStyle,
  );

  Map<String, Object?> toJson() => {
    'palette': palette,
    'background': background,
    'cardSize': cardSize,
    'portraitCards': portraitCards,
    'titles': titles,
    'details': details,
    'railLabels': railLabels,
    'sprockets': sprockets,
    'intro': intro,
    'sound': sound,
    'corners': corners,
    'border': border,
    'glow': glow,
    'rowStyle': rowStyle,
  };

  factory TheaterPrefs.fromJson(Object? raw) {
    final m = asMap(raw) ?? const {};
    const d = TheaterPrefs();
    int pick(String k, int max, int fallback) {
      final v = asInt(m[k]);
      return (v == null || v < 0 || v > max) ? fallback : v;
    }

    return TheaterPrefs(
      palette: pick('palette', TheaterPalette.values.length - 1, d.palette),
      background: pick('background', 2, d.background),
      cardSize: pick('cardSize', 2, d.cardSize),
      portraitCards: asBool(m['portraitCards'], fallback: d.portraitCards),
      titles: asBool(m['titles'], fallback: d.titles),
      details: asBool(m['details'], fallback: d.details),
      railLabels: asBool(m['railLabels'], fallback: d.railLabels),
      sprockets: asBool(m['sprockets'], fallback: d.sprockets),
      intro: asBool(m['intro'], fallback: d.intro),
      sound: asBool(m['sound'], fallback: d.sound),
      corners: pick('corners', 2, d.corners),
      border: pick('border', 2, d.border),
      glow: asBool(m['glow'], fallback: d.glow),
      rowStyle: pick('rowStyle', 2, d.rowStyle),
    );
  }
}
