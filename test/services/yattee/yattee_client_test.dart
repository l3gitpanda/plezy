import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/models/yattee/yattee_session.dart';
import 'package:plezy/services/yattee/yattee_auth_service.dart';
import 'package:plezy/services/yattee/yattee_client.dart';
import 'package:plezy/services/yattee/yattee_exceptions.dart';
import 'package:plezy/services/yattee/yattee_http_client.dart';

YatteeSession _session({String baseUrl = 'https://yattee.example.com'}) => YatteeSession(
  baseUrl: baseUrl,
  username: 'alice',
  secret: 'hunter2',
  instanceLabel: 'Yattee Server',
  version: '1.0.9',
  createdAt: 0,
);

http.Response _json(Object body, {int status = 200}) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

Map<String, dynamic> _video(String id) => {
  'type': 'video',
  'videoId': id,
  'title': 'Video $id',
  'author': 'Author',
  'authorId': 'UC1',
  'lengthSeconds': 60,
  'published': id.hashCode % 1000,
  'videoThumbnails': [],
  'liveNow': false,
  'isUpcoming': false,
};

/// `Basic base64("alice:hunter2")`, what every `/api/v1` request must carry.
const _expectedAuthorization = 'Basic YWxpY2U6aHVudGVyMg==';

void main() {
  setUpAll(() {
    LocaleSettings.setLocaleSync(AppLocale.en);
  });

  group('YatteeHttpClient', () {
    test('sends Basic Auth and encodes query spaces as %20', () async {
      late http.Request seen;
      final client = YatteeHttpClient(
        baseUrl: 'https://yattee.example.com/',
        username: 'alice',
        password: 'hunter2',
        httpClient: MockClient((request) async {
          seen = request;
          return _json([]);
        }),
      );
      await client.send('GET', '/api/v1/search', query: {'q': 'never gonna', 'page': 1});
      expect(seen.url.toString(), 'https://yattee.example.com/api/v1/search?q=never%20gonna&page=1');
      expect(seen.headers['Authorization'], _expectedAuthorization);
      expect(seen.headers['Accept'], 'application/json');
    });

    test('maps 401 to an auth exception carrying FastAPI detail', () async {
      final client = YatteeHttpClient(
        baseUrl: 'https://yattee.example.com',
        username: 'alice',
        password: 'wrong',
        httpClient: MockClient((_) async => _json({'detail': 'Invalid credentials'}, status: 401)),
      );
      await expectLater(
        client.send('GET', '/api/v1/trending'),
        throwsA(isA<YatteeAuthException>().having((e) => e.message, 'message', 'Invalid credentials')),
      );
    });

    test('maps other failures to an API exception', () async {
      final client = YatteeHttpClient(
        baseUrl: 'https://yattee.example.com',
        httpClient: MockClient((_) async => _json({'detail': 'Video not found'}, status: 404)),
      );
      await expectLater(
        client.send('GET', '/api/v1/videos/x'),
        throwsA(isA<YatteeApiException>().having((e) => e.statusCode, 'status', 404)),
      );
    });
  });

  group('YatteeClient', () {
    test('trending and popular decode the bare video array', () async {
      final client = YatteeClient(
        _session(),
        httpClient: MockClient((request) async {
          expect(request.headers['Authorization'], _expectedAuthorization);
          if (request.url.path == '/api/v1/trending') {
            expect(request.url.queryParameters['region'], 'GB');
            return _json([_video('a'), _video('b')]);
          }
          expect(request.url.path, '/api/v1/popular');
          return _json([_video('c')]);
        }),
      );
      final trending = await client.fetchTrending(region: 'GB');
      expect(trending.map((v) => v.videoId), ['a', 'b']);
      final popular = await client.fetchPopular();
      expect(popular.map((v) => v.videoId), ['c']);
    });

    test('feed posts the subscription list in the server\'s snake_case shape', () async {
      late Map<String, dynamic> body;
      final client = YatteeClient(
        _session(),
        httpClient: MockClient((request) async {
          expect(request.method, 'POST');
          expect(request.url.path, '/api/v1/feed');
          expect(request.headers['Content-Type'], startsWith('application/json'));
          body = jsonDecode(request.body) as Map<String, dynamic>;
          return _json({
            'status': 'ready',
            'videos': [_video('x')],
            'total': 1,
            'has_more': false,
            'ready_count': 2,
            'pending_count': 0,
            'error_count': 0,
            'eta_seconds': null,
          });
        }),
      );
      final page = await client.fetchFeed(const [
        YatteeSubscription(channelId: 'UC1', name: 'One', avatarUrl: 'https://a/1.jpg'),
        YatteeSubscription(channelId: '@two', name: 'Two'),
      ], limit: 25);
      expect(body['limit'], 25);
      expect(body['offset'], 0);
      expect(body['channels'], [
        {'channel_id': 'UC1', 'site': 'youtube', 'channel_name': 'One', 'avatar_url': 'https://a/1.jpg'},
        {'channel_id': '@two', 'site': 'youtube', 'channel_name': 'Two'},
      ]);
      expect(page.status, 'ready');
      expect(page.videos.single.videoId, 'x');
      expect(page.readyCount, 2);
    });

    test('feed skips the network entirely with no subscriptions', () async {
      final client = YatteeClient(_session(), httpClient: MockClient((_) async => fail('no request expected')));
      final page = await client.fetchFeed(const []);
      expect(page.videos, isEmpty);
      expect(page.isFetching, isFalse);
    });

    test('feed chunks more than 500 channels and merges the pages newest first', () async {
      var calls = 0;
      final client = YatteeClient(
        _session(),
        httpClient: MockClient((request) async {
          final channels = (jsonDecode(request.body) as Map)['channels'] as List;
          calls++;
          expect(channels.length, lessThanOrEqualTo(500));
          return _json({
            'status': calls == 1 ? 'ready' : 'fetching',
            'videos': [
              {..._video('call$calls-old'), 'published': 10},
              {..._video('call$calls-new'), 'published': 100 * calls},
            ],
            'total': 2,
            'has_more': false,
            'ready_count': 1,
            'pending_count': calls == 1 ? 0 : 1,
            'error_count': 0,
            'eta_seconds': calls == 1 ? null : 6,
          });
        }),
      );
      final page = await client.fetchFeed([
        for (var i = 0; i < 501; i++) YatteeSubscription(channelId: 'UC$i', name: '$i'),
      ]);
      expect(calls, 2);
      expect(page.videos.map((v) => v.videoId).take(2), ['call2-new', 'call1-new']);
      expect(page.status, 'fetching');
      expect(page.total, 4);
      expect(page.pendingCount, 1);
      expect(page.etaSeconds, 6);
    });

    test('search asks for every type by default and splits the mixed hits', () async {
      final client = YatteeClient(
        _session(),
        httpClient: MockClient((request) async {
          expect(request.url.path, '/api/v1/search');
          expect(request.url.queryParameters, {'q': 'rick', 'page': '1', 'type': 'all'});
          return _json([
            _video('v'),
            {'type': 'channel', 'authorId': 'UC9', 'author': 'Rick', 'authorThumbnails': [], 'authorVerified': false},
          ]);
        }),
      );
      final results = await client.search('rick');
      expect(results.videos.single.videoId, 'v');
      expect(results.channels.single.authorId, 'UC9');
    });

    test('suggestions decode the bare string array and ignore junk', () async {
      final client = YatteeClient(_session(), httpClient: MockClient((_) async => _json(['a', 'b', 3, ''])));
      expect(await client.searchSuggestions('x'), ['a', 'b']);
    });

    test('channel and channel videos map the envelope and echo the continuation', () async {
      final client = YatteeClient(
        _session(),
        httpClient: MockClient((request) async {
          if (request.url.path == '/api/v1/channels/%40handle') {
            return _json({
              'authorId': 'UC5',
              'author': 'Handle',
              'description': 'd',
              'subCount': 5,
              'totalViews': 9,
              'authorThumbnails': [],
              'authorBanners': [],
              'authorVerified': true,
            });
          }
          expect(request.url.path, '/api/v1/channels/UC5/videos');
          expect(request.url.queryParameters['continuation'], 'tok1');
          return _json({
            'videos': [_video('p2')],
            'continuation': null,
          });
        }),
      );
      final channel = await client.fetchChannel('@handle');
      expect(channel.authorId, 'UC5');
      expect(channel.totalViews, 9);
      final page = await client.fetchChannelVideos('UC5', continuation: 'tok1');
      expect(page.videos.single.videoId, 'p2');
      expect(page.continuation, isNull);
    });

    test('watched channels seed maps rows, filters non-YouTube sites, and skips blanks', () async {
      late Uri seen;
      final client = YatteeClient(
        _session(),
        httpClient: MockClient((request) async {
          seen = request.url;
          expect(request.headers['Authorization'], _expectedAuthorization);
          return _json([
            {'channel_id': 'UC1', 'site': 'youtube', 'channel_name': 'One', 'avatar_url': 'https://a/1.jpg'},
            // Name absent: the id stands in so the row is still usable.
            {'channel_id': 'UC2', 'site': 'youtube', 'channel_name': null, 'avatar_url': null},
            // Another extractor's channel must not become a YouTube subscription.
            {'channel_id': 'S1', 'site': 'peertube', 'channel_name': 'Other'},
            // Unusable rows are dropped rather than producing empty entries.
            {'channel_id': '', 'site': 'youtube', 'channel_name': 'Blank'},
            {'site': 'youtube', 'channel_name': 'No id'},
          ]);
        }),
      );
      final seeded = await client.fetchWatchedChannels();
      // Root-mounted admin router: NOT under /api/v1.
      expect(seen.path, '/api/watched-channels');
      expect(seeded.map((s) => s.channelId), ['UC1', 'UC2']);
      expect(seeded.first.name, 'One');
      expect(seeded.first.avatarUrl, 'https://a/1.jpg');
      expect(seeded.last.name, 'UC2');
      expect(seeded.last.avatarUrl, isNull);
    });

    test('watched channels treats a non-admin 403 as simply having no seed', () async {
      final client = YatteeClient(
        _session(),
        httpClient: MockClient((_) async => _json({'detail': 'Admin access required'}, status: 403)),
      );
      expect(await client.fetchWatchedChannels(), isEmpty);
    });

    test('watched channels tolerates an unexpected body shape', () async {
      final client = YatteeClient(_session(), httpClient: MockClient((_) async => _json({'nope': true})));
      expect(await client.fetchWatchedChannels(), isEmpty);
    });

    test('video always asks the server to relay the streams', () async {
      final client = YatteeClient(
        _session(),
        httpClient: MockClient((request) async {
          expect(request.url.path, '/api/v1/videos/dQw4w9WgXcQ');
          expect(request.url.queryParameters, {'proxy': 'true', 'proxy_mode': 'relay'});
          return _json({..._video('dQw4w9WgXcQ'), 'adaptiveFormats': [], 'formatStreams': [], 'captions': []});
        }),
      );
      final video = await client.fetchVideo('dQw4w9WgXcQ');
      expect(video.videoId, 'dQw4w9WgXcQ');
    });
  });

  group('YatteeAuthService', () {
    test('expands schemeless input into TLS first, then plain HTTP and the install ports', () {
      expect(YatteeAuthService.expandUrlCandidates('yattee.lan'), [
        'https://yattee.lan',
        'http://yattee.lan',
        'http://yattee.lan:8085',
        'http://yattee.lan:8080',
      ]);
      expect(YatteeAuthService.expandUrlCandidates('http://10.0.0.5:9000/'), ['http://10.0.0.5:9000']);
    });

    test('probe accepts only a Yattee /health answer', () async {
      final service = YatteeAuthService(
        httpClientFactory: () => MockClient((request) async {
          expect(request.url.path, '/health');
          expect(request.headers.containsKey('Authorization'), isFalse);
          return request.url.host == 'yattee' ? _json({'status': 'ok'}) : _json({'hello': 'world'});
        }),
      );
      await service.probe('https://yattee');
      await expectLater(
        service.probe('https://other'),
        throwsA(isA<YatteeUrlException>().having((e) => e.statusCode, 'status', 200)),
      );
    });

    test('probeFirstReachable prefers a slower TLS answer over plain HTTP', () async {
      final service = YatteeAuthService(
        httpClientFactory: () => MockClient((request) async {
          if (request.url.scheme == 'https') {
            await Future<void>.delayed(const Duration(milliseconds: 20));
            return _json({'status': 'ok'});
          }
          return _json({'status': 'ok'});
        }),
      );
      expect(await service.probeFirstReachable('yattee.lan'), 'https://yattee.lan');
    });

    test('probeFirstReachable settles on the install port when only it answers', () async {
      final service = YatteeAuthService(
        httpClientFactory: () => MockClient((request) async {
          if (request.url.scheme != 'http' || request.url.port != 8085) {
            throw http.ClientException('connection refused', request.url);
          }
          return _json({'status': 'ok'});
        }),
      );
      expect(await service.probeFirstReachable('yattee.lan'), 'http://yattee.lan:8085');
    });

    test('signIn verifies the credentials against /info and keeps the instance label', () async {
      final service = YatteeAuthService(
        httpClientFactory: () => MockClient((request) async {
          expect(request.url.path, '/info');
          if (request.headers['Authorization'] != _expectedAuthorization) {
            return _json({'detail': 'Invalid credentials'}, status: 401);
          }
          return _json({'name': 'Yattee Server', 'version': '1.0.9', 'python': '3.12'});
        }),
      );
      final session = await service.signIn(
        baseUrl: 'https://yattee.example.com',
        username: 'alice',
        password: 'hunter2',
      );
      expect(session.baseUrl, 'https://yattee.example.com');
      expect(session.username, 'alice');
      expect(session.secret, 'hunter2');
      expect(session.instanceLabel, 'Yattee Server');
      expect(session.version, '1.0.9');
      await expectLater(
        service.signIn(baseUrl: 'https://yattee.example.com', username: 'alice', password: 'nope'),
        throwsA(isA<YatteeAuthException>().having((e) => e.statusCode, 'status', 401)),
      );
    });

    test('signIn rejects a server whose /info is not a Yattee Server', () async {
      final service = YatteeAuthService(
        httpClientFactory: () => MockClient((_) async => _json({'name': 'invidious', 'version': '2'})),
      );
      await expectLater(
        service.signIn(baseUrl: 'https://x', username: 'a', password: 'b'),
        throwsA(isA<YatteeUrlException>()),
      );
    });
  });

  group('YatteeSession', () {
    test('round-trips through JSON', () {
      final decoded = YatteeSession.decode(_session().encode());
      expect(decoded.baseUrl, 'https://yattee.example.com');
      expect(decoded.username, 'alice');
      expect(decoded.secret, 'hunter2');
      expect(decoded.instanceLabel, 'Yattee Server');
    });
  });
}
