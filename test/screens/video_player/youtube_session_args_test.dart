import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/models/yattee/yattee_video.dart';
import 'package:plezy/models/yattee/youtube_media_item.dart';
import 'package:plezy/screens/video_player/youtube_session_args.dart';
import 'package:plezy/services/playback_context.dart';
import 'package:plezy/services/yattee/yattee_stream_selector.dart';

const _summary = YatteeVideoSummary(
  videoId: 'dQw4w9WgXcQ',
  title: 'Live now',
  author: 'a',
  authorId: 'UC',
  lengthSeconds: 0,
  liveNow: true,
);

void main() {
  group('YouTubeSessionArgs', () {
    test('a live selection reaches the player as a live playback result', () {
      final args = YouTubeSessionArgs(
        video: const YatteeVideo(summary: _summary, hlsUrl: 'https://yattee.example/relay?token=abc'),
        selection: const YatteeStreamSelection.liveHls('https://yattee.example/relay?token=abc'),
      );

      expect(args.isLive, isTrue);

      final context = args.toPlaybackContext(_metadata());

      expect(context.result.isLiveStream, isTrue);
      expect(context.result.videoUrl, 'https://yattee.example/relay?token=abc');
      // A manifest carries its own audio; nothing to side-load.
      expect(context.result.externalAudioUrl, isNull);
      // Still a plain remote URL with no server to report progress to.
      expect(context.sourceKind, PlaybackSourceKind.remoteDirect);
      expect(context.reportingMode, PlaybackReportingMode.disabled);
    });

    test('an ordinary upload stays a non-live result with its side-loaded audio', () {
      final args = YouTubeSessionArgs(
        video: const YatteeVideo(summary: _summary),
        selection: const YatteeStreamSelection(
          videoUrl: 'https://yattee.example/relay?itag=137',
          audioUrl: 'https://yattee.example/relay?itag=140',
          isAdaptive: true,
          height: 1080,
        ),
      );

      expect(args.isLive, isFalse);

      final context = args.toPlaybackContext(_metadata());

      expect(context.result.isLiveStream, isFalse);
      expect(context.result.externalAudioUrl, 'https://yattee.example/relay?itag=140');
    });
  });
}

MediaItem _metadata() => YouTubeMediaItems.fromSummary(_summary);
