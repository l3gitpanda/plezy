#!/usr/bin/env python3
"""Minimal Jellyfin look-alike: one TV library, one series, one season, five
episodes carrying Ronin-style canon/filler tags. Logs every request so the
client's field sets can be inspected."""
import json, sys, time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8096
EMBY = 'emby' in sys.argv[3:]  # third arg 'emby': no ProductName, RemoteAddresses, TagItems only
LOG_PATH = sys.argv[2] if len(sys.argv) > 2 else '/tmp/stub-jellyfin.log'
SERVER_ID, USER_ID, TOKEN = 'stubserver0001', 'user0001', 'stubtoken'
MIN = 60 * 10_000_000
STAMP = '2026-01-01T00:00:00.0000000Z'

def user_data(played=False, unplayed=None):
    d = {'PlaybackPositionTicks': 0, 'PlayCount': 1 if played else 0, 'IsFavorite': False, 'Played': played, 'Key': 'k'}
    if unplayed is not None:
        d['UnplayedItemCount'] = unplayed
    return d

LIBRARY = {'Id': 'lib-anime', 'Name': 'Anime', 'ServerId': SERVER_ID, 'Type': 'CollectionFolder', 'CollectionType': 'tvshows',
           'IsFolder': True, 'ImageTags': {}, 'BackdropImageTags': [], 'UserData': user_data(), 'LocationType': 'FileSystem',
           'SortName': 'anime', 'Etag': 'e', 'DateCreated': STAMP, 'CanDelete': False, 'CanDownload': False, 'ChildCount': 1,
           'Path': '/media/anime'}
SERIES = {'Id': 'series-1', 'Name': 'Stub Ninja Chronicles', 'ServerId': SERVER_ID, 'Type': 'Series', 'IsFolder': True,
          'Overview': 'A stub series whose episodes carry Ronin-style canon/filler tags.', 'ProductionYear': 2024,
          'PremiereDate': '2024-01-07T00:00:00.0000000Z', 'ChildCount': 1, 'RecursiveItemCount': 5, 'ImageTags': {},
          'BackdropImageTags': [], 'UserData': user_data(unplayed=5), 'Genres': ['Animation'],
          'GenreItems': [{'Name': 'Animation', 'Id': 'g1'}], 'Tags': ['anime'], 'TagItems': [{'Name': 'anime', 'Id': 't0'}],
          'Status': 'Continuing', 'LocationType': 'FileSystem', 'MediaType': 'Unknown', 'SortName': 'stub ninja chronicles',
          'DateCreated': STAMP, 'OfficialRating': 'TV-14', 'CommunityRating': 8.1, 'ParentId': 'lib-anime',
          'RunTimeTicks': 24 * MIN, 'Etag': 'e', 'CanDelete': False, 'CanDownload': False, 'People': [], 'Studios': [],
          'Taglines': [], 'ProviderIds': {}, 'AirDays': [], 'Path': '/media/anime/Stub Ninja Chronicles'}
SEASON = {'Id': 'season-1', 'Name': 'Season 1', 'ServerId': SERVER_ID, 'Type': 'Season', 'IsFolder': True, 'IndexNumber': 1,
          'SeriesId': 'series-1', 'SeriesName': SERIES['Name'], 'ParentId': 'series-1', 'ChildCount': 5, 'RecursiveItemCount': 5,
          'ImageTags': {}, 'BackdropImageTags': [], 'UserData': user_data(unplayed=5), 'LocationType': 'FileSystem',
          'MediaType': 'Unknown', 'SortName': '0001 - season 1', 'ProductionYear': 2024,
          'PremiereDate': '2024-01-07T00:00:00.0000000Z', 'DateCreated': STAMP, 'Etag': 'e', 'CanDelete': False,
          'CanDownload': False, 'Path': '/media/anime/Stub Ninja Chronicles/Season 1'}

