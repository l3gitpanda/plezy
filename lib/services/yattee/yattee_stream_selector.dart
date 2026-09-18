import '../../models/yattee/yattee_video.dart';

/// Resolution cap for YouTube playback. [best] takes whatever the upload
/// offers — 4K/8K included — the others cap the picked video stream's height.
enum YatteeQuality {
  best(null),
  p2160(2160),
  p1440(1440),
  p1080(1080),
  p720(720),
  p480(480),
  p360(360);

  const YatteeQuality(this.maxHeight);

  /// Null for [best].
  final int? maxHeight;
}

/// What the player opens for one video: the primary stream plus, for the
/// adaptive route, the separate audio-only stream the player attaches
/// alongside it.
///
/// YouTube's muxed formats stop at 720p; everything above lives in
/// `adaptiveFormats` as video-only and audio-only files (the DASH
/// representations). Yattee Server exposes no DASH manifest, and the pinned
/// mpv builds for Android/Linux lack FFmpeg's dash demuxer anyway, so full
/// resolution means pairing the two streams client-side — exactly what the
/// Yattee mpv client does.
class YatteeStreamSelection {
  final String videoUrl;

  /// Audio-only stream to side-load; null when [videoUrl] already carries
  /// audio (muxed fallback).
  final String? audioUrl;

  /// Extractor-supplied request headers (non-YouTube sites); null for the
  /// relay URLs YouTube playback uses.
  final Map<String, String>? headers;
  final int? width;
  final int? height;
  final int? fps;

  /// `avc1`, `vp9`, `av01`, or the muxed container's video codec family.
  final String? videoCodec;
  final String? audioCodec;

  /// Whether the pair came from adaptive formats (full resolution) rather
  /// than a muxed progressive stream.
  final bool isAdaptive;

  /// Whether [videoUrl] is a live HLS manifest rather than a file.
  ///
  /// A live stream is a sliding window with no fixed duration, so the player
  /// pins its HLS parser on the URL and suppresses the VOD-only resume, seek
  /// and end-of-stream behaviour. Distinct from a Plex/Jellyfin live channel,
  /// which owns a tuner session this has no equivalent of.
  final bool isLive;

  const YatteeStreamSelection({
    required this.videoUrl,
    this.audioUrl,
    this.headers,
    this.width,
    this.height,
    this.fps,
    this.videoCodec,
    this.audioCodec,
    required this.isAdaptive,
    this.isLive = false,
  });

  /// A live HLS manifest, from either route in [YatteeStreamSelector.decide].
  ///
  /// No audio URL and no codecs: a manifest advertises its own renditions and
  /// carries its own audio, so there is nothing to side-load and nothing for
  /// the quality cap to choose between. [headers] is null for the relay route
  /// (the relay authenticates by signed query parameter and supplies its own
  /// upstream identity) and carries the extractor's headers for the direct
  /// route, where the player talks to the origin itself.
  const YatteeStreamSelection.liveHls(String url, {this.headers, this.height, this.width, this.fps})
    : videoUrl = url,
      audioUrl = null,
      videoCodec = null,
      audioCodec = null,
      isAdaptive = false,
      isLive = true;

  /// `2160p60`-style label for logs and the info sheet.
  String get qualityLabel {
    if (isLive) return 'live HLS';
    final h = height;
    if (h == null) return isAdaptive ? 'adaptive' : 'muxed';
    final f = fps;
    return f != null && f > 30 ? '${h}p$f' : '${h}p';
  }
}

/// Why a fetched video has nothing to open.
enum YatteeUnplayableReason {
  /// A premiere whose countdown has not run out. YouTube lists it like any
  /// other video and the server happily returns it, but no stream exists
  /// until it starts.
  premiereNotStarted,

  /// Flagged live, yet the server returned no HLS manifest — the broadcast
  /// ended between the listing and this fetch, or the extractor failed on it.
  liveUnavailable,

  /// An ordinary upload with no usable adaptive or progressive stream.
  noPlayableStream,
}

/// The launch decision for one fetched video: a stream to open, or the reason
/// there is none. Exactly one of [selection] and [reason] is non-null.
class YatteePlaybackDecision {
  final YatteeStreamSelection? selection;
  final YatteeUnplayableReason? reason;

  const YatteePlaybackDecision.play(YatteeStreamSelection this.selection) : reason = null;

  const YatteePlaybackDecision.refuse(YatteeUnplayableReason this.reason) : selection = null;
}

