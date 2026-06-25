import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Анализ цвета светофора по bbox без нейросети — через HSV-анализ пикселей.
/// Работает полностью офлайн.
class TrafficLightAnalyzer {
  /// Определяет цвет светофора из JPEG-кадра по нормализованному bbox.
  /// Декодирует JPEG самостоятельно — используйте только если нет
  /// уже декодированного img.Image (например, при вызове в изоляте).
  ///
  /// [bbox] = [top, left, bottom, right] нормализованные [0..1]
  static String detectColor(Uint8List jpeg, List<double> bbox) {
    try {
      final image = img.decodeJpg(jpeg);
      if (image == null) return 'неизвестно';
      return detectColorFromImage(image, bbox);
    } catch (e) {
      debugPrint('TrafficLightAnalyzer error: $e');
      return 'неизвестно';
    }
  }

  /// Версия принимающая уже декодированный img.Image.
  /// ИСПРАВЛЕНИЕ Проблемы 3: SmartGlassesServices декодирует JPEG один раз
  /// и передаёт сюда готовый объект, избегая повторного декодирования.
  static String detectColorFromImage(img.Image image, List<double> bbox) {
    try {
      final w = image.width;
      final h = image.height;

      final top = (bbox[0] * h).toInt().clamp(0, h - 1);
      final left = (bbox[1] * w).toInt().clamp(0, w - 1);
      final bottom = (bbox[2] * h).toInt().clamp(0, h - 1);
      final right = (bbox[3] * w).toInt().clamp(0, w - 1);

      if (bottom <= top || right <= left) return 'неизвестно';

      final bh = bottom - top;

      int redScore = 0, yellowScore = 0, greenScore = 0;
      int totalPixels = 0;

      for (int y = top; y < bottom; y++) {
        for (int x = left; x < right; x++) {
          final pixel = image.getPixel(x, y);
          final r = pixel.r.toInt();
          final g = pixel.g.toInt();
          final b = pixel.b.toInt();

          final brightness = (r + g + b) / 3;
          if (brightness < 80) continue;

          totalPixels++;

          if (y < top + bh * 0.35) {
            if (r > 160 && g < 120 && b < 120) redScore++;
          } else if (y < top + bh * 0.65) {
            if (r > 160 && g > 130 && b < 100) yellowScore++;
          } else {
            if (g > 140 && r < 130 && b < 130) greenScore++;
          }
        }
      }

      if (totalPixels < 20) return 'неизвестно';

      final maxScore = [
        redScore,
        yellowScore,
        greenScore,
      ].reduce((a, b) => a > b ? a : b);

      if (maxScore < 5) return 'неизвестно';

      if (redScore == maxScore && redScore > greenScore * 1.5) return 'красный';
      if (greenScore == maxScore && greenScore > redScore * 1.5) {
        return 'зелёный — можно идти';
      }
      if (yellowScore == maxScore) return 'жёлтый';

      return 'неизвестно';
    } catch (e) {
      debugPrint('TrafficLightAnalyzer.detectColorFromImage error: $e');
      return 'неизвестно';
    }
  }

  // ─── HSV конвертация ──────────────────────────────────────────────────────

  static _HSV _rgbToHsv(int r, int g, int b) {
    final rf = r / 255.0;
    final gf = g / 255.0;
    final bf = b / 255.0;

    final cmax = [rf, gf, bf].reduce((a, b) => a > b ? a : b);
    final cmin = [rf, gf, bf].reduce((a, b) => a < b ? a : b);
    final delta = cmax - cmin;

    double h = 0;
    if (delta > 0) {
      if (cmax == rf) {
        h = 60 * (((gf - bf) / delta) % 6);
      } else if (cmax == gf) {
        h = 60 * (((bf - rf) / delta) + 2);
      } else {
        h = 60 * (((rf - gf) / delta) + 4);
      }
      if (h < 0) h += 360;
    }

    final s = cmax == 0 ? 0.0 : delta / cmax;
    final v = cmax;

    return _HSV(h, s, v);
  }

  /// HSV-версия: более точное определение при плохом освещении.
  /// Принимает уже декодированный img.Image — не вызывает img.decodeJpg.
  static String detectColorHSV(Uint8List jpeg, List<double> bbox) {
    try {
      final image = img.decodeJpg(jpeg);
      if (image == null) return 'неизвестно';
      return detectColorHSVFromImage(image, bbox);
    } catch (e) {
      debugPrint('TrafficLightAnalyzer HSV error: $e');
      return 'неизвестно';
    }
  }

  static String detectColorHSVFromImage(img.Image image, List<double> bbox) {
    try {
      final w = image.width;
      final h = image.height;

      final top = (bbox[0] * h).toInt().clamp(0, h - 1);
      final left = (bbox[1] * w).toInt().clamp(0, w - 1);
      final bottom = (bbox[2] * h).toInt().clamp(0, h - 1);
      final right = (bbox[3] * w).toInt().clamp(0, w - 1);

      if (bottom <= top || right <= left) return 'неизвестно';

      final bh = bottom - top;
      int redCount = 0, greenCount = 0, yellowCount = 0;

      for (int y = top; y < bottom; y++) {
        for (int x = left; x < right; x++) {
          final pixel = image.getPixel(x, y);
          final hsv = _rgbToHsv(
            pixel.r.toInt(),
            pixel.g.toInt(),
            pixel.b.toInt(),
          );

          if (hsv.v < 0.3 || hsv.s < 0.4) continue;

          final zone = (y - top) / bh;

          final isRed = hsv.h < 20 || hsv.h > 340;
          final isYellow = hsv.h >= 40 && hsv.h <= 70;
          final isGreen = hsv.h >= 90 && hsv.h <= 150;

          if (zone < 0.4 && isRed) redCount++;
          if (zone >= 0.3 && zone < 0.65 && isYellow) yellowCount++;
          if (zone >= 0.6 && isGreen) greenCount++;
        }
      }

      final max = [
        redCount,
        yellowCount,
        greenCount,
      ].reduce((a, b) => a > b ? a : b);
      if (max < 3) return 'неизвестно';

      if (redCount == max) return 'красный';
      if (greenCount == max) return 'зелёный — можно идти';
      if (yellowCount == max) return 'жёлтый';

      return 'неизвестно';
    } catch (e) {
      debugPrint('TrafficLightAnalyzer.detectColorHSVFromImage error: $e');
      return 'неизвестно';
    }
  }
}

class _HSV {
  final double h, s, v;
  const _HSV(this.h, this.s, this.v);
}
