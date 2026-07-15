import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/tailscale_peer_discovery.dart';

void main() {
  group('TailscalePeerDiscovery', () {
    test('parses online IPv4 peer addresses from Tailscale status', () {
      final status = jsonEncode({
        'Self': {
          'Online': true,
          'TailscaleIPs': ['100.64.0.1', 'fd7a:115c:a1e0::1'],
        },
        'Peer': {
          'node-1': {
            'Online': true,
            'TailscaleIPs': ['100.101.2.3', 'fd7a:115c:a1e0::2'],
          },
          'node-2': {
            'Online': false,
            'TailscaleIPs': ['100.99.2.3'],
          },
          'not-a-tailnet-address': {
            'Online': true,
            'TailscaleIPs': ['192.168.1.20'],
          },
        },
      });

      final addresses = TailscalePeerDiscovery.parsePeerAddresses(status);

      expect(addresses.map((address) => address.address), ['100.101.2.3', '100.64.0.1']);
    });

    test('returns no peers for malformed status output', () {
      expect(TailscalePeerDiscovery.parsePeerAddresses('not json'), isEmpty);
    });

    test('recognizes Tailscale IPv4 and IPv6 ranges', () {
      expect(TailscalePeerDiscovery.isTailscaleAddress(InternetAddress('100.64.0.1')), isTrue);
      expect(TailscalePeerDiscovery.isTailscaleAddress(InternetAddress('100.127.255.254')), isTrue);
      expect(TailscalePeerDiscovery.isTailscaleAddress(InternetAddress('100.128.0.1')), isFalse);
      expect(TailscalePeerDiscovery.isTailscaleAddress(InternetAddress('fd7a:115c:a1e0::1')), isTrue);
      expect(TailscalePeerDiscovery.isTailscaleAddress(InternetAddress('fd00::1')), isFalse);
    });

    test('supports an injected status loader', () async {
      final discovery = TailscalePeerDiscovery(
        () async => jsonEncode({
          'Peer': {
            'node-1': {
              'Online': true,
              'TailscaleIPs': ['100.90.80.70'],
            },
          },
        }),
      );

      final addresses = await discovery.discoverPeerAddresses();

      expect(addresses.single.address, '100.90.80.70');
    });
  });
}