/// Picks the streams to open for a [YatteeVideo] under a [YatteeQuality] cap.
///
/// Video: the tallest stream within the cap, ties broken by codec — AVC
/// first because every device decodes it in hardware, then VP9 (the only
/// option above 1080p on most uploads), then AV1 — and then by bitrate so a
/// 60 fps rendition beats its 30 fps sibling. Audio: the upload's original
/// language track, AAC over Opus for the widest decoder support, highest
/// bitrate. Muxed formats are the fallback when either side is missing.
abstract final class YatteeStreamSelector {
  /// Codec families in preference order; anything unlisted sorts last.
  static const List<String> videoCodecPreference = ['avc1', 'vp9', 'av01'];
  static const List<String> audioCodecPreference = ['mp4a', 'opus'];

  /// What to open for [video], live broadcasts included.
  ///
  /// A live video carries no adaptive or progressive files at all: the whole
  /// stream is the relay's HLS manifest, which [selectMuxed] deliberately
  /// refuses (its `isHls` filter is what keeps IP-bound googlevideo playlists
  /// out of ordinary playback). Hence the branch on the video's own live
  /// flags rather than on [YatteeVideo.hlsUrl] — a finished upload carries
  /// one of those too, and opening it would trade the picked rendition for
  /// whatever the manifest defaults to.
  static YatteePlaybackDecision decide(YatteeVideo video, {YatteeQuality quality = YatteeQuality.best}) {
    // Checked before `liveNow`: an upcoming premiere can carry both flags,
    // and "it hasn't started" is the more useful thing to say.
    if (video.summary.isUpcoming) {
      return const YatteePlaybackDecision.refuse(YatteeUnplayableReason.premiereNotStarted);
    }
    if (video.summary.liveNow) {
      final hlsUrl = video.hlsUrl;
      if (hlsUrl != null) return YatteePlaybackDecision.play(YatteeStreamSelection.liveHls(hlsUrl));
      // `hlsUrl` is empty for YouTube live on Yattee Server: it is read from
      // the top of yt-dlp's info dict (converters/_ytdlp.py), but yt-dlp only
      // sets `manifest_url` per format. The manifest is still there — the
      // format converter puts the HLS variants in `formatStreams` — so fall
      // back to those rather than refusing a stream the server did return.
      final fromFormats = pickLiveHls(video.formatStreams, quality: quality);
      return fromFormats == null
          ? const YatteePlaybackDecision.refuse(YatteeUnplayableReason.liveUnavailable)
          : YatteePlaybackDecision.play(fromFormats);
    }
    final selection = select(video, quality: quality);
    return selection == null
        ? const YatteePlaybackDecision.refuse(YatteeUnplayableReason.noPlayableStream)
        : YatteePlaybackDecision.play(selection);
  }

  /// The video+audio pair for an ordinary upload; null when neither the
  /// adaptive nor the muxed route yields one. Live videos never reach here —
  /// see [decide].
  static YatteeStreamSelection? select(YatteeVideo video, {YatteeQuality quality = YatteeQuality.best}) {
    final adaptive = selectAdaptive(video.adaptiveFormats, quality: quality);
    if (adaptive != null) return adaptive;
    return selectMuxed(video.formatStreams, quality: quality);
  }

  static YatteeStreamSelection? selectAdaptive(
    List<YatteeAdaptiveFormat> formats, {
    YatteeQuality quality = YatteeQuality.best,
  }) {
    final video = pickVideo(formats, quality: quality);
    final audio = pickAudio(formats);
    if (video == null || audio == null) return null;
    return YatteeStreamSelection(
      videoUrl: video.url,
      audioUrl: audio.url,
      headers: video.httpHeaders ?? audio.httpHeaders,
      width: video.width,
      height: video.effectiveHeight,
      fps: video.fps,
      videoCodec: video.codecFamily,
      audioCodec: audio.codecFamily,
      isAdaptive: true,
    );
  }

  static YatteeAdaptiveFormat? pickVideo(
    List<YatteeAdaptiveFormat> formats, {
    YatteeQuality quality = YatteeQuality.best,
  }) {
    final cap = quality.maxHeight;
    final candidates = formats.where((f) => f.isVideo && f.url.isNotEmpty && f.effectiveHeight != null).toList();
    if (candidates.isEmpty) return null;
    // A cap below the smallest rendition still plays something: keep the
    // lowest one rather than nothing.
    var capped = cap == null ? candidates : candidates.where((f) => f.effectiveHeight! <= cap).toList();
    if (capped.isEmpty) {
      final minHeight = candidates.map((f) => f.effectiveHeight!).reduce((a, b) => a < b ? a : b);
      capped = candidates.where((f) => f.effectiveHeight == minHeight).toList();
    }
    capped.sort((a, b) {
      final byHeight = b.effectiveHeight!.compareTo(a.effectiveHeight!);
      if (byHeight != 0) return byHeight;
      final byCodec = _rank(videoCodecPreference, a.codecFamily).compareTo(_rank(videoCodecPreference, b.codecFamily));
      if (byCodec != 0) return byCodec;
      return (b.bitrate ?? 0).compareTo(a.bitrate ?? 0);
    });
    return capped.first;
  }

