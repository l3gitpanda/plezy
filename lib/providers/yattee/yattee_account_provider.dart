import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../mixins/disposable_change_notifier_mixin.dart';
import '../../models/yattee/yattee_session.dart';
import '../../media/media_item.dart';
import '../../models/yattee/yattee_site.dart';
import '../../models/yattee/yattee_video.dart';
import '../../models/yattee/youtube_media_item.dart';
import '../../services/yattee/yattee_auth_service.dart';
import '../../services/yattee/yattee_client.dart';
import '../../services/yattee/yattee_exceptions.dart';
import '../../services/yattee/yattee_store.dart';
import '../../services/yattee/yattee_stream_selector.dart';
import '../../utils/app_logger.dart';

/// Why a subscription seed produced what it did.
///
/// Yattee Server gates its channel list behind an admin account and prunes
/// channels nothing has asked about for 14 days, so an empty result has
/// several very different causes. Collapsing them into "nothing to import"
/// leaves the user with no idea what to do next.
enum YatteeSeedOutcome {
  /// Channels were added to the local list.
  imported,

  /// The server listed channels, but every one was already subscribed here.
  alreadyKnown,

  /// The server's channel list is empty — nothing has posted a feed to it
  /// recently, or its entries aged out.
  empty,

  /// HTTP 403: the signed-in account is not an administrator of the server.
  notAdmin,

  /// HTTP 404: this server predates the admin channel list.
  unsupported,

  /// Anything else — transport failure, unexpected status.
  failed,
}

/// Outcome of [YatteeAccountProvider.seedSubscriptionsFromServer].
class YatteeSeedResult {
  final YatteeSeedOutcome outcome;

  /// How many channels were added; zero for every non-[YatteeSeedOutcome.imported] outcome.
  final int added;

  /// Server-supplied detail for [YatteeSeedOutcome.failed].
  final String? error;

  const YatteeSeedResult(this.outcome, {this.added = 0, this.error});
}