def episode(n, name, tags, overview, minutes=24):
    path = f'/media/anime/Stub Ninja Chronicles/Season 1/Stub Ninja Chronicles S01E{n:02d}.mkv'
    source = {'Id': f'ep-{n}', 'Protocol': 'File', 'Path': path, 'Type': 'Default', 'Container': 'mkv', 'Size': 734003200,
              'Name': f'S01E{n:02d}', 'IsRemote': False, 'RunTimeTicks': minutes * MIN, 'SupportsTranscoding': True,
              'SupportsDirectStream': True, 'SupportsDirectPlay': True, 'IsInfiniteStream': False, 'RequiresOpening': False,
              'RequiresClosing': False, 'RequiresLooping': False, 'SupportsProbing': True, 'VideoType': 'VideoFile',
              'Formats': [], 'Bitrate': 4000000, 'DefaultAudioStreamIndex': 1,
              'MediaStreams': [
                  {'Codec': 'hevc', 'Type': 'Video', 'Width': 1920, 'Height': 1080, 'Index': 0, 'IsDefault': True,
                   'VideoRange': 'SDR', 'VideoRangeType': 'SDR', 'DisplayTitle': '1080p HEVC', 'BitRate': 3800000},
                  {'Codec': 'aac', 'Type': 'Audio', 'Language': 'jpn', 'Channels': 2, 'Index': 1, 'IsDefault': True,
                   'DisplayTitle': 'Japanese - AAC - Stereo', 'ChannelLayout': 'stereo'}]}
    return {'Id': f'ep-{n}', 'Name': name, 'ServerId': SERVER_ID, 'Type': 'Episode', 'IsFolder': False, 'IndexNumber': n,
            'ParentIndexNumber': 1, 'SeriesId': 'series-1', 'SeriesName': SERIES['Name'], 'SeasonId': 'season-1',
            'SeasonName': 'Season 1', 'ParentId': 'season-1', 'Overview': overview, 'RunTimeTicks': minutes * MIN,
            'PremiereDate': f'2024-01-{7 + 7 * (n - 1):02d}T00:00:00.0000000Z', 'ProductionYear': 2024, 'Tags': tags,
            'TagItems': [{'Name': t, 'Id': f'tag-{n}-{i}'} for i, t in enumerate(tags)], 'UserData': user_data(),
            'ImageTags': {}, 'BackdropImageTags': [], 'LocationType': 'FileSystem', 'MediaType': 'Video', 'Container': 'mkv',
            'SortName': f'{n:04d} - {name.lower()}', 'DateCreated': STAMP, 'Etag': 'e', 'CanDelete': False,
            'CanDownload': True, 'HasSubtitles': False, 'MediaSources': [source], 'MediaStreams': source['MediaStreams'],
            'Path': path, 'VideoType': 'VideoFile', 'LockedFields': [], 'LockData': False, 'ProviderIds': {}, 'People': [],
            'Studios': [], 'Genres': [], 'GenreItems': [], 'Taglines': [], 'Chapters': [], 'Width': 1920, 'Height': 1080}

EPISODES = [
    episode(1, 'Enter the Stub', ['Manga Canon'], 'The hero arrives in the village and meets the stub master.'),
    episode(2, 'Beach Episode', ['Filler'], 'Everyone goes to the beach. Nothing of consequence happens.'),
    episode(3, 'Chunin Recap', ['Mixed Canon/Filler'], 'Half a recap, half new material that the manga covered in a page.'),
    episode(4, 'The Anime-Only Arc', ['Anime Canon', 'Fansub'], 'An arc the studio wrote itself; the tag list also carries a fansub mark.'),
    episode(5, 'Untagged Finale', [], 'The plugin never classified this one.'),
]
ITEMS = {i['Id']: i for i in [LIBRARY, SERIES, SEASON, *EPISODES]}
ANCESTORS = {'series-1': [LIBRARY], 'season-1': [SERIES, LIBRARY], **{e['Id']: [SEASON, SERIES, LIBRARY] for e in EPISODES}}

