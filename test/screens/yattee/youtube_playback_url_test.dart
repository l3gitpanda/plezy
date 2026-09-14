import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/models/yattee/yattee_session.dart';
import 'package:plezy/models/yattee/yattee_site.dart';
import 'package:plezy/models/yattee/yattee_video.dart';
import 'package:plezy/models/yattee/youtube_media_item.dart';
import 'package:plezy/providers/yattee/yattee_account_provider.dart';
import 'package:plezy/screens/yattee/youtube_video_actions.dart';

import '../../test_helpers/prefs.dart';

MediaItem _twitchItem({bool liveNow = true, String? videoUrl}) => YouTubeMediaItems.fromSummary(
  YatteeVideoSummary(
    videoId: '317451146103',
    title: 'shroud (live)',
    author: 'shroud',
    authorId: 'shroud',
    lengthSeconds: 0,
    liveNow: liveNow,
    site: YatteeSite.twitch,
    videoUrl: videoUrl,
  ),
);

Future<YatteeAccountProvider> _account() async {
  final account = YatteeAccountProvider();
  await account.onActiveProfileChanged('user-1');
  await account.subscribe(
    const YatteeSubscription(
      channelId: 'shroud',
      name: 'shroud',
      site: YatteeSite.twitch,
      channelUrl: 'https://www.twitch.tv/shroud',
    ),
  );
  return account;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    resetSharedPreferencesForTest();
    LocaleSettings.setLocaleSync(AppLocale.en);
  });

  test('the item\'s own URL is used when the server states one', () async {
    final account = await _account();
    addTearDown(account.dispose);

    expect(
      youTubePlaybackUrl(_twitchItem(videoUrl: 'https://www.twitch.tv/videos/123'), account),
      'https://www.twitch.tv/videos/123',
    );
  });

  // Regression: without a URL these fell through to /videos/{id}, which is
  // YouTube-only and rejects a Twitch id outright — "Invalid video ID format:
  // 317451146103". A live broadcast is reachable at its channel URL, which
  // the subscription stored exactly when it was added.
  test('a live broadcast with no URL falls back to its stored channel URL', () async {
    final account = await _account();
    addTearDown(account.dispose);

    expect(youTubePlaybackUrl(_twitchItem(), account), 'https://www.twitch.tv/shroud');
  });

  // The channel URL points at whatever is on air now, so using it for a past
  // broadcast would quietly play the wrong thing.
  test('a past broadcast with no URL resolves to nothing rather than the channel', () async {
    final account = await _account();
    addTearDown(account.dispose);

    expect(youTubePlaybackUrl(_twitchItem(liveNow: false), account), isNull);
  });

  test('an unsubscribed channel has no stored URL to borrow', () async {
    final account = YatteeAccountProvider();
    await account.onActiveProfileChanged('user-1');
    addTearDown(account.dispose);

    expect(youTubePlaybackUrl(_twitchItem(), account), isNull);
  });

  test('YouTube items never take this path — they are fetched by id', () async {
    final account = await _account();
    addTearDown(account.dispose);
    final youTube = YouTubeMediaItems.fromSummary(
      const YatteeVideoSummary(
        videoId: 'dQw4w9WgXcQ',
        title: 'A video',
        author: 'a',
        authorId: 'UC1',
        lengthSeconds: 10,
      ),
    );

    expect(youTubePlaybackUrl(youTube, account), isNull);
  });
}
