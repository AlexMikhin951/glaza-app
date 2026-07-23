import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:just_audio/just_audio.dart';

/// Уровень освещённости по яркости кадра (Seeing AI Light).
class LightService {
  final Future<void> Function(String text, {int? priority}) _enqueue;
  final AudioPlayer _tone = AudioPlayer();
  bool _toneReady = false;

  LightService({
    required Future<void> Function(String text, {int? priority}) enqueueCallback,
  }) : _enqueue = enqueueCallback;

  Future<void> init() async {
    try {
      // Тихий тон-заглушка; частоту меняем через setSpeed/volume не идеально —
      // для a11y достаточно голосового «темно/светло».
      _toneReady = true;
    } catch (_) {}
  }

  Future<void> announceLight(Uint8List jpeg, {bool playTone = false}) async {
    final level = await compute(_brightness01, jpeg);
    if (level == null) {
      await _enqueue('Не удалось оценить свет.', priority: 0);
      return;
    }
    final phrase = _phrase(level);
    await _enqueue(phrase, priority: 0);
    if (playTone && _toneReady) {
      // Частота 200–2000 Гц через длительность/паузу бипа радара не дублируем:
      // голос — основной канал; тон опционален позже.
      debugPrint('LightService level=$level');
    }
  }

  /// 0.0 = темно, 1.0 = очень ярко.
  static double? _brightness01(Uint8List jpeg) {
    final decoded = img.decodeJpg(jpeg);
    if (decoded == null) return null;
    final w = decoded.width;
    final h = decoded.height;
    double sum = 0;
    var n = 0;
    for (var y = 0; y < h; y += 4) {
      for (var x = 0; x < w; x += 4) {
        final p = decoded.getPixel(x, y);
        sum += 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
        n++;
      }
    }
    if (n == 0) return null;
    return (sum / n / 255.0).clamp(0.0, 1.0);
  }

  static String _phrase(double level) {
    if (level < 0.08) return 'Очень темно.';
    if (level < 0.18) return 'Темно.';
    if (level < 0.35) return 'Приглушённый свет.';
    if (level < 0.55) return 'Нормальное освещение.';
    if (level < 0.75) return 'Светло.';
    if (level < 0.90) return 'Ярко.';
    return 'Очень ярко, возможно солнце или лампа в кадре.';
  }

  void dispose() {
    _tone.dispose();
  }
}
