import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'local_ip.dart';
import 'setup_screen.dart';

/// UDP-команды для ESP32-камеры (порт [kEspCommandPort]).
class EspCameraController {
  static const _prefsKey = 'last_esp_ip';
  InternetAddress? _espAddress;
  bool _loadedPrefs = false;

  void updateAddress(InternetAddress address) {
    if (_espAddress?.address == address.address) return;
    _espAddress = address;
    debugPrint('📷 ESP address: ${address.address}');
    SharedPreferences.getInstance().then((prefs) {
      prefs.setString(_prefsKey, address.address);
    });
  }

  InternetAddress? get espAddress => _espAddress;

  Future<void> _ensureAddress() async {
    if (_espAddress != null || _loadedPrefs) return;
    _loadedPrefs = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_prefsKey);
      if (saved != null && saved.isNotEmpty) {
        _espAddress = InternetAddress(saved);
        debugPrint('📷 ESP address from prefs: $saved');
      }
    } catch (e) {
      debugPrint('📷 load last ESP ip: $e');
    }
  }

  Future<bool> sendCommand(String command) async {
    await _ensureAddress();
    final targets = <InternetAddress>[];
    if (_espAddress != null) targets.add(_espAddress!);

    // Пока IP очков неизвестен — шлём на broadcast подсети хотспота.
    if (targets.isEmpty) {
      final phoneIp = await resolvePhoneIpv4();
      if (phoneIp != null) {
        final parts = phoneIp.split('.');
        if (parts.length == 4) {
          targets.add(InternetAddress('${parts[0]}.${parts[1]}.${parts[2]}.255'));
        }
      }
    }

    if (targets.isEmpty) {
      debugPrint('📷 ESP address unknown, command "$command" skipped');
      return false;
    }

    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.broadcastEnabled = true;
      final bytes = utf8.encode(command);
      for (final target in targets) {
        socket.send(bytes, target, kEspCommandPort);
      }
      debugPrint('📷 → ESP: $command (${targets.map((e) => e.address).join(", ")})');
      return true;
    } catch (e) {
      debugPrint('📷 command error: $e');
      return false;
    } finally {
      socket?.close();
    }
  }

  /// HD-снимок для чтения: пауза потока + CAPTURE (прошивка ESP32).
  Future<bool> captureReadingSnapshot() async {
    await sendCommand('READ_START');
    return sendCommand('CAPTURE');
  }

  /// Возобновить видеопоток после режима чтения.
  Future<bool> resumeVideoStream() => sendCommand('STREAM');

  /// Сообщить ESP актуальный IP телефона (куда слать UDP-видео).
  Future<bool> updateVideoDestination(String ipv4) {
    final ip = ipv4.trim();
    if (ip.isEmpty || ip == '0.0.0.0') return Future.value(false);
    return sendCommand('DEST:$ip');
  }

  Future<bool> ping() => sendCommand('PING');
}
