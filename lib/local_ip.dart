import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Локальный IPv4 телефона для DEST-команды ESP (видео).
Future<String?> resolvePhoneIpv4() async {
  final prefs = await SharedPreferences.getInstance();
  final hotspot = prefs.getBool('wifi_hotspot') ?? true;

  if (hotspot) {
    final ap = await _findHotspotApIp();
    if (ap != null) return ap;
  }

  try {
    final wifiIp = await NetworkInfo().getWifiIP();
    if (wifiIp != null &&
        wifiIp.isNotEmpty &&
        wifiIp != '0.0.0.0' &&
        !wifiIp.contains(':')) {
      return wifiIp;
    }
  } catch (e) {
    debugPrint('resolvePhoneIpv4 wifi: $e');
  }

  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLinkLocal: false,
      includeLoopback: false,
    );
    for (final iface in interfaces) {
      final name = iface.name.toLowerCase();
      if (name.contains('tun') ||
          name.contains('ppp') ||
          name.contains('rmnet') ||
          name.contains('ccmni')) {
        continue;
      }
      for (final addr in iface.addresses) {
        final ip = addr.address;
        if (ip.startsWith('192.168.') ||
            ip.startsWith('10.') ||
            ip.startsWith('172.')) {
          return ip;
        }
      }
    }
  } catch (e) {
    debugPrint('resolvePhoneIpv4 ifaces: $e');
  }
  return null;
}

Future<String?> _findHotspotApIp() async {
  const knownAp = {
    '192.168.43.1',
    '192.168.137.1',
    '192.168.42.1',
    '192.168.0.1',
    '192.168.150.1',
    '192.168.49.1',
  };
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLinkLocal: false,
      includeLoopback: false,
    );
    final all = <String>[];
    for (final iface in interfaces) {
      for (final addr in iface.addresses) {
        all.add(addr.address);
      }
    }
    for (final ip in all) {
      if (knownAp.contains(ip)) return ip;
    }
    for (final ip in all) {
      if (RegExp(r'^192\.168\.\d+\.1$').hasMatch(ip)) return ip;
    }
  } catch (e) {
    debugPrint('findHotspotApIp: $e');
  }
  return null;
}
