/// Collapses the two surfaces tvOS uses to deliver a single Play/Pause press.
///
/// The Siri Remote's Play/Pause button reaches the app through one of two
/// channels, and tvOS picks between them by whether the app's audio session is
/// currently active — which is to say, by whether the video is playing:
///
///  - the responder chain, as a `UIPress` of type `.playPause`, which
///    `PlezyFlutterViewController.pressesBegan` bridges onto the
///    `flutter/gamepadtouchevent` channel; and
///  - `MPRemoteCommandCenter`, whose play/pause/toggle commands the
///    `os_media_controls` plugin normalises into one `TogglePlayPauseEvent`
///    (it also installs a `.playPause` tap recognizer of its own and folds
///    that into the same event).
///
/// An active session steals the press from the responder chain, so the two
/// directions of the same button do not arrive the same way: the press that
/// pauses lands on one channel and the press that resumes lands on the other.
/// Honouring only one channel leaves the other direction dead — the button
/// pauses and then refuses to resume — while honouring both without a gate
/// toggles twice for one press, which reads as the same dead button.
///
/// Both channels are therefore honoured, and this collapses whichever pair
/// arrives for one physical press. Collapsing a genuine human double-press
/// inside the window is the safe way to be wrong: two toggles net to no change
/// anyway, so the viewer sees one press honoured rather than none.
class AppleTvTransportArbiter {
  /// How far apart the two reports of one press can land.
  ///
  /// The native bridge speaks at press-down and the plugin's tap recognizer at
  /// press-up, so the gap is the length of the press itself plus two platform
  /// channel hops. Wide enough for a deliberate press, short enough that two
  /// separate presses stay two commands.
  static const Duration defaultWindow = Duration(milliseconds: 400);

  AppleTvTransportArbiter({DateTime Function()? now, this.window = defaultWindow}) : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  final Duration window;

  DateTime? _lastAccepted;

  /// Whether this delivery is the one that acts on the press.
  ///
  /// The first delivery wins; a second one inside [window] is the other
  /// channel reporting the same press and is refused.
  bool accept() {
    final now = _now();
    final last = _lastAccepted;
    // `isBefore` guards a clock that stepped backwards: a negative difference
    // is not a duplicate, it is a fresh press on a rewound clock.
    if (last != null && !now.isBefore(last) && now.difference(last) < window) {
      return false;
    }
    _lastAccepted = now;
    return true;
  }
}