  static YatteeAdaptiveFormat? pickAudio(List<YatteeAdaptiveFormat> formats) {
    final candidates = formats.where((f) => f.isAudio && f.url.isNotEmpty).toList();
    if (candidates.isEmpty) return null;
    // Dubbed uploads list one audio format per language; only the original
    // (or, absent that flag, an untagged track) should play by default.
    final originals = candidates.where((f) => f.audioTrack?.isOriginal ?? false).toList();
    final untagged = candidates.where((f) => f.audioTrack == null).toList();
    final pool = originals.isNotEmpty ? originals : (untagged.isNotEmpty ? untagged : candidates);
    pool.sort((a, b) {
      final byCodec = _rank(audioCodecPreference, a.codecFamily).compareTo(_rank(audioCodecPreference, b.codecFamily));
      if (byCodec != 0) return byCodec;
      return (b.bitrate ?? 0).compareTo(a.bitrate ?? 0);
    });
    return pool.first;
  }

  /// The live manifest among [streams], or null when none is HLS.
  ///
  /// The mirror of [selectMuxed]'s `isHls` filter, which exists to keep these
  /// manifests out of ordinary playback: here they are the only thing wanted.
  ///
  /// Yattee Server dedupes these by URL, so YouTube's renditions — which all
  /// share one master playlist — normally collapse to a single entry whose
  /// height is incidental. The cap is still applied for the case where they
  /// do not: an extractor with no `manifest_url` falls back to a per-rendition
  /// chunklist, and then the height is real and worth respecting.
  ///
  /// Unlike every other route these URLs point at the origin, not the relay —
  /// the server does not proxy HLS entries — so the selection carries the
  /// extractor's headers and playback needs a network path to the origin.
  static YatteeStreamSelection? pickLiveHls(
    List<YatteeFormatStream> streams, {
    YatteeQuality quality = YatteeQuality.best,
  }) {
    final candidates = streams.where((s) => s.isHls && s.url.isNotEmpty).toList();
    if (candidates.isEmpty) return null;
    final cap = quality.maxHeight;
    var capped = cap == null ? candidates : candidates.where((s) => (s.height ?? 0) <= cap).toList();
    if (capped.isEmpty) capped = candidates;
    capped.sort((a, b) => (b.height ?? 0).compareTo(a.height ?? 0));
    final pick = capped.first;
    return YatteeStreamSelection.liveHls(
      pick.url,
      headers: pick.httpHeaders,
      height: pick.height,
      width: pick.width,
      fps: pick.fps,
    );
  }

  /// Muxed progressive fallback: the tallest non-HLS stream within the cap.
  static YatteeStreamSelection? selectMuxed(
    List<YatteeFormatStream> streams, {
    YatteeQuality quality = YatteeQuality.best,
  }) {
    final cap = quality.maxHeight;
    final candidates = streams.where((s) => !s.isHls && s.url.isNotEmpty).toList();
    if (candidates.isEmpty) return null;
    int heightOf(YatteeFormatStream s) => s.height ?? _heightFromLabel(s.resolution) ?? 0;
    var capped = cap == null ? candidates : candidates.where((s) => heightOf(s) <= cap).toList();
    if (capped.isEmpty) capped = candidates;
    capped.sort((a, b) => heightOf(b).compareTo(heightOf(a)));
    final pick = capped.first;
    return YatteeStreamSelection(
      videoUrl: pick.url,
      headers: pick.httpHeaders,
      width: pick.width,
      height: heightOf(pick) == 0 ? null : heightOf(pick),
      fps: pick.fps,
      videoCodec: pick.type.contains('avc1')
          ? 'avc1'
          : pick.type.contains('vp9') || pick.type.contains('vp09')
          ? 'vp9'
          : null,
      isAdaptive: false,
    );
  }

  static int _rank(List<String> preference, String family) {
    final index = preference.indexOf(family);
    return index == -1 ? preference.length : index;
  }

  static int? _heightFromLabel(String? label) {
    if (label == null) return null;
    final match = RegExp(r'^(\d+)p').firstMatch(label.trim());
    return match == null ? null : int.tryParse(match.group(1)!);
  }
}
