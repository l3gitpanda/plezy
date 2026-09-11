import 'dart:async';

import 'package:flutter/material.dart';

import '../../i18n/strings.g.dart';
import '../../models/yattee/youtube_media_item.dart';
import '../../providers/yattee/yattee_account_provider.dart';
import '../../screens/video_player/youtube_session_args.dart';
import '../../screens/video_player_screen.dart';
import '../../services/yattee/yattee_exceptions.dart';
import '../../services/yattee/yattee_stream_selector.dart';
import '../app_logger.dart';
import '../dialogs.dart';
import '../snackbar_helper.dart';
import '../video_player_navigation.dart';

/// Whether a launch is already resolving. `/videos/{id}` runs yt-dlp on a
/// cache miss, long enough for a second tap to land; one dialog at a time.
bool _launchInFlight = false;

/// Navigate to the video player for a YouTube video — the single YouTube
/// entry, the parallel of `navigateToLiveTv`.
///
/// Everything the player needs is resolved here, under a loading dialog:
/// the full `/videos/{id}` answer, the stream pair for the profile's quality
/// cap, and the synthetic [MediaItem] the player shows. The screen itself
/// then has nothing to negotiate (see [YouTubeSessionArgs]).
Future<void> navigateToYouTubeVideo(
  BuildContext context, {
  required YatteeAccountProvider account,
  required String videoId,
}) async {
  final client = account.client;
  if (client == null || _launchInFlight) return;
  _launchInFlight = true;
  final navigator = Navigator.of(context);
  final loading = ScopedLoadingDialogController()
    ..show(
      context,
      builder: (_) => const PopScope(canPop: false, child: Center(child: CircularProgressIndicator())),
    );
  try {
    final video = await client.fetchVideo(videoId);
    if (!context.mounted) return;
    if (video.summary.liveNow || video.summary.isUpcoming) {
      // Live playback needs an HLS open the shared VOD path does not
      // expose; the muxed/adaptive lists are empty for a live video anyway.
      await loading.dismiss();
      if (context.mounted) showErrorSnackBar(context, t.yattee.liveUnsupported);
      return;
    }
    final selection = YatteeStreamSelector.select(video, quality: account.quality);
    if (selection == null) {
      await loading.dismiss();
      if (context.mounted) showErrorSnackBar(context, t.yattee.noPlayableStream);
      return;
    }
    appLogger.i(
      'YouTube: playing ${video.videoId} at ${selection.qualityLabel} '
      '(${selection.isAdaptive ? 'adaptive ${selection.videoCodec}+${selection.audioCodec}' : 'muxed'})',
    );
    final metadata = YouTubeMediaItems.fromSummary(video.summary);
    final route = buildVideoPlayerRoute(
      builder: (_) => VideoPlayerScreen(
        metadata: metadata,
        youtube: YouTubeSessionArgs(video: video, selection: selection),
      ),
    );
    await loading.dismiss();
    unawaited(navigator.push<bool>(route));
  } catch (e, stackTrace) {
    appLogger.w('YouTube: failed to resolve $videoId', error: e, stackTrace: stackTrace);
    await loading.dismiss();
    if (!context.mounted) return;
    final message = switch (e) {
      YatteeAuthException(:final display) => display ?? t.addServer.invalidCredentials,
      YatteeApiException(:final message) => message,
      _ => e.toString(),
    };
    showErrorSnackBar(context, t.yattee.videoLoadFailed(error: message));
  } finally {
    _launchInFlight = false;
    unawaited(loading.dismiss());
  }
}
