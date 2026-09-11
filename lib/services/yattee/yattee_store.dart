import 'dart:convert';

import '../../models/yattee/yattee_session.dart';
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

  // Shared across profile-keyed provider/store lifetimes. Enqueue the entire
  // operation before any preferences/vault await so a new load or clear cannot
  // overtake an old provider's still-encrypting save.
  static final SerialFutureQueue _persistence = SerialFutureQueue();

  const YatteeStore();

  String _scopedKey(String userUuid, String baseKey) => profileScopedPrefsKey(userUuid, baseKey);

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
