import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

import 'setup_screen.dart';

/// UDP-команды для ESP32-камеры (порт [kEspCommandPort]).
class EspCameraController {
  InternetAddress? _espAddress;

  void updateAddress(InternetAddress address) {
    if (_espAddress?.address == address.address) return;
    _espAddress = address;
    debugPrint('📷 ESP address: ${address.address}');
  }

  InternetAddress? get espAddress => _espAddress;

  Future<bool> sendCommand(String command) async {
    final target = _espAddress;
    if (target == null) {
      debugPrint('📷 ESP address unknown, command "$command" skipped');
      return false;
    }

    RawDatagramSocket? socket;
    try {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      socket.send(
        utf8.encode(command),
        target,
        kEspCommandPort,
      );
      debugPrint('📷 → ESP: $command');
      return true;
    } catch (e) {
      debugPrint('📷 command error: $e');
      return false;
    } finally {
      socket?.close();
    }
  }

  /// HD-снимок для чтения (камера переключается на 1280×720, quality=0).
  Future<bool> captureReadingSnapshot() => sendCommand('READ_START');

  /// Возобновить SVGA-поток (800×600, quality=12) после режима чтения.
  Future<bool> resumeVideoStream() => sendCommand('STREAM');
}
