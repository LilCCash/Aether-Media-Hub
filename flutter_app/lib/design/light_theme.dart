import 'package:flutter/material.dart';

/// The light theme is the dark one seen through a colour filter that inverts the lightness and keeps the hues (invert, then
/// rotate the hue by 180°). The filter is its own inverse, so pictures and the player cancel it by applying it a second time.
const List<double> kLightMatrix = <double>[
  0.574, -1.430, -0.144, 0, 255, //
  -0.426, -0.430, -0.144, 0, 255, //
  -0.426, -1.430, 0.856, 0, 255, //
  0, 0, 0, 1, 0,
];

/// Whether the light theme is on (so images and the player know to undo the filter).
class LightScope extends InheritedWidget {
  const LightScope({super.key, required this.light, required super.child});
  final bool light;

  static bool of(BuildContext c) =>
      c.dependOnInheritedWidgetOfExactType<LightScope>()?.light ?? false;

  @override
  bool updateShouldNotify(LightScope old) => old.light != light;
}

/// Shows [child] with its true colours inside the light theme (photos, video); changes nothing in the dark one.
class LightCancel extends StatelessWidget {
  const LightCancel({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => LightScope.of(context)
      ? ColorFiltered(
          colorFilter: const ColorFilter.matrix(kLightMatrix),
          child: child,
        )
      : child;
}