USER = {'Name': 'verifier', 'ServerId': SERVER_ID, 'Id': USER_ID, 'HasPassword': True, 'HasConfiguredPassword': True,
        'HasConfiguredEasyPassword': False, 'EnableAutoLogin': False, 'LastLoginDate': STAMP, 'LastActivityDate': STAMP,
        'Configuration': {'PlayDefaultAudioTrack': True, 'SubtitleLanguagePreference': '', 'DisplayMissingEpisodes': False,
                          'GroupedFolders': [], 'SubtitleMode': 'Default', 'DisplayCollectionsView': False,
                          'EnableLocalPassword': False, 'OrderedViews': [], 'LatestItemsExcludes': [], 'MyMediaExcludes': [],
                          'HidePlayedInLatest': True, 'RememberAudioSelections': True, 'RememberSubtitleSelections': True,
                          'EnableNextEpisodeAutoPlay': True, 'CastReceiverId': ''},
        'Policy': {'IsAdministrator': True, 'IsHidden': False, 'IsDisabled': False, 'EnableAllFolders': True,
                   'EnabledFolders': [], 'EnableContentDeletion': False, 'EnableContentDeletionFromFolders': [],
                   'EnableMediaPlayback': True, 'EnableAudioPlaybackTranscoding': True, 'EnableVideoPlaybackTranscoding': True,
                   'EnablePlaybackRemuxing': True, 'EnableContentDownloading': True, 'EnableSyncTranscoding': True,
                   'EnableMediaConversion': True, 'EnableRemoteAccess': True, 'EnableLiveTvManagement': False,
                   'EnableLiveTvAccess': False, 'EnablePublicSharing': False, 'RemoteClientBitrateLimit': 0,
                   'AuthenticationProviderId': 'Jellyfin.Server.Implementations.Users.DefaultAuthenticationProvider',
                   'PasswordResetProviderId': 'Jellyfin.Server.Implementations.Users.DefaultPasswordResetProvider',
                   'SyncPlayAccess': 'CreateAndJoinGroups', 'EnableAllChannels': True, 'EnabledChannels': [],
                   'EnableAllDevices': True, 'EnabledDevices': [], 'EnableUserPreferenceAccess': True, 'AccessSchedules': [],
                   'BlockedTags': [], 'AllowedTags': [], 'BlockUnratedItems': [], 'EnableRemoteControlOfOtherUsers': False,
                   'EnableSharedDeviceControl': True, 'InvalidLoginAttemptCount': 0, 'LoginAttemptsBeforeLockout': -1,
                   'MaxActiveSessions': 0, 'ForceRemoteSourceTranscoding': False, 'EnableCollectionManagement': False,
                   'EnableSubtitleManagement': False, 'EnableLyricManagement': False}}
PUBLIC_INFO = ({'LocalAddress': f'http://127.0.0.1:{PORT}', 'ServerName': 'Stub Emby', 'Version': '4.9.1.0', 'Id': SERVER_ID + 'emby',
                'RemoteAddresses': [], 'OperatingSystem': 'Linux', 'StartupWizardCompleted': True} if EMBY else
               {'LocalAddress': f'http://127.0.0.1:{PORT}', 'ServerName': 'Stub Jellyfin', 'Version': '10.11.0',
                'ProductName': 'Jellyfin Server', 'OperatingSystem': 'Linux', 'Id': SERVER_ID, 'StartupWizardCompleted': True})
if EMBY:
    for _item in ITEMS.values():
        _item.pop('Tags', None)

def page(items, q):
    start = int(q.get('StartIndex', ['0'])[0]); limit = q.get('Limit', [None])[0]
    sliced = items[start:start + int(limit)] if limit else items[start:]
    return {'Items': sliced, 'TotalRecordCount': len(items), 'StartIndex': start}

def log(line):
    with open(LOG_PATH, 'a') as f:
        f.write(f'{time.strftime("%H:%M:%S")} {line}\n')

