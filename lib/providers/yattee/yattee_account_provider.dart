import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../mixins/disposable_change_notifier_mixin.dart';
import '../../models/yattee/yattee_session.dart';
import '../../services/yattee/yattee_auth_service.dart';
import '../../services/yattee/yattee_client.dart';
import '../../services/yattee/yattee_store.dart';
import '../../services/yattee/yattee_stream_selector.dart';
import '../../utils/app_logger.dart';

/// Owns the active Yattee Server session for the currently-selected profile,
/// mirroring [SeerrAccountProvider]'s rebind shape: `onActiveProfileChanged`
/// loads the profile's stored session, subscriptions and quality cap and
/// rebuilds the API client.
///
/// The connect screen drives [YatteeAuthService] itself and hands the
/// finished session to [adoptSession]. Subscriptions live here rather than
/// on the server because Yattee Server's feed endpoint is stateless — it
/// expects the full channel list on every call.
class YatteeAccountProvider extends ChangeNotifier with DisposableChangeNotifierMixin {
  YatteeAccountProvider({YatteeStore? store, YatteeAuthService? authService})
    : _store = store ?? const YatteeStore(),
      authService = authService ?? YatteeAuthService();

  final YatteeStore _store;
  final YatteeAuthService authService;

  YatteeSession? _session;
  YatteeClient? _client;
  List<YatteeSubscription> _subscriptions = const [];
  YatteeQuality _quality = YatteeQuality.best;
  String _activeUserUuid = '';
  int _bindingGeneration = 0;

  YatteeSession? get session => _session;
  bool get isConnected => _session != null;
  String? get displayName => _session?.username;

  /// API client for the browse and playback surfaces; null when disconnected.
  YatteeClient? get client => _client;

  List<YatteeSubscription> get subscriptions => _subscriptions;

  YatteeQuality get quality => _quality;

  void _logPersistenceFailure(Object e) => appLogger.w('Yattee: persistence failed', error: e);

  /// Called whenever the active profile changes (or on initial load).
  Future<void> onActiveProfileChanged(String? newUserUuid) async {
    if (isDisposed) return;
    final userUuid = newUserUuid ?? '';
    final generation = ++_bindingGeneration;
    _activeUserUuid = userUuid;
    _setSessionAndRebind(userUuid, generation, null);
    if (!_isCurrentBinding(userUuid, generation)) return;
    final loaded = await _store.loadSession(userUuid);
    if (!_isCurrentBinding(userUuid, generation)) return;
    // Subscriptions and quality are only meaningful alongside a session, but
    // they load regardless so a reconnect keeps the list.
    final subscriptions = await _store.loadSubscriptions(userUuid);
    final quality = await _store.loadQuality(userUuid);
    if (!_isCurrentBinding(userUuid, generation)) return;
    _subscriptions = subscriptions;
    _quality = quality;
    _setSessionAndRebind(userUuid, generation, loaded);
  }

  /// Persist and bind a session the connect screen established.
  Future<void> adoptSession(YatteeSession session) async {
    if (isDisposed) return;
    final userUuid = _activeUserUuid;
    final generation = ++_bindingGeneration;
    _setSessionAndRebind(userUuid, generation, null);
    if (!_isCurrentBinding(userUuid, generation)) return;
    await _store.saveSession(userUuid, session);
    _setSessionAndRebind(userUuid, generation, session);
  }

  /// Forget the instance. Basic Auth has no server-side session to revoke.
  Future<void> disconnect() async {
    if (isDisposed) return;
    final userUuid = _activeUserUuid;
    final generation = ++_bindingGeneration;
    _subscriptions = const [];
    _setSessionAndRebind(userUuid, generation, null);
    if (!_isCurrentBinding(userUuid, generation)) return;
    await _store.clearSession(userUuid);
  }

  bool isSubscribed(String channelId) => _subscriptions.any((s) => s.channelId == channelId);

  Future<void> subscribe(YatteeSubscription subscription) async {
    if (isDisposed || isSubscribed(subscription.channelId)) return;
    _subscriptions = [subscription, ..._subscriptions];
    safeNotifyListeners();
    await _persistSubscriptions();
  }

  Future<void> unsubscribe(String channelId) async {
    if (isDisposed || !isSubscribed(channelId)) return;
    _subscriptions = [
      for (final s in _subscriptions)
        if (s.channelId != channelId) s,
    ];
    safeNotifyListeners();
    await _persistSubscriptions();
  }

  Future<void> _persistSubscriptions() async {
    final userUuid = _activeUserUuid;
    final generation = _bindingGeneration;
    try {
      await _store.saveSubscriptions(userUuid, _subscriptions);
    } catch (e) {
      _logPersistenceFailure(e);
    }
    // A profile switch mid-save must not leak the old list into the new
    // profile; the store keys by profile, so only the in-memory copy matters.
    if (!_isCurrentBinding(userUuid, generation)) return;
  }

  Future<void> setQuality(YatteeQuality quality) async {
    if (isDisposed || _quality == quality) return;
    _quality = quality;
    safeNotifyListeners();
    try {
      await _store.saveQuality(_activeUserUuid, quality);
    } catch (e) {
      _logPersistenceFailure(e);
    }
  }

  void _setSessionAndRebind(String userUuid, int generation, YatteeSession? session) {
    if (!_isCurrentBinding(userUuid, generation)) return;
    _session = session;
    _client?.dispose();
    // The auth service's client factory is a test seam (null in
    // production); sharing it lets one MockClient serve both.
    _client = session == null ? null : YatteeClient(session, httpClient: authService.httpClientFactory?.call());
    safeNotifyListeners();
  }

  bool _isCurrentBinding(String userUuid, int generation) {
    return !isDisposed && userUuid == _activeUserUuid && generation == _bindingGeneration;
  }

  @override
  void dispose() {
    _client?.dispose();
    _client = null;
    super.dispose();
  }
}