/// Owns the active Yattee Server session for the currently-selected profile,
/// mirroring [SeerrAccountProvider]'s rebind shape: `onActiveProfileChanged`
/// loads the profile's stored session, subscriptions and quality cap and
/// rebuilds the API client.
///
/// The connect screen drives [YatteeAuthService] itself and hands the
/// finished session to [adoptSession]. Subscriptions live here rather than
/// on the server because Yattee Server's feed endpoint is stateless — it
/// expects the full channel list on every call — and the server keeps no
/// per-user list to sync against. [seedSubscriptionsFromServer] borrows the
/// server's global channel set once so a new device does not start empty.
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

  /// Watched marks in order, most recent last. A list rather than a set so
  /// the oldest can be dropped when the store trims (see
  /// [YatteeStore.maxWatchedEntries]); membership is answered by [_watchedLookup].
  List<String> _watched = const [];
  Set<String> _watchedLookup = const {};
  String _activeUserUuid = '';
  int _bindingGeneration = 0;

  YatteeSession? get session => _session;
  bool get isConnected => _session != null;
  String? get displayName => _session?.username;

  /// API client for the browse and playback surfaces; null when disconnected.
  YatteeClient? get client => _client;

  List<YatteeSubscription> get subscriptions => _subscriptions;

  /// This profile's subscriptions on one site, in stored order.
  ///
  /// The feed is fetched per site — each is its own row — because a single
  /// `POST /feed` merges everything it is given into one list, and because a
  /// site the server has disabled fails the whole call rather than its own
  /// share of it.
  List<YatteeSubscription> subscriptionsFor(YatteeSite site) => [
    for (final subscription in _subscriptions)
      if (subscription.site == site) subscription,
  ];

  /// Sites this profile actually follows anything on, so the UI can leave out
  /// a row nobody has subscriptions for.
  Set<YatteeSite> get subscribedSites => {for (final subscription in _subscriptions) subscription.site};

  YatteeQuality get quality => _quality;

  /// Key for one video's watched mark.
  ///
  /// Scoped by site because ids are only unique within one: a Twitch
  /// broadcast id and a YouTube video id could otherwise collide.
  static String watchedKeyFor(YatteeSite site, String videoId) => '${site.id}:$videoId';

  bool isVideoWatched(YatteeSite site, String videoId) => _watchedLookup.contains(watchedKeyFor(site, videoId));

  /// The card stand-in for [video], carrying this profile's watched mark.
  ///
  /// Every browse surface builds its items through here so the mark is never
  /// applied in some rows and not others.
  MediaItem toMediaItem(YatteeVideoSummary video) =>
      YouTubeMediaItems.fromSummary(video).withWatchedFlag(isVideoWatched(video.site, video.videoId));

  /// Re-apply the current marks to items already on screen.
  ///
  /// Marking one watched must not refetch a row; the flag is the only thing
  /// that changed, and it is derivable from the item itself.
  List<MediaItem> restampWatched(List<MediaItem> items) => [
    for (final item in items)
      if (item.youTubeVideoId case final videoId?)
        item.withWatchedFlag(isVideoWatched(item.youTubeSite, videoId))
      else
        item,
  ];

  /// Mark (or unmark) one video.
  ///
  /// Local only. Yattee Server keeps no watch state — it has no history,
  /// progress or mark-watched route — so there is nothing to report this to,
  /// and nothing that could report it back.
  Future<void> setVideoWatched(YatteeSite site, String videoId, bool watched) async {
    if (isDisposed) return;
    final key = watchedKeyFor(site, videoId);
    if (_watchedLookup.contains(key) == watched) return;
    _watched = [
      for (final entry in _watched)
        if (entry != key) entry,
      if (watched) key,
    ];
    _watchedLookup = _watched.toSet();
    safeNotifyListeners();
    final userUuid = _activeUserUuid;
    try {
      await _store.saveWatched(userUuid, _watched);
    } catch (e) {
      _logPersistenceFailure(e);
    }
  }

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
    // Quality is a preference and outlives a disconnect; the subscription
    // list does not — `clearSession` drops it with the session it belonged to.
    final subscriptions = await _store.loadSubscriptions(userUuid);
    final quality = await _store.loadQuality(userUuid);
    final watched = await _store.loadWatched(userUuid);
    if (!_isCurrentBinding(userUuid, generation)) return;
    _subscriptions = subscriptions;
    _quality = quality;
    _watched = watched;
    _watchedLookup = watched.toSet();
    _setSessionAndRebind(userUuid, generation, loaded);
    // Nothing stored yet on this device: try the server's channel set so the
    // Subscriptions row is populated without the user re-subscribing by hand.
    if (loaded != null && subscriptions.isEmpty) {
      unawaited(seedSubscriptionsFromServer());
    }
  }

  /// Merge the server's watched-channel set into the local list.
  ///
  /// Additive by construction: the server's set is global and lossy (see
  /// [YatteeClient.fetchWatchedChannels]), so it may omit channels the user
  /// subscribed to here and include ones they never did. Replacing the local
  /// list with it would silently drop the user's own choices, so entries are
  /// only ever added. The [YatteeSeedResult] says why nothing arrived when
  /// nothing does — the causes need different things from the user.
  Future<YatteeSeedResult> seedSubscriptionsFromServer() async {
    if (isDisposed) return const YatteeSeedResult(YatteeSeedOutcome.failed);
    final client = _client;
    if (client == null) return const YatteeSeedResult(YatteeSeedOutcome.failed);
    final userUuid = _activeUserUuid;
    final generation = _bindingGeneration;
    final List<YatteeSubscription> discovered;
    try {
      discovered = await client.fetchWatchedChannels();
    } on YatteeAuthException catch (e) {
      // 401 only: the credentials themselves were refused.
      appLogger.w('Yattee: the server refused the credentials (HTTP ${e.statusCode})');
      return YatteeSeedResult(YatteeSeedOutcome.failed, error: e.message);
    } on YatteeApiException catch (e) {
      appLogger.w('Yattee: the server rejected the channel list request (HTTP ${e.statusCode})');
      // 403 is "Admin privileges required" — the channel list is admin-only,
      // so a secondary account on a shared server can never read it. It
      // arrives here rather than as an auth failure because the account is
      // fine; it simply lacks the role.
      return YatteeSeedResult(switch (e.statusCode) {
        403 => YatteeSeedOutcome.notAdmin,
        404 => YatteeSeedOutcome.unsupported,
        _ => YatteeSeedOutcome.failed,
      }, error: e.message);
    } catch (e, stackTrace) {
      appLogger.w('Yattee: seeding subscriptions from the server failed', error: e, stackTrace: stackTrace);
      return YatteeSeedResult(YatteeSeedOutcome.failed, error: e.toString());
    }
    if (!_isCurrentBinding(userUuid, generation)) return const YatteeSeedResult(YatteeSeedOutcome.failed);
    if (discovered.isEmpty) return const YatteeSeedResult(YatteeSeedOutcome.empty);
    final known = {for (final subscription in _subscriptions) (subscription.site, subscription.channelId)};
    final added = [
      for (final subscription in discovered)
        if (!known.contains((subscription.site, subscription.channelId))) subscription,
    ];
    if (added.isEmpty) return const YatteeSeedResult(YatteeSeedOutcome.alreadyKnown);
    _subscriptions = [..._subscriptions, ...added];
    safeNotifyListeners();
    await _persistSubscriptions();
    appLogger.i('Yattee: seeded ${added.length} subscription(s) from the server');
    return YatteeSeedResult(YatteeSeedOutcome.imported, added: added.length);
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
    // First connect on this device: pull whatever channels the server already
    // knows about so the user's existing Yattee subscriptions carry over.
    unawaited(seedSubscriptionsFromServer());
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

  /// Channel ids are only unique within a site, so membership is keyed on
  /// both — a Twitch channel and a YouTube channel can share a name.
  bool isSubscribed(String channelId, {YatteeSite site = YatteeSite.youtube}) =>
      _subscriptions.any((s) => s.channelId == channelId && s.site == site);

  Future<void> subscribe(YatteeSubscription subscription) async {
    if (isDisposed || isSubscribed(subscription.channelId, site: subscription.site)) return;
    _subscriptions = [subscription, ..._subscriptions];
    safeNotifyListeners();
    await _persistSubscriptions();
  }

  Future<void> unsubscribe(String channelId, {YatteeSite site = YatteeSite.youtube}) async {
    if (isDisposed || !isSubscribed(channelId, site: site)) return;
    _subscriptions = [
      for (final s in _subscriptions)
        if (s.channelId != channelId || s.site != site) s,
    ];
    safeNotifyListeners();
    await _persistSubscriptions();
  }

  /// Writes the in-memory list to this profile's key. The key is captured
  /// before the await, so a profile switch mid-save still lands the old
  /// profile's list under the old profile's key rather than the new one's.
  Future<void> _persistSubscriptions() async {
    final userUuid = _activeUserUuid;
    try {
      await _store.saveSubscriptions(userUuid, _subscriptions);
    } catch (e) {
      _logPersistenceFailure(e);
    }
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
