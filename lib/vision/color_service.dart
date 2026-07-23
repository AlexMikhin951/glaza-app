import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Офлайн определение доминирующего цвета центра кадра (Seeing AI Color).
class ColorService {
  final Future<void> Function(String text, {int? priority}) _enqueue;

  ColorService({
    required Future<void> Function(String text, {int? priority}) enqueueCallback,
  }) : _enqueue = enqueueCallback;

  Future<void> announceColor(Uint8List jpeg) async {
    final name = await compute(_dominantColorName, jpeg);
    if (name == null) {
      await _enqueue('Не удалось определить цвет.', priority: 0);
      return;
    }
    await _enqueue('Цвет: $name.', priority: 0);
  }

  static String? _dominantColorName(Uint8List jpeg) {
    final decoded = img.decodeJpg(jpeg);
    if (decoded == null) return null;

    final w = decoded.width;
    final h = decoded.height;
    final x0 = (w * 0.4).round();
    final x1 = (w * 0.6).round();
    final y0 = (h * 0.4).round();
    final y1 = (h * 0.6).round();

    double sumR = 0, sumG = 0, sumB = 0;
    var n = 0;
    for (var y = y0; y < y1; y += 2) {
      for (var x = x0; x < x1; x += 2) {
        final p = decoded.getPixel(x, y);
        sumR += p.r;
        sumG += p.g;
        sumB += p.b;
        n++;
      }
    }
    if (n == 0) return null;
    final r = (sumR / n).round();
    final g = (sumG / n).round();
    final b = (sumB / n).round();
    return _nameFromRgb(r, g, b);
  }

  static String _nameFromRgb(int r, int g, int b) {
    final max = [r, g, b].reduce((a, c) => a > c ? a : c);
    final min = [r, g, b].reduce((a, c) => a < c ? a : c);
    final delta = max - min;
    final brightness = (r + g + b) / 3;

    if (delta < 18) {
      if (brightness < 40) return 'чёрный';
      if (brightness < 90) return 'тёмно-серый';
      if (brightness < 160) return 'серый';
      if (brightness < 220) return 'светло-серый';
      return 'белый';
    }

    // HSV hue
    double h;
    if (max == r) {
      h = 60 * (((g - b) / delta) % 6);
    } else if (max == g) {
      h = 60 * (((b - r) / delta) + 2);
    } else {
      h = 60 * (((r - g) / delta) + 4);
    }
    if (h < 0) h += 360;
    final s = delta / max;
    final v = max / 255.0;

    if (s < 0.18) {
      if (v < 0.35) return 'тёмно-серый';
      if (v > 0.85) return 'белый';
      return 'серый';
    }

    if (h < 15 || h >= 345) return v < 0.45 ? 'тёмно-красный' : 'красный';
    if (h < 40) return v < 0.5 ? 'коричневый' : 'оранжевый';
    if (h < 70) return 'жёлтый';
    if (h < 160) return v < 0.45 ? 'тёмно-зелёный' : 'зелёный';
    if (h < 200) return 'бирюзовый';
    if (h < 255) return v < 0.45 ? 'тёмно-синий' : 'синий';
    if (h < 290) return 'фиолетовый';
    if (h < 330) return 'розовый';
    return 'красный';
  }
}
