import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/models/yattee/yattee_site.dart';
import 'package:plezy/models/yattee/yattee_video.dart';
import 'package:plezy/providers/yattee/yattee_account_provider.dart';
import 'package:plezy/services/yattee/yattee_store.dart';

import '../test_helpers/prefs.dart';

YatteeVideoSummary _video(String id, {YatteeSite site = YatteeSite.youtube}) =>
    YatteeVideoSummary(videoId: id, title: 'Video $id', author: 'a', authorId: 'UC1', lengthSeconds: 60, site: site);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
  });

  test('a mark survives a rebind of the same profile', () async {
    final provider = YatteeAccountProvider();
    await provider.onActiveProfileChanged('user-1');
    await provider.setVideoWatched(YatteeSite.youtube, 'abc', true);
    expect(provider.isVideoWatched(YatteeSite.youtube, 'abc'), isTrue);
    provider.dispose();

    final reopened = YatteeAccountProvider();
    addTearDown(reopened.dispose);
    await reopened.onActiveProfileChanged('user-1');

    expect(reopened.isVideoWatched(YatteeSite.youtube, 'abc'), isTrue);
  });

  test('marks are per profile', () async {
    final provider = YatteeAccountProvider();
    addTearDown(provider.dispose);
    await provider.onActiveProfileChanged('user-1');
    await provider.setVideoWatched(YatteeSite.youtube, 'abc', true);

    await provider.onActiveProfileChanged('user-2');
    expect(provider.isVideoWatched(YatteeSite.youtube, 'abc'), isFalse);
  });

  // Ids are only unique within a site, so the key carries both.
  test('the same id on two sites is two marks', () async {
    final provider = YatteeAccountProvider();
    addTearDown(provider.dispose);
    await provider.onActiveProfileChanged('user-1');

    await provider.setVideoWatched(YatteeSite.twitch, '123', true);

    expect(provider.isVideoWatched(YatteeSite.twitch, '123'), isTrue);
    expect(provider.isVideoWatched(YatteeSite.youtube, '123'), isFalse);
  });

  test('unmarking removes it', () async {
    final provider = YatteeAccountProvider();
    addTearDown(provider.dispose);
    await provider.onActiveProfileChanged('user-1');

    await provider.setVideoWatched(YatteeSite.youtube, 'abc', true);
    await provider.setVideoWatched(YatteeSite.youtube, 'abc', false);

    expect(provider.isVideoWatched(YatteeSite.youtube, 'abc'), isFalse);
  });

  test('the card stand-in carries the mark, and restamping updates it', () async {
    final provider = YatteeAccountProvider();
    addTearDown(provider.dispose);
    await provider.onActiveProfileChanged('user-1');

    final before = provider.toMediaItem(_video('abc'));
    expect(before.isWatched, isFalse);

    await provider.setVideoWatched(YatteeSite.youtube, 'abc', true);

    expect(provider.toMediaItem(_video('abc')).isWatched, isTrue);
    // An item already on screen is updated in place rather than refetched.
    expect(provider.restampWatched([before]).single.isWatched, isTrue);
  });

  test('the stored list is bounded so the blob cannot grow forever', () async {
    const store = YatteeStore();
    await store.saveWatched('user-1', [for (var i = 0; i < YatteeStore.maxWatchedEntries + 50; i++) 'youtube:v$i']);

    final loaded = await store.loadWatched('user-1');

    expect(loaded, hasLength(YatteeStore.maxWatchedEntries));
    // The newest are kept; the oldest marks fall off the front.
    expect(loaded.last, 'youtube:v${YatteeStore.maxWatchedEntries + 49}');
    expect(loaded.first, 'youtube:v50');
  });
}
