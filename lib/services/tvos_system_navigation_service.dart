import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../utils/platform_detector.dart';

class TvosSystemNavigationService {
  static const BasicMessageChannel<Object?> _channel = BasicMessageChannel<Object?>(
    'flutter/tvos_system_navigation',
    JSONMessageCodec(),
  );

  // What main_screen asked for (enabled only at root — see
  // `_updateTvosMenuPassthrough`).
  static bool? _appDesired;
  // While the native tvOS keyboard is up, Menu must reach the system so it
  // can dismiss the keyboard — the engine otherwise synthesizes a Flutter
  // back event that the keyboard session guards swallow. This overrides
  // `_appDesired` for the duration of the keyboard session.
  static bool _keyboardSessionActive = false;
  static bool? _lastSentEffective;

  static Future<void> setMenuPassthroughEnabled(bool enabled) async {
    _appDesired = enabled;
    await _sync();
  }

  /// Forces Menu passthrough on for the duration of a native tvOS keyboard
  /// session, regardless of what [setMenuPassthroughEnabled] last requested.
  static Future<void> setKeyboardSessionActive(bool active) async {
    _keyboardSessionActive = active;
    await _sync();
  }

  static Future<void> _sync() async {
    if (!PlatformDetector.isAppleTV()) return;
    final effective = _keyboardSessionActive || (_appDesired ?? false);
    if (_lastSentEffective == effective) return;

    _lastSentEffective = effective;
    await _channel.send({'menuPassthroughEnabled': effective});
  }

  @visibleForTesting
  static void resetForTesting() {
    _appDesired = null;
    _keyboardSessionActive = false;
    _lastSentEffective = null;
  }
}
