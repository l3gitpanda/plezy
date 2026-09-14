import 'dart:async';

import 'package:flutter/material.dart';

import '../../i18n/strings.g.dart';
import '../../models/yattee/yattee_site.dart';
import '../../models/yattee/yattee_video.dart';
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
  YatteeSite site = YatteeSite.youtube,
  String? videoUrl,
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
    // YouTube is fetched by id; every other site by its own URL, because
    // `/videos/{id}` is YouTube-only — it asserts the extractor first, and its
    // id sanitiser rejects anything that is not YouTube-shaped ("Invalid video
    // ID format"). Falling back to it for a URL-less non-YouTube item was
    // therefore never going to work, only fail confusingly.
    final YatteeVideo video;
    if (site == YatteeSite.youtube) {
      video = await client.fetchVideo(videoId);
    } else if (videoUrl != null) {
      video = await client.extractVideo(videoUrl);
    } else {
      await loading.dismiss();
      if (context.mounted) showErrorSnackBar(context, t.yattee.videoUnavailable);
      return;
    }
    if (!context.mounted) return;
    final decision = YatteeStreamSelector.decide(video, quality: account.quality);
    if (decision.reason case final reason?) {
      await loading.dismiss();
      if (context.mounted) showErrorSnackBar(context, _unplayableMessage(reason));
      return;
    }
    final selection = decision.selection!;
    appLogger.i(
      'YouTube: playing ${video.videoId} at ${selection.qualityLabel} '
      '(${selection.isLive
          ? 'live'
          : selection.isAdaptive
          ? 'adaptive ${selection.videoCodec}+${selection.audioCodec}'
          : 'muxed'})',
    );
    final metadata = YouTubeMediaItems.fromSummary(video.summary);
    final route = VideoPlayerRoute(
      builder: (_) => VideoPlayerScreen(
        metadata: metadata,
        youtube: YouTubeSessionArgs(video: video, selection: selection),
      ),
    );
    await loading.dismiss();
    // Pushed through the route itself rather than the navigator: that is what
    // tears down a player already on screen before this one starts, so
    // launching one video from another does not leave two sessions alive.
    unawaited(route.push(navigator));
  } catch (e, stackTrace) {
    appLogger.w('YouTube: failed to resolve $videoId', error: e, stackTrace: stackTrace);
    await loading.dismiss();
    if (!context.mounted) return;
    showErrorSnackBar(context, _launchFailureMessage(e));
  } finally {
    _launchInFlight = false;
    unawaited(loading.dismiss());
  }
}

/// What to tell the user when resolving a video threw.
///
/// The extractor's own failures reach us as HTTP 422 with yt-dlp's message
/// wrapped in "Could not extract video: …" (routers/videos.py). That text is
/// written for a terminal, not a television, so the two cases worth naming
/// get a sentence of their own and everything else is summarised rather than
/// dumped.
String _launchFailureMessage(Object error) {
  if (error case YatteeApiException(:final statusCode, :final message) when statusCode == 422) {
    final detail = message.toLowerCase();
    // yt-dlp reports an offline Twitch channel as "<name> is offline"; there
    // is no status code or field that distinguishes it, so the text is all
    // there is to go on.
    if (detail.contains('offline')) return t.yattee.channelOffline;
    return t.yattee.videoUnavailable;
  }
  final message = switch (error) {
    // Only a genuine credential refusal reaches here now — a policy 403 is an
    // API exception and carries its own reason.
    YatteeAuthException(:final display) => display ?? t.addServer.invalidCredentials,
    YatteeApiException(:final message) => message,
    _ => error.toString(),
  };
  return t.yattee.videoLoadFailed(error: message);
}

String _unplayableMessage(YatteeUnplayableReason reason) => switch (reason) {
  YatteeUnplayableReason.premiereNotStarted => t.yattee.premiereNotStarted,
  YatteeUnplayableReason.liveUnavailable => t.yattee.liveUnavailable,
  YatteeUnplayableReason.noPlayableStream => t.yattee.noPlayableStream,
};