class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def log_message(self, *args): pass

    def send_json(self, body, status=200):
        raw = b'' if body is None else json.dumps(body).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json; charset=utf-8')
        self.send_header('Content-Length', str(len(raw)))
        self.end_headers()
        if raw: self.wfile.write(raw)

    def do_GET(self):
        u = urlparse(self.path); p = u.path; q = parse_qs(u.query)
        log(f'GET {self.path}')
        if p == '/System/Info/Public' or p == '/System/Info': return self.send_json(PUBLIC_INFO)
        if p in ('/Users/Me', f'/Users/{USER_ID}'): return self.send_json(USER)
        if p.endswith('/Views'): return self.send_json(page([LIBRARY], q))
        if p == '/Items/Filters': return self.send_json({'Genres': [], 'Tags': [], 'OfficialRatings': [], 'Years': []})
        if p == '/QuickConnect/Enabled': return self.send_json(False)
        if p.startswith('/DisplayPreferences/'):
            return self.send_json({'Id': 'dp', 'SortBy': 'SortName', 'RememberIndexing': False, 'PrimaryImageHeight': 250,
                                   'PrimaryImageWidth': 250, 'CustomPrefs': {}, 'ScrollDirection': 'Horizontal', 'ShowBackdrop': True,
                                   'RememberSorting': False, 'SortOrder': 'Ascending', 'ShowSidebar': False, 'Client': 'emby'})
        if p == '/Branding/Configuration': return self.send_json({'LoginDisclaimer': '', 'CustomCss': '', 'SplashscreenEnabled': False})
        if p == '/Items':
            ids = q.get('Ids', [''])[0]
            if ids: return self.send_json(page([ITEMS[i] for i in ids.split(',') if i in ITEMS], q))
            parent = q.get('ParentId', [None])[0]
            types = q.get('IncludeItemTypes', [''])[0]
            recursive = q.get('Recursive', ['false'])[0].lower() == 'true'
            if parent == 'lib-anime': items = EPISODES if (recursive and 'Episode' in types) else [SERIES]
            elif parent == 'series-1': items = EPISODES if (recursive or 'Episode' in types) else [SEASON]
            elif parent == 'season-1': items = EPISODES
            elif parent is None and 'Series' in types: items = [SERIES]
            else: items = []
            return self.send_json(page(items, q))
        if p == '/Shows/series-1/Seasons': return self.send_json(page([SEASON], q))
        if p == '/Shows/series-1/Episodes':
            season = q.get('SeasonId', q.get('seasonId', [None]))[0]
            return self.send_json(page(EPISODES if season in (None, 'season-1') else [], q))
        if p == '/Shows/NextUp' or p.endswith('/Items/Resume') or p == '/UserItems/Resume': return self.send_json(page([], q))
        if p.endswith('/Items/Latest'): return self.send_json([SERIES])
        parts = [s for s in p.split('/') if s]
        if len(parts) >= 2 and parts[-2] == 'Items' and parts[-1] in ITEMS: return self.send_json(ITEMS[parts[-1]])
        if len(parts) == 3 and parts[0] == 'Items' and parts[2] == 'Ancestors': return self.send_json(ANCESTORS.get(parts[1], []))
        if len(parts) == 3 and parts[0] == 'Items' and parts[2] == 'Similar': return self.send_json(page([], q))
        if 'Images' in parts: return self.send_json(None, 404)
        if p == '/LiveTv/Info': return self.send_json({'IsEnabled': False, 'EnabledUsers': [], 'Services': []})
        if p in ('/Library/VirtualFolders', '/Sessions', '/Plugins'): return self.send_json([])
        log(f'UNHANDLED GET {p}')
        if any(seg in parts for seg in ('Items', 'Shows', 'Artists', 'Genres', 'Persons', 'Studios', 'Years', 'Tags', 'LiveTv', 'Playlists', 'Channels')):
            return self.send_json(page([], q))
        return self.send_json({})

    def do_POST(self):
        length = int(self.headers.get('Content-Length') or 0)
        body = self.rfile.read(length) if length else b''
        u = urlparse(self.path); p = u.path
        log(f'POST {self.path} {body[:200]!r}')
        if p == '/Users/AuthenticateByName':
            try: creds = json.loads(body or b'{}')
            except ValueError: creds = {}
            if creds.get('Username') == 'verifier' and creds.get('Pw') == 'verifier':
                return self.send_json({'User': USER, 'SessionInfo': {'Id': 'session-1', 'UserId': USER_ID, 'UserName': 'verifier',
                                       'Client': 'Plezy', 'DeviceName': 'verifier', 'DeviceId': 'dev', 'ServerId': SERVER_ID},
                                       'AccessToken': TOKEN, 'ServerId': SERVER_ID})
            return self.send_json({'Message': 'Invalid username or password'}, 401)
        return self.send_json(None, 204)

    def do_DELETE(self):
        log(f'DELETE {self.path}'); self.send_json(None, 204)
    def do_HEAD(self):
        self.send_response(200); self.send_header('Content-Length', '0'); self.end_headers()

if __name__ == '__main__':
    ThreadingHTTPServer(('127.0.0.1', PORT), Handler).serve_forever()
