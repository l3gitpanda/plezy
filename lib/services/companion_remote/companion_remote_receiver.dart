import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../models/companion_remote/remote_command.dart';
import '../../utils/app_logger.dart';
import '../../utils/key_event_simulator.dart';

class CompanionRemoteReceiver {
  CompanionRemoteReceiver._();

  static CompanionRemoteReceiver? _instance;

  static CompanionRemoteReceiver get instance {
    _instance ??= CompanionRemoteReceiver._();
    return _instance!;
  }

  /// Called on any remote input so InputModeTracker can switch to keyboard mode.
  /// Same pattern as [GamepadService.onGamepadInput].
  static VoidCallback? onRemoteInput;

  /// Owners prevent a disposed screen from clearing callbacks installed by a
  /// replacement screen later in the same frame.
  Object? navigationOwner;
  Object? playerOwner;
  VoidCallback? playerHomeFallback;

  VoidCallback? onTabNext;
  VoidCallback? onTabPrevious;
  VoidCallback? onTabDiscover;
  VoidCallback? onTabLibraries;
  VoidCallback? onTabSearch;
  VoidCallback? onTabDownloads;
  VoidCallback? onTabSettings;
  VoidCallback? onTabExplore;
  VoidCallback? onHome;
  void Function(String? query)? onSearchAction;
  void Function(String? query)? onExploreSearch;
  VoidCallback? onPlayPause;
  void Function(Map<String, dynamic>? data)? onPlayMedia;
  VoidCallback? onNextTrack;
  VoidCallback? onPreviousTrack;
  VoidCallback? onNextChapter;
  VoidCallback? onPreviousChapter;
  VoidCallback? onStop;
  VoidCallback? onSeekForward;
  VoidCallback? onSeekBackward;
  VoidCallback? onVolumeUp;
  VoidCallback? onVolumeDown;
  VoidCallback? onVolumeMute;
  VoidCallback? onSubtitles;
  VoidCallback? onAudioTracks;
  VoidCallback? onFullscreen;

  void handleCommand(RemoteCommand command, BuildContext? _) {
    appLogger.d('CompanionRemoteReceiver: Handling command: ${command.type}');

    // Switch to keyboard mode so focus visuals render
    onRemoteInput?.call();
    _setTraditionalFocusHighlight();
    scheduleFrameIfIdle();

    switch (command.type) {
      case RemoteCommandType.dpadUp:
        simulateKeyPress(LogicalKeyboardKey.arrowUp);
      case RemoteCommandType.dpadDown:
        simulateKeyPress(LogicalKeyboardKey.arrowDown);
      case RemoteCommandType.dpadLeft:
        simulateKeyPress(LogicalKeyboardKey.arrowLeft);
      case RemoteCommandType.dpadRight:
        simulateKeyPress(LogicalKeyboardKey.arrowRight);
      case RemoteCommandType.select:
        simulateKeyPress(LogicalKeyboardKey.enter);
      case RemoteCommandType.back:
        simulateKeyPress(LogicalKeyboardKey.gameButtonB);
      case RemoteCommandType.contextMenu:
        simulateKeyPress(LogicalKeyboardKey.contextMenu);

      case RemoteCommandType.play:
      case RemoteCommandType.pause:
      case RemoteCommandType.playPause:
        // The simulated space bar only reaches focus-tree handlers, not the
        // player's HardwareKeyboard shortcut, so the player registers a real
        // callback; the key press remains as an app-level fallback.
        if (onPlayPause != null) {
          onPlayPause!.call();
        } else {
          simulateKeyPress(LogicalKeyboardKey.space);
        }
      case RemoteCommandType.seekForward:
        onSeekForward?.call();
      case RemoteCommandType.seekBackward:
        onSeekBackward?.call();

      case RemoteCommandType.volumeUp:
        onVolumeUp?.call();
      case RemoteCommandType.volumeDown:
        onVolumeDown?.call();
      case RemoteCommandType.volumeMute:
        onVolumeMute?.call();

      case RemoteCommandType.tabNext:
        onTabNext?.call();
      case RemoteCommandType.tabPrevious:
        onTabPrevious?.call();
      case RemoteCommandType.tabDiscover:
        onTabDiscover?.call();
      case RemoteCommandType.tabLibraries:
        onTabLibraries?.call();
      case RemoteCommandType.tabSearch:
        onTabSearch?.call();
      case RemoteCommandType.tabDownloads:
        onTabDownloads?.call();
      case RemoteCommandType.tabSettings:
        onTabSettings?.call();
      case RemoteCommandType.tabExplore:
        onTabExplore?.call();

      case RemoteCommandType.home:
        onHome?.call();
      case RemoteCommandType.search:
        final query = command.data?['query'] as String?;
        onSearchAction?.call(query);
      case RemoteCommandType.exploreSearch:
        final query = command.data?['query'] as String?;
        onExploreSearch?.call(query);
      case RemoteCommandType.playMedia:
        onPlayMedia?.call(command.data);

      case RemoteCommandType.stop:
        onStop?.call();
      case RemoteCommandType.nextTrack:
        onNextTrack?.call();
      case RemoteCommandType.previousTrack:
        onPreviousTrack?.call();
      case RemoteCommandType.nextChapter:
        onNextChapter?.call();
      case RemoteCommandType.previousChapter:
        onPreviousChapter?.call();

      case RemoteCommandType.subtitles:
        onSubtitles?.call();
      case RemoteCommandType.audioTracks:
        onAudioTracks?.call();

      case RemoteCommandType.fullscreen:
        if (onFullscreen != null) {
          onFullscreen!.call();
        } else {
          simulateKeyPress(LogicalKeyboardKey.keyF);
        }

      case RemoteCommandType.ping:
      case RemoteCommandType.pong:
      case RemoteCommandType.ack:
      case RemoteCommandType.deviceInfo:
      case RemoteCommandType.disconnect:
      case RemoteCommandType.syncState:
        break;

      default:
        appLogger.w('CompanionRemoteReceiver: Unhandled command type: ${command.type}');
    }
  }

  void _setTraditionalFocusHighlight() {
    if (FocusManager.instance.highlightStrategy != FocusHighlightStrategy.alwaysTraditional) {
      FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTraditional;
    }
  }
}
