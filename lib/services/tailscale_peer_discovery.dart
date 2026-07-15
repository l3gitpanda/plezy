import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../utils/app_logger.dart';

typedef TailscaleStatusJsonLoader = Future<String?> Function();

/// Finds online tailnet peers through the locally installed Tailscale CLI.
///
/// Tailscale is a layer-3 network and does not forward the subnet broadcast
/// used by Jellyfin discovery. Desktop clients can work around that by sending
/// the same discovery packet directly to every online Tailscale peer.
class TailscalePeerDiscovery {
  static const int maxPeerAddresses = 256;
  static const Duration statusTimeout = Duration(seconds: 2);

  final TailscaleStatusJsonLoader? _statusJsonLoader;

  const TailscalePeerDiscovery([this._statusJsonLoader]);

  Future<List<InternetAddress>> discoverPeerAddresses() async {
    try {
      final loader = _statusJsonLoader;
      final statusJson = loader != null ? await loader() : await _loadStatusJson();
      if (statusJson == null || statusJson.trim().isEmpty) return const [];
      return parsePeerAddresses(statusJson);
    } catch (e, st) {
      appLogger.d('Tailscale peer discovery unavailable', error: e, stackTrace: st);
      return const [];
    }
  }

  static List<InternetAddress> parsePeerAddresses(String statusJson) {
    try {
      final decoded = jsonDecode(statusJson);
      if (decoded is! Map<String, dynamic>) return const [];

      final nodes = <Object?>[decoded['Self']];
      final peers = decoded['Peer'];
      if (peers is Map) nodes.addAll(peers.values);

      final addresses = <String, InternetAddress>{};
      for (final node in nodes) {
        if (node is! Map || node['Online'] == false) continue;
        final tailscaleIps = node['TailscaleIPs'];
        if (tailscaleIps is! List) continue;
        for (final value in tailscaleIps) {
          if (value is! String) continue;
          final address = InternetAddress.tryParse(value.trim());
          if (address == null || address.type != InternetAddressType.IPv4 || !isTailscaleAddress(address)) continue;
          addresses.putIfAbsent(address.address, () => address);
        }
      }

      final sorted = addresses.values.toList()..sort((a, b) => a.address.compareTo(b.address));
      return List.unmodifiable(sorted.take(maxPeerAddresses));
    } catch (_) {
      return const [];
    }
  }

  /// Tailscale's IPv4 CGNAT range and unique-local IPv6 prefix.
  static bool isTailscaleAddress(InternetAddress address) {
    final bytes = address.rawAddress;
    if (bytes.length == 4) {
      return bytes[0] == 100 && bytes[1] >= 64 && bytes[1] <= 127;
    }
    if (bytes.length == 16) {
      return bytes[0] == 0xfd &&
          bytes[1] == 0x7a &&
          bytes[2] == 0x11 &&
          bytes[3] == 0x5c &&
          bytes[4] == 0xa1 &&
          bytes[5] == 0xe0;
    }
    return false;
  }

  Future<String?> _loadStatusJson() async {
    if (!Platform.isWindows && !Platform.isMacOS && !Platform.isLinux) return null;

    for (final command in _statusCommandCandidates()) {
      final output = await _runStatusCommand(command);
      if (output != null) return output;
    }
    return null;
  }

  List<String> _statusCommandCandidates() {
    final commands = <String>['tailscale'];
    if (Platform.isWindows) {
      final programFiles = Platform.environment['ProgramFiles'];
      if (programFiles != null && programFiles.trim().isNotEmpty) {
        commands.add('$programFiles\\Tailscale\\tailscale.exe');
      }
    } else if (Platform.isMacOS) {
      commands.add('/Applications/Tailscale.app/Contents/MacOS/Tailscale');
    }
    return List.unmodifiable(commands.toSet());
  }

  Future<String?> _runStatusCommand(String command) async {
    Process? process;
    try {
      process = await Process.start(command, const ['status', '--json']);
      final stdoutFuture = process.stdout.transform(utf8.decoder).join();
      final stderrFuture = process.stderr.drain<void>();

      try {
        final exitCode = await process.exitCode.timeout(statusTimeout);
        final output = await stdoutFuture;
        return exitCode == 0 ? output : null;
      } on TimeoutException {
        process.kill();
        try {
          await process.exitCode.timeout(const Duration(milliseconds: 500));
        } on TimeoutException {
          // Killing a process is best-effort on some desktop platforms.
        }
        return null;
      } finally {
        try {
          await Future.wait<void>([
            stdoutFuture.then<void>((_) {}),
            stderrFuture,
          ]).timeout(const Duration(milliseconds: 500));
        } on Object {
          // Output collection is best-effort after a failed or killed CLI.
        }
      }
    } on ProcessException {
      return null;
    } catch (e, st) {
      appLogger.d('Failed to read Tailscale status with $command', error: e, stackTrace: st);
      process?.kill();
      return null;
    }
  }
}
