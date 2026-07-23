import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../ai_detector.dart';

typedef FrameListener = void Function({
  required Uint8List jpeg,
  required List<DetectedObject> objects,
  required int timestampMs,
});

/// Один JPEG → подписчики с throttle (safety / OCR / find).
class FrameHub {
  Uint8List? _latestJpeg;
  List<DetectedObject> _latestObjects = const [];
  int _latestMs = 0;
  int _gen = 0;

  final Map<String, _Sub> _subs = {};

  Uint8List? get latestJpeg => _latestJpeg;
  List<DetectedObject> get latestObjects => _latestObjects;
  int get generation => _gen;

  void publish({
    required Uint8List jpeg,
    required List<DetectedObject> objects,
  }) {
    _latestJpeg = jpeg;
    _latestObjects = objects;
    _latestMs = DateTime.now().millisecondsSinceEpoch;
    _gen++;

    for (final sub in _subs.values) {
      if (!sub.enabled) continue;
      final now = _latestMs;
      if (now - sub.lastMs < sub.minIntervalMs) continue;
      sub.lastMs = now;
      try {
        sub.listener(
          jpeg: jpeg,
          objects: objects,
          timestampMs: now,
        );
      } catch (e) {
        debugPrint('FrameHub listener ${sub.id} error: $e');
      }
    }
  }

  /// [minIntervalMs]: safety ~80–120 мс (8–12 FPS), OCR по запросу = 0.
  void subscribe(
    String id,
    FrameListener listener, {
    int minIntervalMs = 100,
  }) {
    _subs[id] = _Sub(id, listener, minIntervalMs);
  }

  void setEnabled(String id, bool enabled) {
    final s = _subs[id];
    if (s != null) s.enabled = enabled;
  }

  void unsubscribe(String id) => _subs.remove(id);

  void clear() {
    _latestJpeg = null;
    _latestObjects = const [];
    _subs.clear();
  }
}

class _Sub {
  final String id;
  final FrameListener listener;
  final int minIntervalMs;
  int lastMs = 0;
  bool enabled = true;

  _Sub(this.id, this.listener, this.minIntervalMs);
}
