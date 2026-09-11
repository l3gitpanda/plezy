import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/screens/video_player/apple_tv_transport_arbiter.dart';

void main() {
  late DateTime now;
  AppleTvTransportArbiter arbiter({Duration? window}) =>
      AppleTvTransportArbiter(now: () => now, window: window ?? AppleTvTransportArbiter.defaultWindow);

  setUp(() => now = DateTime(2026, 1, 1, 12));

  test('the first delivery of a press acts', () {
    expect(arbiter().accept(), isTrue);
  });

  test('either surface may be the one that speaks first', () {
    final bridgeFirst = arbiter();
    expect(bridgeFirst.accept(), isTrue, reason: 'native remote bridge');
    expect(bridgeFirst.accept(), isFalse, reason: 'OS media session, same press');

    now = now.add(const Duration(seconds: 5));
    final sessionFirst = arbiter();
    expect(sessionFirst.accept(), isTrue, reason: 'OS media session');
    expect(sessionFirst.accept(), isFalse, reason: 'native remote bridge, same press');
  });

  test('a press reported by both surfaces toggles once', () {
    final a = arbiter();
    expect(a.accept(), isTrue);
    // The bridge speaks at press-down and the plugin's tap recognizer at
    // press-up, so the second report trails by the length of the press.
    now = now.add(const Duration(milliseconds: 180));
    expect(a.accept(), isFalse);
  });

  test('a second press past the window is a second command', () {
    final a = arbiter();
    expect(a.accept(), isTrue);
    now = now.add(AppleTvTransportArbiter.defaultWindow);
    expect(a.accept(), isTrue);
  });

  test('the window is measured from the accepted delivery, not the refused one', () {
    final a = arbiter(window: const Duration(milliseconds: 400));
    expect(a.accept(), isTrue);

    now = now.add(const Duration(milliseconds: 300));
    expect(a.accept(), isFalse, reason: 'still the first press');

    // A refused delivery must not extend the window past the real press, or a
    // steady stream of duplicates would wedge the button shut.
    now = now.add(const Duration(milliseconds: 150));
    expect(a.accept(), isTrue, reason: '450ms after the accepted press');
  });

  test('a clock that steps backwards does not wedge the button shut', () {
    final a = arbiter();
    expect(a.accept(), isTrue);
    now = now.subtract(const Duration(hours: 1));
    expect(a.accept(), isTrue);
  });
}
