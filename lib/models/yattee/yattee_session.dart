import 'dart:convert';

/// A connected Yattee Server for one profile: instance URL plus the HTTP
/// Basic Auth credentials every `/api/v1` call carries.
///
/// [secret] is the plaintext password while in memory; the store protects it
/// with CredentialVault before persisting. Empty after an unrecoverable
/// decrypt failure, in which case API calls fail with 401 and the settings
/// row asks the user to reconnect.
class YatteeSession {
  final String baseUrl;
  final String username;
  final String secret;

  /// `name` from `/info` — "Yattee Server" unless the operator renamed it.
  final String instanceLabel;

  /// `version` from `/info`, informational only.
  final String version;
  final int createdAt;

  const YatteeSession({
    required this.baseUrl,
    required this.username,
    required this.secret,
    required this.instanceLabel,
    required this.version,
    required this.createdAt,
  });

  YatteeSession copyWith({String? secret}) => YatteeSession(
    baseUrl: baseUrl,
    username: username,
    secret: secret ?? this.secret,
    instanceLabel: instanceLabel,
    version: version,
    createdAt: createdAt,
  );

  Map<String, Object?> toJson() => {
    'base_url': baseUrl,
    'username': username,
    'secret': secret,
    'instance_label': instanceLabel,
    'version': version,
    'created_at': createdAt,
  };

  factory YatteeSession.fromJson(Map<String, Object?> json) => YatteeSession(
    baseUrl: json['base_url'] as String,
    username: json['username'] as String? ?? '',
    secret: json['secret'] as String? ?? '',
    instanceLabel: json['instance_label'] as String? ?? '',
    version: json['version'] as String? ?? '',
    createdAt: (json['created_at'] as num?)?.toInt() ?? 0,
  );

  String encode() => jsonEncode(toJson());

  static YatteeSession decode(String raw) => YatteeSession.fromJson((jsonDecode(raw) as Map).cast<String, Object?>());
}

/// A channel the user follows, kept client-side: Yattee Server's feed
/// endpoint is stateless and expects the full subscription list on every
/// call, so the list has to live in the app.
class YatteeSubscription {
  final String channelId;
  final String name;
  final String? avatarUrl;

  const YatteeSubscription({required this.channelId, required this.name, this.avatarUrl});

  Map<String, Object?> toJson() => {'channel_id': channelId, 'name': name, 'avatar_url': avatarUrl};

  factory YatteeSubscription.fromJson(Map<String, Object?> json) => YatteeSubscription(
    channelId: json['channel_id'] as String,
    name: json['name'] as String? ?? '',
    avatarUrl: json['avatar_url'] as String?,
  );
}
