import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/screens/video_player/network_stream_tuning_policy.dart';

void main() {
  group('usesNetworkVodTuning', () {
    test('a remote file gets the reconnect tuning', () {
      expect(usesNetworkVodTuning(isLocalMedia: false, isTunerLive: false, isLiveStream: false), isTrue);
    });

    test('local media has no network to tune', () {
      expect(usesNetworkVodTuning(isLocalMedia: true, isTunerLive: false, isLiveStream: false), isFalse);
    });

    test('a tuner channel opts out', () {
      expect(usesNetworkVodTuning(isLocalMedia: false, isTunerLive: true, isLiveStream: false), isFalse);
    });

    // The regression: a YouTube livestream is not widget.isLive, so it used to
    // fall through to the VOD options. ffmpeg then read the whole HLS playlist,
    // took its normal end-of-body EOF for a dropped connection, and reconnected
    // on a growing backoff forever — the player buffering the entire time,
    // never handed the manifest it had already fetched.
    test('a live manifest opts out even though no tuner owns it', () {
      expect(usesNetworkVodTuning(isLocalMedia: false, isTunerLive: false, isLiveStream: true), isFalse);
    });
  });
}
