import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/navigation/navigation_tabs.dart';

void main() {
  group('YouTube tab visibility', () {
    test('hides YouTube until a Yattee Server is connected', () {
      final without = NavigationTab.getVisibleTabs(isOffline: false, hasLiveTv: true, hasExplore: true);
      expect(without.map((tab) => tab.id), isNot(contains(NavigationTabId.youTube)));

      final ids = NavigationTab.getVisibleTabs(
        isOffline: false,
        hasLiveTv: true,
        hasExplore: true,
        hasYouTube: true,
      ).map((tab) => tab.id).toList();
      expect(ids, contains(NavigationTabId.youTube));
      // YouTube sits after Explore, directly before Search.
      expect(ids.indexOf(NavigationTabId.youTube), ids.indexOf(NavigationTabId.explore) + 1);
      expect(ids.indexOf(NavigationTabId.youTube), ids.indexOf(NavigationTabId.search) - 1);
    });

    test('YouTube is online-only', () {
      final offline = NavigationTab.getVisibleTabs(isOffline: true, hasYouTube: true);
      expect(offline.map((tab) => tab.id), isNot(contains(NavigationTabId.youTube)));
    });

    test('resolveDefaultTab honours a visible YouTube preference and falls back otherwise', () {
      expect(
        NavigationTab.resolveDefaultTab(
          isOffline: false,
          hasLiveTv: false,
          hasYouTube: true,
          preferredStartup: NavigationTabId.youTube,
        ),
        NavigationTabId.youTube,
      );
      expect(
        NavigationTab.resolveDefaultTab(isOffline: false, hasLiveTv: false, preferredStartup: NavigationTabId.youTube),
        NavigationTabId.discover,
      );
    });
  });
}
