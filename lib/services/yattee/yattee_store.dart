import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../models/yattee/yattee_session.dart';
import '../../models/yattee/yattee_watch_progress.dart';
import '../../profiles/profile.dart';
import '../../utils/serial_future_queue.dart';
import '../base_shared_preferences_service.dart';
import '../credential_vault.dart';
import 'yattee_stream_selector.dart';

/// Per-profile persistence for the YouTube integration: the Yattee Server
/// session, the client-held subscription list and the playback quality cap.
/// Mirrors `SeerrSessionStore`'s `user_{uuid}_{baseKey}` scoping.
///
/// The password ([YatteeSession.secret]) is CredentialVault-protected at the
/// store boundary; a failed decrypt degrades to an empty secret (API calls
/// then fail with 401 and the settings screen asks for a reconnect) rather
/// than dropping the session.
class YatteeStore {
  static const String _sessionKey = 'yattee_session';
  static const String _subscriptionsKey = 'yattee_subscriptions';
  static const String _qualityKey = 'yattee_quality';
  static const String _watchedKey = 'yattee_watched';
  static const String _progressKey = 'yattee_progress';

  // Shared across profile-keyed provider/store lifetimes. Enqueue the entire
  // operation before any preferences/vault await so a new load or clear cannot
  // overtake an old provider's still-encrypting save.
  static final SerialFutureQueue _persistence = SerialFutureQueue();

  const YatteeStore();

  /// Drop anything still queued on the shared persistence queue. Test-only.
  ///
  /// The queue is static so that a profile switch cannot interleave writes,
  /// which means it also outlives any one test. A widget test that starts a
  /// write inside its fake-async zone leaves that write pending forever once
  /// the zone ends, and every later test in the file would then queue behind
  /// it and hang.
  @visibleForTesting
  static void resetForTesting() => _persistence.reset();

  String _scopedKey(String userUuid, String baseKey) => profileScopedPrefsKey(userUuid, baseKey);

  /// How many watched marks are kept per profile before the oldest are
  /// dropped. Generous for a browse history, small enough that the blob stays
  /// a few tens of kilobytes.
  static const int maxWatchedEntries = 2000;

  Future<YatteeSession?> loadSession(String userUuid) => _persistence.run(() async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    // Outside the try below on purpose: an unreadable credential must
    // reach the repair prompt, not be swallowed as 'no session'.
    final raw = readTolerantString(prefs, _scopedKey(userUuid, _sessionKey));
    if (raw == null) return null;
    try {
      final session = YatteeSession.decode(raw);
      if (session.secret.isEmpty) return session;
      return session.copyWith(secret: await CredentialVault.reveal(session.secret) ?? '');
    } catch (_) {
      return null;
    }
  });

  Future<void> saveSession(String userUuid, YatteeSession session) => _persistence.run(() async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    final protected = session.secret.isEmpty
        ? session
        : session.copyWith(secret: await CredentialVault.protect(session.secret));
    await prefs.setString(_scopedKey(userUuid, _sessionKey), protected.encode());
  });

  /// Forgets the session and the subscriptions with it: the list belongs to
  /// the instance the user just disconnected from.
  Future<void> clearSession(String userUuid) => _persistence.run(() async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    await prefs.remove(_scopedKey(userUuid, _sessionKey));
    await prefs.remove(_scopedKey(userUuid, _subscriptionsKey));
  });

  Future<List<YatteeSubscription>> loadSubscriptions(String userUuid) => _persistence.run(() async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    final raw = readTolerantString(prefs, _scopedKey(userUuid, _subscriptionsKey));
    if (raw == null) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final entry in decoded)
          if (entry is Map) YatteeSubscription.fromJson(entry.cast<String, Object?>()),
      ];
    } catch (_) {
      return const [];
    }
  });

  Future<void> saveSubscriptions(String userUuid, List<YatteeSubscription> subscriptions) => _persistence.run(() async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    await prefs.setString(
      _scopedKey(userUuid, _subscriptionsKey),
      jsonEncode([for (final subscription in subscriptions) subscription.toJson()]),
    );
  });

  /// Videos this profile has marked watched, oldest first.
  ///
  /// Kept here rather than on the server because Yattee Server has no watch
  /// state to keep it in: it exposes no history, progress or mark-watched
  /// route of any kind. So this is Plezy's own record and travels with the
  /// profile, not the instance.
  Future<List<String>> loadWatched(String userUuid) => _persistence.run(() async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    final raw = readTolerantString(prefs, _scopedKey(userUuid, _watchedKey));
    if (raw == null) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final entry in decoded)
          if (entry is String && entry.isNotEmpty) entry,
      ];
    } catch (_) {
      return const [];
    }
  });

  /// Writes the list, keeping only the most recent [maxWatchedEntries].
  ///
  /// Preferences are a single blob rewritten on every change, so an unbounded
  /// list would grow the write forever. The oldest marks are the ones least
  /// likely to be looked at again.
  Future<void> saveWatched(String userUuid, List<String> watched) => _persistence.run(() async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    final bounded = watched.length <= maxWatchedEntries ? watched : watched.sublist(watched.length - maxWatchedEntries);
    await prefs.setString(_scopedKey(userUuid, _watchedKey), jsonEncode(bounded));
  });

  /// How many resume points are kept per profile. Each carries the video
  /// summary it needs to draw a card, so entries are much larger than a
  /// watched mark; a Continue Watching row nobody scrolls past the first
  /// screen of does not need more than this.
  static const int maxProgressEntries = 100;

  /// This profile's resume points, most recently updated last.
  ///
  /// Local for the same reason [loadWatched] is: Yattee Server stores no
  /// playback position, so there is nowhere else for one to live.
  Future<List<YatteeWatchProgress>> loadProgress(String userUuid) => _persistence.run(() async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    final raw = readTolerantString(prefs, _scopedKey(userUuid, _progressKey));
    if (raw == null) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [
        for (final entry in decoded)
          if (entry is Map)
            if (YatteeWatchProgress.fromJson(entry.cast<String, Object?>()) case final progress
                when progress.videoId.isNotEmpty)
              progress,
      ];
    } catch (_) {
      return const [];
    }
  });

  /// Writes the list, keeping only the most recently updated
  /// [maxProgressEntries].
  Future<void> saveProgress(String userUuid, List<YatteeWatchProgress> progress) => _persistence.run(() async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    final bounded = progress.length <= maxProgressEntries
        ? progress
        : progress.sublist(progress.length - maxProgressEntries);
    await prefs.setString(
      _scopedKey(userUuid, _progressKey),
      jsonEncode([for (final entry in bounded) entry.toJson()]),
    );
  });

  Future<YatteeQuality> loadQuality(String userUuid) => _persistence.run(() async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    final raw = readTolerantString(prefs, _scopedKey(userUuid, _qualityKey));
    return YatteeQuality.values.asNameMap()[raw] ?? YatteeQuality.best;
  });

  Future<void> saveQuality(String userUuid, YatteeQuality quality) => _persistence.run(() async {
    final prefs = await BaseSharedPreferencesService.sharedCache();
    await prefs.setString(_scopedKey(userUuid, _qualityKey), quality.name);
  });
}
