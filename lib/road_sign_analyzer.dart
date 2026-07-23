import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// Тип дорожного знака
enum RoadSignType {
  pedestrianCrossing,
  unknown,
}

class DetectedSign {
  final RoadSignType type;
  final String label;
  final double confidence;
  final List<double> bbox; // [top, left, bottom, right] нормализованные

  const DetectedSign({
    required this.type,
    required this.label,
    required this.confidence,
    required this.bbox,
  });
}

/// Офлайн-анализатор **синего знака** «пешеходный переход» через HSV.
/// Не ищет зебру на асфальте/полу — только синий квадрат знака в bbox.
class RoadSignAnalyzer {
  static const double _minBlueRatio = 0.22;
  static const double _minWhiteRatio = 0.08;
  static const double _blueToWhiteMin = 1.2;
  static const double _minBboxSize = 0.04;
  /// Знак обычно в верхней/средней части кадра — низ = пол, ложные срабатывания.
  static const double _maxBboxCenterY = 0.72;

  /// Анализирует JPEG-кадр в заданном bbox.
  /// Декодирует JPEG самостоятельно. Используйте [analyzeFromImage] если
  /// у вас уже есть декодированный img.Image — это быстрее.
  static DetectedSign? analyze(
    Uint8List jpeg,
    List<double> bbox, {
    String yoloLabel = '',
  }) {
    try {
      final image = img.decodeJpg(jpeg);
      if (image == null) return null;
      return analyzeFromImage(image, bbox, yoloLabel: yoloLabel);
    } catch (e) {
      debugPrint('RoadSignAnalyzer error: $e');
      return null;
    }
  }

  /// Анализирует уже декодированный img.Image в заданном bbox.
  /// ИСПРАВЛЕНИЕ Проблемы 3: SmartGlassesServices декодирует JPEG один раз
  /// и передаёт сюда готовый объект — повторного img.decodeJpg не происходит.
  static DetectedSign? analyzeFromImage(
    img.Image image,
    List<double> bbox, {
    String yoloLabel = '',
  }) {
    try {
      final bboxH = bbox[2] - bbox[0];
      final bboxW = bbox[3] - bbox[1];
      if (bboxH < _minBboxSize || bboxW < _minBboxSize) return null;

      // Отсекаем пол / ковры / плитку внизу кадра.
      final centerY = (bbox[0] + bbox[2]) / 2;
      if (centerY > _maxBboxCenterY) return null;

      // Знак roughly квадратный; длинные полосы пола отбрасываем.
      final aspect = bboxW / bboxH.clamp(0.001, 10.0);
      if (aspect < 0.55 || aspect > 1.85) return null;

      final w = image.width;
      final h = image.height;

      final top = (bbox[0] * h).toInt().clamp(0, h - 1);
      final left = (bbox[1] * w).toInt().clamp(0, w - 1);
      final bottom = (bbox[2] * h).toInt().clamp(0, h - 1);
      final right = (bbox[3] * w).toInt().clamp(0, w - 1);

      if (bottom <= top || right <= left) return null;

      int blueCount = 0;
      int whiteCount = 0;
      int totalCount = 0;

      for (int y = top; y < bottom; y++) {
        for (int x = left; x < right; x++) {
          final pixel = image.getPixel(x, y);
          final hsv = _rgbToHsv(
            pixel.r.toInt(),
            pixel.g.toInt(),
            pixel.b.toInt(),
          );
          totalCount++;

          if (hsv.h >= 175 && hsv.h <= 255 && hsv.s > 0.20 && hsv.v > 0.18) {
            blueCount++;
          }
          if (hsv.s < 0.35 && hsv.v > 0.65) {
            whiteCount++;
          }
        }
      }

      if (totalCount == 0) return null;

      final blueRatio = blueCount / totalCount;
      final whiteRatio = whiteCount / totalCount;

      debugPrint(
        '🔍 SignAnalyzer bbox=$bbox '
        'blue=${(blueRatio * 100).toStringAsFixed(1)}% '
        'white=${(whiteRatio * 100).toStringAsFixed(1)}%',
      );

      if (_isPedestrianCrossing(blueRatio, whiteRatio)) {
        final conf =
            _confidence(blueRatio, _minBlueRatio, 0.60) *
            _confidence(whiteRatio, _minWhiteRatio, 0.40);
        return DetectedSign(
          type: RoadSignType.pedestrianCrossing,
          label: 'Пешеходный переход',
          confidence: conf.clamp(0.0, 1.0),
          bbox: bbox,
        );
      }

      return null;
    } catch (e) {
      debugPrint('RoadSignAnalyzer.analyzeFromImage error: $e');
      return null;
    }
  }

  static bool _isPedestrianCrossing(double blueRatio, double whiteRatio) {
    if (blueRatio < _minBlueRatio) return false;
    if (whiteRatio < _minWhiteRatio) return false;
    if (whiteRatio > 0 && blueRatio / whiteRatio < _blueToWhiteMin)
      return false;
    if (whiteRatio > 0.55) return false;
    return true;
  }

  static double _confidence(double value, double low, double high) {
    if (value <= low) return 0.0;
    if (value >= high) return 1.0;
    return (value - low) / (high - low);
  }

  static _HSV _rgbToHsv(int r, int g, int b) {
    final rf = r / 255.0;
    final gf = g / 255.0;
    final bf = b / 255.0;

    final cmax = rf > gf ? (rf > bf ? rf : bf) : (gf > bf ? gf : bf);
    final cmin = rf < gf ? (rf < bf ? rf : bf) : (gf < bf ? gf : bf);
    final delta = cmax - cmin;

    double h = 0;
    if (delta > 0.001) {
      if (cmax == rf) {
        h = 60 * (((gf - bf) / delta) % 6);
      } else if (cmax == gf) {
        h = 60 * (((bf - rf) / delta) + 2);
      } else {
        h = 60 * (((rf - gf) / delta) + 4);
      }
      if (h < 0) h += 360;
    }

    final s = cmax < 0.001 ? 0.0 : delta / cmax;
    return _HSV(h, s, cmax);
  }

  /// Полный скан кадра отключён: давал ложные «пешеходные переходы» на плитке/ковре.
  @Deprecated('Вызывает ложные срабатывания на полу — не использовать')
  static DetectedSign? scanFullFrame(Uint8List jpeg) => null;

  @Deprecated('Вызывает ложные срабатывания на полу — не использовать')
  static DetectedSign? scanFullFrameFromImage(img.Image image) => null;
}

class _HSV {
  final double h, s, v;
  const _HSV(this.h, this.s, this.v);
}
