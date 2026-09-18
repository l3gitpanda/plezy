part of '../../video_player_screen.dart';

/// YouTube (Yattee Server) sessions: the one place the player branches on
/// [VideoPlayerScreen.youtube], so the start and reload flows share a single
/// source-resolution seam instead of each checking for it.
extension _VideoPlayerYouTubeMethods on VideoPlayerScreenState {
  /// Resolve the playback source for [options]. A YouTube session rebuilds
  /// its context from the streams it launched with — the relay URLs stay
  /// valid for hours, which covers every in-place reload the screen can
  /// trigger — and everything else goes through [resolver].
  Future<PlaybackContext> _resolvePlaybackSource(
    PlaybackSourceResolver resolver,
    PlaybackInitializationOptions options, {
    required bool offlineLibraryMode,
  }) {
    final youtube = widget.youtube;
    if (youtube != null) return Future.value(youtube.toPlaybackContext(options.metadata));
    return resolver.resolve(options, offlineLibraryMode: offlineLibraryMode);
  }
}
