import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:os_media_controls/os_media_controls.dart';
import 'package:plezy/mpv/mpv.dart';
import 'package:plezy/providers/playback_state_provider.dart';
import 'package:plezy/screens/video_player_screen.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:provider/provider.dart';

import '../../test_helpers/media_items.dart';
import '../../test_helpers/mock_player_channels.dart';
import '../../test_helpers/prefs.dart';

/// The Siri Remote's Play/Pause button reaches the app through one of two
/// surfaces — the responder chain, bridged natively from `pressesBegan`, or
/// `MPRemoteCommandCenter`, which arrives on the OS media-session stream —
/// and tvOS picks between them by whether the audio session is active. The
/// screen used to honour the bridge and drop the media session outright, so
/// the direction tvOS routed through the command centre did nothing: the
/// remote could pause and then refuse to resume.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    await SettingsService.getInstance();
    TvDetectionService.debugSetAppleTVOverride(true);
  });

  tearDown(() => TvDetectionService.debugSetAppleTVOverride(null));

  Future<void> withScreen(
    WidgetTester tester,
    _TransportRecordingPlayer player,
    Future<void> Function(VideoPlayerScreenState state) body,
  ) async {
    await withMockPlayerChannels(
      methodChannelName: 'com.plezy/mpv_player',
      eventChannelName: 'com.plezy/mpv_player/events',
      testBody: () async {
        final screenKey = GlobalKey<VideoPlayerScreenState>();
        await tester.pumpWidget(_screen(screenKey));
        screenKey.currentState!.player = player;
        screenKey.currentState!.debugMarkPlayerInitializedForTesting();
        await body(screenKey.currentState!);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('a press tvOS routes through the OS media session resumes playback', (tester) async {
    final player = _TransportRecordingPlayer(playing: false);

    await withScreen(tester, player, (state) async {
      state.debugHandleMediaControlEventForTesting(const TogglePlayPauseEvent());
      await tester.pump();

      expect(player.commands, ['play'], reason: 'the paused remote press must reach the player, not be dropped');
    });
  });

  testWidgets('a press tvOS routes through the OS media session pauses playback', (tester) async {
    final player = _TransportRecordingPlayer(playing: true);

    await withScreen(tester, player, (state) async {
      state.debugHandleMediaControlEventForTesting(const TogglePlayPauseEvent());
      await tester.pump();

      expect(player.commands, ['pause']);
    });
  });

  testWidgets('one press reported by both surfaces toggles once', (tester) async {
    final player = _TransportRecordingPlayer(playing: false);

    await withScreen(tester, player, (state) async {
      // The native bridge speaks at press-down, the media session at
      // press-up. Two reports, one button press.
      await state.debugHandleAppleTvRemotePlayPauseForTesting();
      state.debugHandleMediaControlEventForTesting(const TogglePlayPauseEvent());
      await tester.pump();

      expect(player.commands, ['play'], reason: 'toggling twice would leave the video exactly as it was');
    });
  });

  testWidgets('the bridge still drives the transport when it is the surface that speaks', (tester) async {
    final player = _TransportRecordingPlayer(playing: true);

    await withScreen(tester, player, (state) async {
      await state.debugHandleAppleTvRemotePlayPauseForTesting();
      await tester.pump();

      expect(player.commands, ['pause']);
    });
  });
}

Widget _screen(GlobalKey<VideoPlayerScreenState> key) {
  return ChangeNotifierProvider(
    create: (_) => PlaybackStateProvider(),
    child: MaterialApp(
      home: VideoPlayerScreen(
        key: key,
        metadata: testMediaItem(title: 'Apple TV play/pause surfaces'),
        isOffline: true,
      ),
    ),
  );
}

class _TransportRecordingPlayer implements Player {
  _TransportRecordingPlayer({required bool playing})
    : _state = PlayerState(
        playing: playing,
        position: const Duration(minutes: 2),
        duration: const Duration(minutes: 45),
        seekable: true,
      );

  PlayerState _state;
  final List<String> commands = [];

  @override
  PlayerState get state => _state;

  @override
  Future<void> play() async {
    commands.add('play');
    _state = _state.copyWith(playing: true);
  }

  @override
  Future<void> pause() async {
    commands.add('pause');
    _state = _state.copyWith(playing: false);
  }

  @override
  Future<void> playOrPause() async => _state.playing ? pause() : play();

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> dispose({bool preserveDisplayMode = false}) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
