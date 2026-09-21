import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/models/yattee/yattee_video.dart';
import 'package:plezy/models/yattee/youtube_media_item.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/widgets/media_card.dart';

import '../test_helpers/prefs.dart';
import '../test_helpers/media_items.dart';

MediaItem _youTube({int lengthSeconds = 212, bool liveNow = false}) => YouTubeMediaItems.fromSummary(
  YatteeVideoSummary(
    videoId: 'dQw4w9WgXcQ',
    title: 'A video',
    author: 'A channel',
    authorId: 'UC1',
    lengthSeconds: lengthSeconds,
    liveNow: liveNow,
  ),
);

/// [fullBleed] selects the other grid builder. Both matter: the TV browse
/// rail renders cards with `viewModeOverride: ViewMode.grid`, and switches to the full-bleed
/// one under the TV full-card layout setting — so the badge has to survive
/// both or it vanishes on exactly the surface it was asked for.
Future<void> pumpGridCard(WidgetTester tester, MediaItem item, {bool fullBleed = false}) {
  return tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        theme: monoTheme(dark: true),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 200,
              height: 160,
              child: MediaCard(
                item: item,
                width: 200,
                height: 120,
                viewModeOverride: ViewMode.grid,
                fullBleedImage: fullBleed,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    LocaleSettings.setLocaleSync(AppLocale.en);
    await SettingsService.getInstance();
  });

  testWidgets('a YouTube card shows its runtime on the poster', (tester) async {
    await pumpGridCard(tester, _youTube());
    await tester.pump();

    expect(find.text('3:32'), findsOneWidget);
    expect(find.byKey(const Key('media-card-duration')), findsOneWidget);
  });

  testWidgets('and shows it in the full-bleed layout the TV rail can use', (tester) async {
    await pumpGridCard(tester, _youTube(), fullBleed: true);
    await tester.pump();

    expect(find.text('3:32'), findsOneWidget);
  });

  // A live broadcast reports zero length; a runtime there would be a lie.
  testWidgets('a live card shows none', (tester) async {
    await pumpGridCard(tester, _youTube(lengthSeconds: 0, liveNow: true));
    await tester.pump();

    expect(find.byKey(const Key('media-card-duration')), findsNothing);
  });

  // Server-backed items state their runtime on a detail screen; the badge is
  // for stand-ins that play straight from the card.
  testWidgets('a server-backed card is unchanged', (tester) async {
    await pumpGridCard(tester, testMediaItem(id: 'm1', title: 'Movie', durationMs: 5400000));
    await tester.pump();

    expect(find.byKey(const Key('media-card-duration')), findsNothing);
  });
}
