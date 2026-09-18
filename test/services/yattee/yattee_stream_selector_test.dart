import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/models/yattee/yattee_video.dart';
import 'package:plezy/services/yattee/yattee_stream_selector.dart';

YatteeAdaptiveFormat _video(String itag, int height, String codec, {int bitrate = 0, int fps = 30, String? label}) =>
    YatteeAdaptiveFormat(
      url: 'https://yattee.example/proxy/relay?itag=$itag',
      itag: itag,
      type: 'video/${codec == 'avc1' ? 'mp4' : 'webm'}',
      height: height,
      resolution: label,
      bitrate: bitrate,
      fps: fps,
      encoding: codec,
    );

YatteeAdaptiveFormat _audio(String itag, String codec, {int bitrate = 0, YatteeAudioTrack? track}) =>
    YatteeAdaptiveFormat(
      url: 'https://yattee.example/proxy/relay?itag=$itag',
      itag: itag,
      type: 'audio/${codec == 'opus' ? 'webm' : 'mp4'}',
      bitrate: bitrate,
      encoding: codec,
      audioTrack: track,
    );

/// A typical upload: AVC up to 1080p, VP9 up to 2160p, AV1 at 1080p, AAC
/// and Opus audio — YouTube's usual ladder.
final _ladder = <YatteeAdaptiveFormat>[
  _video('160', 144, 'avc1', bitrate: 100000),
  _video('134', 360, 'avc1', bitrate: 400000),
  _video('135', 480, 'avc1', bitrate: 800000),
  _video('136', 720, 'avc1', bitrate: 1500000),
  _video('137', 1080, 'avc1', bitrate: 3000000),
  _video('299', 1080, 'avc1', bitrate: 5000000, fps: 60),
  _video('248', 1080, 'vp9', bitrate: 2500000),
  _video('399', 1080, 'av01', bitrate: 2000000),
  _video('271', 1440, 'vp9', bitrate: 9000000),
  _video('313', 2160, 'vp9', bitrate: 21000000),
  _video('401', 2160, 'av01', bitrate: 18000000),
  _audio('140', 'mp4a', bitrate: 129000),
  _audio('251', 'opus', bitrate: 160000),
  _audio('250', 'opus', bitrate: 70000),
];

