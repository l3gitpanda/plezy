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
  });

  /// `2160p60`-style label for logs and the info sheet.
  String get qualityLabel {
    final h = height;
    if (h == null) return isAdaptive ? 'adaptive' : 'muxed';
    final f = fps;
    return f != null && f > 30 ? '${h}p$f' : '${h}p';
  }
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
