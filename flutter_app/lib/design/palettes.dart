import 'dart:ui';

/// The colour palettes of the iOS app: a primary and a secondary wash. «Aether» keeps the accent chosen in the settings.
enum AetherPalette {
  aether('Aether', '✨', null, null),
  sunset('Tramonto', '🌅', 0xFFFF6B4A, 0xFFB03CFF),
  ocean('Oceano', '🌊', 0xFF1FB6FF, 0xFF12D6B0),
  forest('Foresta', '🌲', 0xFF2FBF71, 0xFFC8E04A),
  candy('Zucchero filato', '🍬', 0xFFFF6FB5, 0xFF7AD7FF),
  midnight('Mezzanotte', '🌌', 0xFF4C3FFF, 0xFF9B5CFF),
  cinema('Sala buia', '🎞️', 0xFFD9A441, 0xFF7A1F2B),
  popcorn('Popcorn', '🍿', 0xFFFFC83D, 0xFFE5383B);

  const AetherPalette(this.title, this.emoji, this._primary, this._secondary);
  final String title;
  final String emoji;
  final int? _primary;
  final int? _secondary;

  Color? get primary => _primary == null ? null : Color(_primary);
  Color? get secondary => _secondary == null ? null : Color(_secondary);

  static AetherPalette byName(String? name) => AetherPalette.values.firstWhere(
    (p) => p.name == name,
    orElse: () => AetherPalette.aether,
  );
}

/// Fonts offered for titles. Only families every phone already has: nothing is downloaded.
enum TitleFont {
  standard('Standard', null),
  serif('Con grazie', 'serif'),
  mono('Monospaziato', 'monospace');

  const TitleFont(this.title, this.family);
  final String title;
  final String? family;

  static TitleFont byName(String? name) => TitleFont.values.firstWhere(
    (p) => p.name == name,
    orElse: () => TitleFont.standard,
  );
}
