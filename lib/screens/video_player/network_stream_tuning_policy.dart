/// Whether an open should get the network-VOD reconnect tuning: ffmpeg's
/// `reconnect_streamed` family, which turns a dropped connection mid-file into
/// a resumed byte range instead of a truncated playback.
///
/// It must NOT reach a live stream. Those options make ffmpeg treat *any* EOF
/// on the stream layer as a disconnect to retry, and a live HLS open's first
/// read is the playlist body — a short file whose normal end is an EOF. The
/// read then never completes: ffmpeg reconnects on an exponential backoff
/// (1s, 3s, 7s, 15s, 31s…) while the player sits buffering forever, having
/// never been handed the manifest.
///
/// Three separate things mean "live" here and any of them disqualifies:
/// [isTunerLive] is a Plex/Jellyfin channel (`VideoPlayerScreen.isLive`),
/// [isLiveStream] is a live manifest from any source (YouTube today), and
/// local media has no network to tune in the first place.
bool usesNetworkVodTuning({required bool isLocalMedia, required bool isTunerLive, required bool isLiveStream}) {
  return !isLocalMedia && !isTunerLive && !isLiveStream;
}
