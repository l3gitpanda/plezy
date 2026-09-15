import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../mixins/disposable_change_notifier_mixin.dart';
import '../../models/yattee/yattee_session.dart';
import '../../media/media_item.dart';
import '../../models/yattee/yattee_site.dart';
import '../../models/yattee/yattee_video.dart';
import '../../models/yattee/yattee_watch_progress.dart';
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

  /// Resume points in order, least recently updated first — the order the
  /// store trims from. Keyed lookup lives in [_progressLookup].
  List<YatteeWatchProgress> _progress = const [];
  Map<String, YatteeWatchProgress> _progressLookup = const {};
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

  /// Key for one video's watched mark and resume point.
  ///
  /// Scoped by site because ids are only unique within one: a Twitch
  /// broadcast id and a YouTube video id could otherwise collide.
  static String watchedKeyFor(YatteeSite site, String videoId) => '${site.id}:$videoId';

  bool isVideoWatched(YatteeSite site, String videoId) => _watchedLookup.contains(watchedKeyFor(site, videoId));

  /// Videos with a resume point, most recently watched first.
  ///
  /// Marking one watched removes it, so a finished video never lingers here
  /// — [recordProgress] and [setVideoWatched] both drop the entry rather than
  /// leaving the row to filter it out.
  List<YatteeWatchProgress> get continueWatching => _progress.reversed.toList(growable: false);

  /// Where playback of [videoId] should pick up, or null for a video with no
  /// stored resume point.
  int? resumePositionMsFor(YatteeSite site, String videoId) =>
      _progressLookup[watchedKeyFor(site, videoId)]?.positionMs;

  /// The card stand-in for [video], carrying this profile's watched mark and
  /// resume point.
  ///
  /// Every browse surface builds its items through here so neither is applied
  /// in some rows and not others.
  MediaItem toMediaItem(YatteeVideoSummary video) => _stampLocalState(YouTubeMediaItems.fromSummary(video));

  /// Re-apply the current marks and resume points to items already on screen.
  ///
  /// Marking one watched must not refetch a row; the flag is the only thing
  /// that changed, and it is derivable from the item itself.
  List<MediaItem> restampWatched(List<MediaItem> items) => [for (final item in items) _stampLocalState(item)];

  /// Applies whatever this profile knows about [item] locally: the watched
  /// flag, and the view offset the card draws its progress bar from.
  ///
  /// The offset goes on `viewOffsetMs` — the same field a server-backed item
  /// carries it in — so the shared card, the watched indicator and the
  /// player's own resume resolution all read it without a YouTube special
  /// case.
  MediaItem _stampLocalState(MediaItem item) {
    final videoId = item.youTubeVideoId;
    if (videoId == null) return item;
    final site = item.youTubeSite;
    final stamped = item.withWatchedFlag(isVideoWatched(site, videoId));
    final progress = _progressLookup[watchedKeyFor(site, videoId)];
    if (progress == null) return stamped;
    // The runtime playback reported wins over the listing's `lengthSeconds`,
    // which is zero on a fair number of rows; without a duration the card has
    // nothing to draw the bar against.
    return stamped.copyWith(
      viewOffsetMs: progress.positionMs,
      durationMs: stamped.durationMs ?? (progress.durationMs > 0 ? progress.durationMs : null),
    );
  }

  /// Mark (or unmark) one video.
  ///
  /// Local only. Yattee Server keeps no watch state — it has no history,
  /// progress or mark-watched route — so there is nothing to report this to,
  /// and nothing that could report it back.
  ///
  /// Marking watched also drops the resume point: the video is finished, so
  /// leaving it in Continue Watching would offer to resume something the user
  /// just said they were done with.
  Future<void> setVideoWatched(YatteeSite site, String videoId, bool watched) async {
    if (isDisposed) return;
    final key = watchedKeyFor(site, videoId);
    final droppedProgress = watched && _progressLookup.containsKey(key);
    if (_watchedLookup.contains(key) == watched && !droppedProgress) return;
    _watched = [
      for (final entry in _watched)
        if (entry != key) entry,
      if (watched) key,
    ];
    _watchedLookup = _watched.toSet();
    if (droppedProgress) _setProgress(_withoutKey(key));
    safeNotifyListeners();
    final userUuid = _activeUserUuid;
    try {
      await _store.saveWatched(userUuid, _watched);
      if (droppedProgress) await _store.saveProgress(userUuid, _progress);
    } catch (e) {
      _logPersistenceFailure(e);
    }
  }

  /// Record how far into [video] playback got.
  ///
  /// The entry moves to the end of the list so the row reads most-recent-first
  /// and the store trims the least recently watched. Called from the player on
  /// a timer and once more when the session ends.
  Future<void> recordProgress(YatteeVideoSummary video, {required int positionMs, required int durationMs}) async {
    if (isDisposed) return;
    final key = watchedKeyFor(video.site, video.videoId);
    final existing = _progressLookup[key];
    // Same second, same entry: the player samples far more often than the
    // position meaningfully changes, and every write is a full re-encode of
    // the list.
    if (existing != null && existing.positionMs ~/ 1000 == positionMs ~/ 1000) return;
    _setProgress([
      ..._withoutKey(key),
      YatteeWatchProgress(
        video: video,
        positionMs: positionMs,
        durationMs: durationMs,
        updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      ),
    ]);
    safeNotifyListeners();
    try {
      await _store.saveProgress(_activeUserUuid, _progress);
    } catch (e) {
      _logPersistenceFailure(e);
    }
  }

  /// Forget one video's resume point without marking it watched — the
  /// "remove from Continue Watching" action.
  Future<void> clearProgress(YatteeSite site, String videoId) async {
    if (isDisposed) return;
    final key = watchedKeyFor(site, videoId);
    if (!_progressLookup.containsKey(key)) return;
    _setProgress(_withoutKey(key));
    safeNotifyListeners();
    try {
      await _store.saveProgress(_activeUserUuid, _progress);
    } catch (e) {
      _logPersistenceFailure(e);
    }
  }

  List<YatteeWatchProgress> _withoutKey(String key) => [
    for (final entry in _progress)
      if (watchedKeyFor(entry.site, entry.videoId) != key) entry,
  ];

  void _setProgress(List<YatteeWatchProgress> progress) {
    _progress = progress;
    _progressLookup = {for (final entry in progress) watchedKeyFor(entry.site, entry.videoId): entry};
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
    final progress = await _store.loadProgress(userUuid);
    if (!_isCurrentBinding(userUuid, generation)) return;
    _subscriptions = subscriptions;
    _quality = quality;
    _watched = watched;
    _watchedLookup = watched.toSet();
    _setProgress(progress);
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
