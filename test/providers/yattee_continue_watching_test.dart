import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/models/yattee/yattee_site.dart';
import 'package:plezy/models/yattee/yattee_video.dart';
import 'package:plezy/models/yattee/yattee_watch_progress.dart';
import 'package:plezy/providers/yattee/yattee_account_provider.dart';
import 'package:plezy/services/yattee/yattee_store.dart';

import '../test_helpers/prefs.dart';

YatteeVideoSummary _video(String id, {YatteeSite site = YatteeSite.youtube, int lengthSeconds = 600}) =>
    YatteeVideoSummary(
      videoId: id,
      title: 'Video $id',
      author: 'Channel',
      authorId: 'UC1',
      lengthSeconds: lengthSeconds,
      thumbnails: const [YatteeThumbnail(quality: 'high', url: 'https://example.test/t.jpg', width: 480, height: 360)],
      site: site,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
  });

  Future<YatteeAccountProvider> boundProvider(String uuid) async {
    final provider = YatteeAccountProvider();
    addTearDown(provider.dispose);
    await provider.onActiveProfileChanged(uuid);
    return provider;
  }

  test('a recorded position becomes a resume point and a Continue Watching entry', () async {
    final provider = await boundProvider('user-1');

    await provider.recordProgress(_video('abc'), positionMs: 120000, durationMs: 600000);

    expect(provider.resumePositionMsFor(YatteeSite.youtube, 'abc'), 120000);
    expect(provider.continueWatching.single.videoId, 'abc');
  });

  test('the newest resume point leads the row', () async {
    final provider = await boundProvider('user-1');

    await provider.recordProgress(_video('one'), positionMs: 60000, durationMs: 600000);
    await provider.recordProgress(_video('two'), positionMs: 60000, durationMs: 600000);
    // Going back to the first moves it to the front rather than duplicating it.
    await provider.recordProgress(_video('one'), positionMs: 90000, durationMs: 600000);

    expect([for (final entry in provider.continueWatching) entry.videoId], ['one', 'two']);
    expect(provider.resumePositionMsFor(YatteeSite.youtube, 'one'), 90000);
  });

  test('the card carries the resume point, so the shelf draws its progress bar', () async {
    final provider = await boundProvider('user-1');
    await provider.recordProgress(_video('abc'), positionMs: 120000, durationMs: 600000);

    final item = provider.toMediaItem(_video('abc'));

    expect(item.viewOffsetMs, 120000);
    expect(item.hasActiveProgress, isTrue);
  });

  // The listing reports no length for a fair number of rows; without the
  // played runtime there is nothing to draw the bar against.
  test('a video the listing gave no length falls back to the played runtime', () async {
    final provider = await boundProvider('user-1');
    await provider.recordProgress(_video('abc', lengthSeconds: 0), positionMs: 120000, durationMs: 600000);

    final item = provider.toMediaItem(_video('abc', lengthSeconds: 0));

    expect(item.durationMs, 600000);
    expect(item.hasActiveProgress, isTrue);
  });

  test('marking watched retires the resume point', () async {
    final provider = await boundProvider('user-1');
    await provider.recordProgress(_video('abc'), positionMs: 120000, durationMs: 600000);

    await provider.setVideoWatched(YatteeSite.youtube, 'abc', true);

    expect(provider.continueWatching, isEmpty);
    expect(provider.resumePositionMsFor(YatteeSite.youtube, 'abc'), isNull);
    expect(provider.isVideoWatched(YatteeSite.youtube, 'abc'), isTrue);
  });

  test('removing from Continue Watching does not mark it watched', () async {
    final provider = await boundProvider('user-1');
    await provider.recordProgress(_video('abc'), positionMs: 120000, durationMs: 600000);

    await provider.clearProgress(YatteeSite.youtube, 'abc');

    expect(provider.continueWatching, isEmpty);
    expect(provider.isVideoWatched(YatteeSite.youtube, 'abc'), isFalse);
  });

  // Ids are only unique within a site.
  test('the same id on two sites is two resume points', () async {
    final provider = await boundProvider('user-1');

    await provider.recordProgress(_video('123', site: YatteeSite.twitch), positionMs: 60000, durationMs: 600000);

    expect(provider.resumePositionMsFor(YatteeSite.twitch, '123'), 60000);
    expect(provider.resumePositionMsFor(YatteeSite.youtube, '123'), isNull);
  });

  test('resume points survive a rebind and are per profile', () async {
    final provider = YatteeAccountProvider();
    await provider.onActiveProfileChanged('user-1');
    await provider.recordProgress(_video('abc'), positionMs: 120000, durationMs: 600000);
    provider.dispose();

    final reopened = await boundProvider('user-1');
    expect(reopened.resumePositionMsFor(YatteeSite.youtube, 'abc'), 120000);
    // The whole card is rebuilt from the stored copy, not refetched.
    expect(reopened.continueWatching.single.video.title, 'Video abc');
    expect(reopened.continueWatching.single.video.thumbnail?.url, 'https://example.test/t.jpg');

    await reopened.onActiveProfileChanged('user-2');
    expect(reopened.resumePositionMsFor(YatteeSite.youtube, 'abc'), isNull);
  });

  test('the stored list is bounded so the blob cannot grow forever', () async {
    const store = YatteeStore();
    await store.saveProgress('user-1', [
      for (var i = 0; i < YatteeStore.maxProgressEntries + 20; i++)
        YatteeWatchProgress(video: _video('v$i'), positionMs: 1000, durationMs: 600000, updatedAtMs: i),
    ]);

    final loaded = await store.loadProgress('user-1');

    expect(loaded, hasLength(YatteeStore.maxProgressEntries));
    // The least recently watched fall off the front.
    expect(loaded.first.videoId, 'v20');
    expect(loaded.last.videoId, 'v${YatteeStore.maxProgressEntries + 19}');
  });

  test('a stored entry round-trips the whole video, origin included', () {
    final progress = YatteeWatchProgress(
      video: _video(
        'abc',
        site: YatteeSite.twitch,
      ).withOrigin(site: YatteeSite.twitch, videoUrl: 'https://twitch.tv/someone'),
      positionMs: 1000,
      durationMs: 600000,
      updatedAtMs: 42,
    );

    final restored = YatteeWatchProgress.fromJson(progress.toJson());

    expect(restored.video.videoId, 'abc');
    expect(restored.video.title, 'Video abc');
    // The origin is what routes playback; losing it would send a Twitch
    // stream to the YouTube-only `/videos/{id}`.
    expect(restored.video.site, YatteeSite.twitch);
    expect(restored.video.videoUrl, 'https://twitch.tv/someone');
    expect(restored.video.thumbnail?.url, 'https://example.test/t.jpg');
    expect(restored.positionMs, 1000);
    expect(restored.durationMs, 600000);
    expect(restored.updatedAtMs, 42);
  });
}
