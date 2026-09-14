import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/models/yattee/yattee_session.dart';
import 'package:plezy/models/yattee/yattee_site.dart';

void main() {
  group('YatteeSite.fromId', () {
    test('maps the server extractor ids', () {
      expect(YatteeSite.fromId('twitch'), YatteeSite.twitch);
      expect(YatteeSite.fromId('Twitch'), YatteeSite.twitch);
      expect(YatteeSite.fromId('youtube'), YatteeSite.youtube);
    });

    // Everything stored before sites existed is YouTube, and so is anything
    // from an extractor this build has no row for.
    test('falls back to YouTube for missing and unknown ids', () {
      expect(YatteeSite.fromId(null), YatteeSite.youtube);
      expect(YatteeSite.fromId(''), YatteeSite.youtube);
      expect(YatteeSite.fromId('vimeo'), YatteeSite.youtube);
    });
  });

  group('YatteeSite.channelUrlFor', () {
    test('builds a URL from the bare name a person would type on a remote', () {
      expect(YatteeSite.channelUrlFor(YatteeSite.twitch, 'shroud'), 'https://www.twitch.tv/shroud');
      expect(YatteeSite.channelUrlFor(YatteeSite.twitch, '  shroud  '), 'https://www.twitch.tv/shroud');
      expect(YatteeSite.channelUrlFor(YatteeSite.youtube, '@veritasium'), 'https://www.youtube.com/@veritasium');
    });

    test('passes a pasted URL through unchanged', () {
      expect(
        YatteeSite.channelUrlFor(YatteeSite.twitch, 'https://www.twitch.tv/shroud'),
        'https://www.twitch.tv/shroud',
      );
    });

    test('rejects input that would build a nonsense URL', () {
      expect(YatteeSite.channelUrlFor(YatteeSite.twitch, ''), isNull);
      expect(YatteeSite.channelUrlFor(YatteeSite.twitch, '   '), isNull);
      expect(YatteeSite.channelUrlFor(YatteeSite.twitch, '@'), isNull);
      // A partial path is neither a name nor a URL.
      expect(YatteeSite.channelUrlFor(YatteeSite.twitch, 'twitch.tv/shroud'), isNull);
      expect(YatteeSite.channelUrlFor(YatteeSite.twitch, 'https://'), isNull);
    });
  });

  group('YatteeSubscription', () {
    test('round-trips its site and channel URL', () {
      const subscription = YatteeSubscription(
        channelId: 'shroud',
        name: 'shroud',
        site: YatteeSite.twitch,
        channelUrl: 'https://www.twitch.tv/shroud',
      );

      final restored = YatteeSubscription.fromJson(subscription.toJson().cast<String, Object?>());

      expect(restored.site, YatteeSite.twitch);
      expect(restored.channelUrl, 'https://www.twitch.tv/shroud');
      expect(restored.channelId, 'shroud');
    });

    // Subscriptions persisted by an earlier build have neither field.
    test('reads a pre-site stored subscription as YouTube', () {
      final restored = YatteeSubscription.fromJson(const {
        'channel_id': 'UC123',
        'name': 'A channel',
        'avatar_url': null,
      });

      expect(restored.site, YatteeSite.youtube);
      expect(restored.channelUrl, isNull);
    });
  });
}
