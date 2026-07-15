import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../utils/app_logger.dart';
import '../utils/udp_broadcast_sockets.dart';
import 'jellyfin_endpoint_discovery.dart';
import 'tailscale_peer_discovery.dart';

class DiscoveredJellyfinServer {
  final String address;
  final String id;
  final String name;

  DiscoveredJellyfinServer({required this.address, required this.id, required this.name});
}

class JellyfinLanDiscoveryService {
  static const int discoveryPort = 7359;
  static const String discoveryMessage = 'who is JellyfinServer?';

  /// Sends two discovery packets 350 ms apart, then listens for
  /// [responseWindow] after the second packet.
  Future<List<DiscoveredJellyfinServer>> discover({
    Duration responseWindow = const Duration(seconds: 2),
    InternetAddress? broadcastAddress,
    Future<Iterable<InternetAddress>>? additionalTargets,
  }) async {
    UdpBroadcastSocketSet? socketSet;
    final discovered = <String, DiscoveredJellyfinServer>{};
    try {
      socketSet = await UdpBroadcastSockets.bind();
      socketSet.listen((datagram) {
        final fromTailscale = TailscalePeerDiscovery.isTailscaleAddress(datagram.address);
        final server = parseDiscoveryResponse(datagram.data, sourceAddress: datagram.address);
        if (server == null) return;
        if (fromTailscale || !discovered.containsKey(server.id)) {
          discovered[server.id] = server;
        }
      }, debugLabel: 'Jellyfin LAN discovery');

      final data = utf8.encode(discoveryMessage);
      final target = broadcastAddress ?? UdpBroadcastSockets.limitedBroadcastAddress;
      socketSet.send(data, target, discoveryPort);
      await Future<void>.delayed(const Duration(milliseconds: 350));
      socketSet.send(data, target, discoveryPort);

      if (additionalTargets != null) {
        final targets = await _resolveAdditionalTargets(additionalTargets);
        if (targets.isNotEmpty) {
          for (final target in targets) {
            socketSet.send(data, target, discoveryPort);
          }
          await Future<void>.delayed(const Duration(milliseconds: 350));
          for (final target in targets) {
            socketSet.send(data, target, discoveryPort);
          }
        }
      }
      await Future<void>.delayed(responseWindow);
    } catch (e, st) {
      appLogger.w('Jellyfin LAN discovery failed', error: e, stackTrace: st);
    } finally {
      await socketSet?.close();
    }

    return sortDiscoveredServers(discovered.values);
  }

  static List<DiscoveredJellyfinServer> sortDiscoveredServers(Iterable<DiscoveredJellyfinServer> servers) {
    final sorted = servers.toList()
      ..sort((a, b) {
        final name = a.name.toLowerCase().compareTo(b.name.toLowerCase());
        if (name != 0) return name;
        final address = a.address.compareTo(b.address);
        if (address != 0) return address;
        return a.id.compareTo(b.id);
      });
    return List.unmodifiable(sorted);
  }

  static DiscoveredJellyfinServer? parseDiscoveryResponse(List<int> data, {InternetAddress? sourceAddress}) {
    try {
      final decoded = jsonDecode(utf8.decode(data));
      if (decoded is! Map<String, dynamic>) return null;

      final address = _stringValue(decoded, 'Address') ?? _stringValue(decoded, 'address');
      final id = _stringValue(decoded, 'Id') ?? _stringValue(decoded, 'id');
      final name = _stringValue(decoded, 'Name') ?? _stringValue(decoded, 'name');
      if (address == null || id == null || name == null) return null;

      final normalized = JellyfinEndpointDiscovery.normalizeBaseUrl(address);
      if (normalized.isEmpty || id.trim().isEmpty || name.trim().isEmpty) return null;
      return DiscoveredJellyfinServer(
        address: _addressReachableFromSource(normalized, sourceAddress),
        id: id.trim(),
        name: name.trim(),
      );
    } catch (_) {
      return null;
    }
  }

  static String? _stringValue(Map<String, dynamic> json, String key) {
    final value = json[key];
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static Future<List<InternetAddress>> _resolveAdditionalTargets(
    Future<Iterable<InternetAddress>> additionalTargets,
  ) async {
    try {
      final targets = await additionalTargets;
      final unique = <String, InternetAddress>{};
      for (final target in targets) {
        if (target.type != InternetAddressType.IPv4 || target.isLoopback) continue;
        unique.putIfAbsent(target.address, () => target);
      }
      return List.unmodifiable(unique.values);
    } catch (e, st) {
      appLogger.d('Additional Jellyfin discovery targets unavailable', error: e, stackTrace: st);
      return const [];
    }
  }

  static String _addressReachableFromSource(String reportedAddress, InternetAddress? sourceAddress) {
    if (sourceAddress == null || !TailscalePeerDiscovery.isTailscaleAddress(sourceAddress)) {
      return reportedAddress;
    }

    final uri = Uri.tryParse(reportedAddress);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return reportedAddress;
    final reportedHost = InternetAddress.tryParse(uri.host);
    if (reportedHost == null ||
        TailscalePeerDiscovery.isTailscaleAddress(reportedHost) ||
        !_isPrivateAddress(reportedHost)) {
      return reportedAddress;
    }

    return JellyfinEndpointDiscovery.normalizeBaseUrl(uri.replace(host: sourceAddress.address).toString());
  }

  static bool _isPrivateAddress(InternetAddress address) {
    final bytes = address.rawAddress;
    if (bytes.length == 4) {
      return bytes[0] == 10 ||
          bytes[0] == 127 ||
          (bytes[0] == 169 && bytes[1] == 254) ||
          (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) ||
          (bytes[0] == 192 && bytes[1] == 168);
    }
    if (bytes.length == 16) {
      final isLoopback = bytes.take(15).every((byte) => byte == 0) && bytes[15] == 1;
      final isUniqueLocal = bytes[0] & 0xfe == 0xfc;
      final isLinkLocal = bytes[0] == 0xfe && bytes[1] & 0xc0 == 0x80;
      return isLoopback || isUniqueLocal || isLinkLocal;
    }
    return false;
  }
}
