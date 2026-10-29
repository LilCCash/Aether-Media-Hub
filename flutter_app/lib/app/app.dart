import 'dart:io';

import 'package:pip_kit/pip_kit.dart';
import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/prefs_ext.dart';
import '../data/settings.dart';
import '../design/palettes.dart';
import '../design/tokens.dart';
import '../design/light_theme.dart';
import '../design/widgets.dart' show PosterImage;
import 'hooks.dart';
import 'providers.dart';
import 'router.dart';
import '../features/shell/shell.dart';

class AetherApp extends ConsumerWidget {
  const AetherApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(settingsProvider);
    ref.watch(appHooksProvider);
    // Trakt / Simkl read the current settings (scrobbling, which lists to sync) through this.
    ref.read(servicesProvider).sync.settings = () => ref.read(settingsProvider);
    PosterImage.overrides = s.alternatePosters ? s.posterOverrides : const {};
    final palette = AetherPalette.byName(s.palette);
    final accent = palette.primary ?? colorFromHex(s.accentHex);
    final scaffold = s.amoled
        ? Colors.black
        : (s.customBackgroundHex == null
              ? AetherTokens.ink
              : colorFromHex(s.customBackgroundHex!));
    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: Brightness.dark,
      surface: scaffold,
    ).copyWith(primary: accent, onSurface: AetherTokens.textPrimary);
    final theme = ThemeData(
      useMaterial3: true,
      visualDensity: s.compact ? VisualDensity.compact : VisualDensity.standard,
      fontFamily: switch (s.uiFont) {
        'serif' => 'serif',
        'mono' => 'monospace',
        _ => null,
      },
      colorScheme: scheme,
      scaffoldBackgroundColor: scaffold,
      textTheme: AetherTokens.textTheme(
        AetherTokens.textPrimary,
        titleFamily: TitleFont.byName(s.titleFont).family,
      ),
      splashFactory: NoSplash.splashFactory,
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      dividerColor: AetherTokens.hairline,
      sliderTheme: SliderThemeData(
        activeTrackColor: accent,
        inactiveTrackColor: Colors.white24,
        thumbColor: Colors.white,
        trackHeight: 3,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.all(Colors.white),
        trackColor: WidgetStateProperty.resolveWith(
          (st) => st.contains(WidgetState.selected) ? accent : Colors.white24,
        ),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: CupertinoPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        },
      ),
    );
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        statusBarBrightness: Brightness.dark,
      ),
    );
    return MaterialApp.router(
      title: 'Aether',
      debugShowCheckedModeBanner: false,
      theme: theme,
      darkTheme: theme,
      themeMode: ThemeMode.dark,
      routerConfig: ref.watch(routerProvider),
      builder: (context, child) {
        final light =
            s.themeMode == 'light' ||
            (s.themeMode == 'auto' &&
                MediaQuery.platformBrightnessOf(context) == Brightness.light);
        final app = _themed(context, ref, child, s, accent, palette);
        return LightScope(
          light: light,
          child: light
              ? AnnotatedRegion<SystemUiOverlayStyle>(
                  value: SystemUiOverlayStyle.dark,
                  child: ColorFiltered(
                    colorFilter: const ColorFilter.matrix(kLightMatrix),
                    child: app,
                  ),
                )
              : app,
        );
      },
    );
  }

  Widget _themed(
    BuildContext context,
    WidgetRef ref,
    Widget? child,
    AppSettings s,
    Color accent,
    AetherPalette palette,
  ) {
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(
        textScaler: TextScaler.linear(
          MediaQuery.of(context).textScaler.scale(1) * s.textScale,
        ),
      ),
      child: AetherLook(
        accent: accent,
        glassIntensity: s.glassIntensity,
        reduceEffects: s.reduceEffects,
        amoled: s.amoled,
        cinematic: s.cinematic,
        secondary: palette.secondary,
        corner: switch (s.cornerStyle) {
          'sharp' => 4,
          'rounded' => 20,
          'bubble' => 28,
          _ => 14,
        },
        chrome: s.cardChrome,
        posterScale: switch (s.posterSize) {
          'small' => 0.85,
          'large' => 1.2,
          _ => 1.0,
        },
        posterRatings: s.posterRatings,
        backdropStyle: s.backdropStyle,
        backdropIntensity: s.backdropIntensity,
        halos: s.halos,
        customBackground: s.customBackgroundHex == null
            ? null
            : colorFromHex(s.customBackgroundHex!),
        animations: s.animations,
        liquid: s.liquidGlass,
        compact: s.compact,
        child: _pipHost(
          DockOverlay(
            router: ref.read(routerProvider),
            child: child ?? const SizedBox(),
          ),
        ),
      ),
    );
  }
}

/// iPhone: the host Picture in Picture needs above the app (Android uses its own window).
Widget _pipHost(Widget child) => Platform.isIOS ? PipHost(child: child) : child;