void main() {
  group('YatteeStreamSelector.pickVideo', () {
    test('best takes the tallest rendition, VP9 over AV1 at equal height', () {
      expect(YatteeStreamSelector.pickVideo(_ladder)?.itag, '313');
    });

    test('a cap keeps the tallest rendition at or below it', () {
      expect(YatteeStreamSelector.pickVideo(_ladder, quality: YatteeQuality.p1440)?.itag, '271');
      expect(YatteeStreamSelector.pickVideo(_ladder, quality: YatteeQuality.p720)?.itag, '136');
    });

    test('at 1080p AVC beats VP9 and AV1, and the 60 fps rendition wins on bitrate', () {
      expect(YatteeStreamSelector.pickVideo(_ladder, quality: YatteeQuality.p1080)?.itag, '299');
    });

    test('a cap below the smallest rendition still plays the smallest one', () {
      final tallOnly = [_video('271', 1440, 'vp9'), _video('313', 2160, 'vp9')];
      expect(YatteeStreamSelector.pickVideo(tallOnly, quality: YatteeQuality.p360)?.itag, '271');
    });

    test('reads the height off the resolution label when the numeric field is missing', () {
      final labelled = [_video('a', 0, 'avc1', label: '720p'), _video('b', 0, 'avc1', label: '1080p60')]
          .map(
            (f) => YatteeAdaptiveFormat(
              url: f.url,
              itag: f.itag,
              type: f.type,
              resolution: f.resolution,
              encoding: f.encoding,
            ),
          )
          .toList();
      expect(YatteeStreamSelector.pickVideo(labelled)?.itag, 'b');
    });

    test('ignores audio formats and blank URLs', () {
      final formats = [
        _audio('140', 'mp4a'),
        const YatteeAdaptiveFormat(url: '', itag: '137', type: 'video/mp4', height: 1080),
      ];
      expect(YatteeStreamSelector.pickVideo(formats), isNull);
    });
  });

  group('YatteeStreamSelector.pickAudio', () {
    test('prefers AAC over a higher-bitrate Opus track', () {
      expect(YatteeStreamSelector.pickAudio(_ladder)?.itag, '140');
    });

    test('falls back to the best Opus track when no AAC exists', () {
      final opusOnly = [_audio('250', 'opus', bitrate: 70000), _audio('251', 'opus', bitrate: 160000)];
      expect(YatteeStreamSelector.pickAudio(opusOnly)?.itag, '251');
    });

    test('plays the original-language track on dubbed uploads', () {
      final dubbed = [
        _audio(
          '140-fr',
          'mp4a',
          bitrate: 129000,
          track: const YatteeAudioTrack(id: 'fr', displayName: 'French'),
        ),
        _audio(
          '140-en',
          'mp4a',
          bitrate: 129000,
          track: const YatteeAudioTrack(id: 'en', displayName: 'English (original)'),
        ),
        _audio(
          '251-fr',
          'opus',
          bitrate: 160000,
          track: const YatteeAudioTrack(id: 'fr', displayName: 'French'),
        ),
      ];
      expect(YatteeStreamSelector.pickAudio(dubbed)?.itag, '140-en');
    });

    test('prefers untagged tracks over foreign dubs when no original is flagged', () {
      final mixed = [
        _audio(
          '140-fr',
          'mp4a',
          bitrate: 129000,
          track: const YatteeAudioTrack(id: 'fr', displayName: 'French'),
        ),
        _audio('251', 'opus', bitrate: 160000),
      ];
      expect(YatteeStreamSelector.pickAudio(mixed)?.itag, '251');
    });
  });

  group('YatteeStreamSelector.select', () {
    test('pairs the adaptive video with a separate audio stream', () {
      final selection = YatteeStreamSelector.select(
        YatteeVideo(summary: _summary(), adaptiveFormats: _ladder),
        quality: YatteeQuality.p1080,
      );
      expect(selection, isNotNull);
      expect(selection!.isAdaptive, isTrue);
      expect(selection.videoUrl, endsWith('itag=299'));
      expect(selection.audioUrl, endsWith('itag=140'));
      expect(selection.height, 1080);
      expect(selection.fps, 60);
      expect(selection.videoCodec, 'avc1');
      expect(selection.audioCodec, 'mp4a');
      expect(selection.qualityLabel, '1080p60');
    });

    test('falls back to the tallest muxed stream when no audio-only format exists', () {
      final video = YatteeVideo(
        summary: _summary(),
        adaptiveFormats: [_video('137', 1080, 'avc1')],
        formatStreams: const [
          YatteeFormatStream(
            url: 'https://x/18',
            itag: '18',
            type: 'video/mp4; codecs="avc1, mp4a"',
            resolution: '360p',
            height: 360,
          ),
          YatteeFormatStream(
            url: 'https://x/22',
            itag: '22',
            type: 'video/mp4; codecs="avc1, mp4a"',
            resolution: '720p',
            height: 720,
          ),
          YatteeFormatStream(
            url: 'https://x/hls',
            itag: 'hls',
            type: 'application/vnd.apple.mpegurl',
            container: 'hls',
          ),
        ],
      );
      final selection = YatteeStreamSelector.select(video);
      expect(selection, isNotNull);
      expect(selection!.isAdaptive, isFalse);
      expect(selection.audioUrl, isNull);
      expect(selection.videoUrl, 'https://x/22');
      expect(selection.height, 720);
      expect(selection.videoCodec, 'avc1');
    });

    test('caps the muxed fallback too', () {
      final video = YatteeVideo(
        summary: _summary(),
        formatStreams: const [
          YatteeFormatStream(url: 'https://x/18', itag: '18', type: 'video/mp4', resolution: '360p'),
          YatteeFormatStream(url: 'https://x/22', itag: '22', type: 'video/mp4', resolution: '720p'),
        ],
      );
      expect(YatteeStreamSelector.select(video, quality: YatteeQuality.p480)?.videoUrl, 'https://x/18');
    });

    test('returns null when nothing is playable', () {
      expect(YatteeStreamSelector.select(YatteeVideo(summary: _summary())), isNull);
    });
  });

  group('YatteeStreamSelector.decide', () {
    test('a live broadcast opens its HLS manifest, ignoring the quality cap', () {
      final video = YatteeVideo(
        summary: _summary(liveNow: true, lengthSeconds: 0),
        hlsUrl: 'https://yattee.example/proxy/relay?token=abc',
        adaptiveFormats: _ladder,
      );

      final decision = YatteeStreamSelector.decide(video, quality: YatteeQuality.p720);

      expect(decision.reason, isNull);
      final selection = decision.selection!;
      expect(selection.isLive, isTrue);
      expect(selection.videoUrl, 'https://yattee.example/proxy/relay?token=abc');
      // A manifest advertises its own renditions and carries its own audio.
      expect(selection.audioUrl, isNull);
      expect(selection.height, isNull);
      expect(selection.isAdaptive, isFalse);
      expect(selection.qualityLabel, 'live HLS');
    });

    test('an ordinary upload ignores its hlsUrl and picks the stream pair', () {
      final video = YatteeVideo(
        summary: _summary(),
        hlsUrl: 'https://yattee.example/proxy/relay?token=abc',
        adaptiveFormats: _ladder,
      );

      final selection = YatteeStreamSelector.decide(video, quality: YatteeQuality.p1080).selection!;

      expect(selection.isLive, isFalse);
      expect(selection.videoUrl, contains('itag=299'));
      expect(selection.audioUrl, contains('itag=140'));
    });

    // Yattee Server leaves hlsUrl empty for YouTube live — it reads
    // `manifest_url` from the top of yt-dlp's info dict, where yt-dlp never
    // puts it — but the format converter still lists the manifest among
    // formatStreams. Refusing there would reject a stream the server returned.
    test('a live broadcast falls back to the HLS entry in formatStreams', () {
      final video = YatteeVideo(
        summary: _summary(liveNow: true, lengthSeconds: 0),
        formatStreams: const [
          YatteeFormatStream(
            url: 'https://manifest.googlevideo.com/api/manifest/hls_playlist/master.m3u8',
            itag: '96',
            type: 'application/vnd.apple.mpegurl',
            container: 'hls',
            resolution: '1080p',
            height: 1080,
            httpHeaders: {'User-Agent': 'yt-dlp'},
          ),
        ],
      );

      final selection = YatteeStreamSelector.decide(video).selection!;

      expect(selection.isLive, isTrue);
      expect(selection.videoUrl, contains('master.m3u8'));
      expect(selection.height, 1080);
      // Direct to the origin, not the relay: the server does not proxy HLS
      // entries, so the extractor's headers have to ride along.
      expect(selection.headers, {'User-Agent': 'yt-dlp'});
    });

    test('the relayed hlsUrl wins over the formatStreams entry when both exist', () {
      final video = YatteeVideo(
        summary: _summary(liveNow: true, lengthSeconds: 0),
        hlsUrl: 'https://yattee.example/proxy/relay?token=abc',
        formatStreams: const [
          YatteeFormatStream(
            url: 'https://manifest.googlevideo.com/master.m3u8',
            itag: '96',
            type: 'application/vnd.apple.mpegurl',
            container: 'hls',
          ),
        ],
      );

      final selection = YatteeStreamSelector.decide(video).selection!;

      expect(selection.videoUrl, 'https://yattee.example/proxy/relay?token=abc');
      expect(selection.headers, isNull);
    });

    // The isHls filter exists to keep IP-bound manifests out of ordinary
    // playback; the live fallback must not become a back door into it.
    test('an ordinary upload never falls back to an HLS entry', () {
      final video = YatteeVideo(
        summary: _summary(),
        formatStreams: const [
          YatteeFormatStream(
            url: 'https://manifest.googlevideo.com/master.m3u8',
            itag: '96',
            type: 'application/vnd.apple.mpegurl',
            container: 'hls',
          ),
        ],
      );

      expect(YatteeStreamSelector.decide(video).reason, YatteeUnplayableReason.noPlayableStream);
    });

    test('the cap applies when the manifests are per-rendition chunklists', () {
      const streams = [
        YatteeFormatStream(
          url: 'https://x/1080.m3u8',
          itag: '96',
          type: 'application/vnd.apple.mpegurl',
          container: 'hls',
          height: 1080,
        ),
        YatteeFormatStream(
          url: 'https://x/480.m3u8',
          itag: '93',
          type: 'application/vnd.apple.mpegurl',
          container: 'hls',
          height: 480,
        ),
      ];

      expect(YatteeStreamSelector.pickLiveHls(streams)?.videoUrl, 'https://x/1080.m3u8');
      expect(YatteeStreamSelector.pickLiveHls(streams, quality: YatteeQuality.p720)?.videoUrl, 'https://x/480.m3u8');
    });

    test('a live broadcast the server has no manifest for is refused as unavailable', () {
      final video = YatteeVideo(summary: _summary(liveNow: true, lengthSeconds: 0));

      final decision = YatteeStreamSelector.decide(video);

      expect(decision.selection, isNull);
      expect(decision.reason, YatteeUnplayableReason.liveUnavailable);
    });

    test('a premiere is refused as not started even when it is flagged live', () {
      final video = YatteeVideo(
        summary: _summary(liveNow: true, isUpcoming: true, lengthSeconds: 0),
        hlsUrl: 'https://yattee.example/proxy/relay?token=abc',
      );

      expect(YatteeStreamSelector.decide(video).reason, YatteeUnplayableReason.premiereNotStarted);
    });

    test('an upload with no usable stream is refused as unplayable', () {
      expect(
        YatteeStreamSelector.decide(YatteeVideo(summary: _summary())).reason,
        YatteeUnplayableReason.noPlayableStream,
      );
    });
  });
}

YatteeVideoSummary _summary({bool liveNow = false, bool isUpcoming = false, int lengthSeconds = 1}) =>
    YatteeVideoSummary(
      videoId: 'dQw4w9WgXcQ',
      title: 't',
      author: 'a',
      authorId: 'UC',
      lengthSeconds: lengthSeconds,
      liveNow: liveNow,
      isUpcoming: isUpcoming,
    );
