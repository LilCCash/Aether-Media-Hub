import 'package:aether_flutter/features/settings/about_eggs.dart';
import 'package:flutter_test/flutter_test.dart';

Duration ms(int v) => Duration(milliseconds: v);

void main() {
  test('seven quick taps pop; a pause starts over; after a pop it rests', () {
    final t = TapTracker();
    for (var i = 1; i <= 6; i++) {
      expect(t.register(ms(i * 200)), TapOutcome.heat);
    }
    expect(t.register(ms(1400)), TapOutcome.pop);
    expect(t.pops, 1);
    // hammering during the rest does nothing
    expect(t.register(ms(1500)), TapOutcome.ignored);
    expect(t.register(ms(3000)), TapOutcome.ignored);
    // after the rest it counts from one again
    expect(t.register(ms(6000)), TapOutcome.heat);
    expect(t.taps, 1);
  });

  test('a pause longer than the window resets the count; the clock going back never freezes it', () {
    final t = TapTracker(threshold: 3);
    t.register(ms(100));
    t.register(ms(300));
    expect(t.register(ms(2500)), TapOutcome.heat); // too late: back to 1
    expect(t.taps, 1);
    expect(t.register(ms(50)), TapOutcome.heat); // clock went backwards
    expect(t.taps, 1);
    t.register(ms(200));
    expect(t.register(ms(400)), TapOutcome.pop);
  });
}
