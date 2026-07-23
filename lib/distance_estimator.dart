import 'dart:math';

import 'ai_detector.dart';

/// Оценка дистанции для ESP32-CAM с **OV5640** и широким/искажённым объективом.
///
/// Pinhole на 55° сильно ошибается: у типичных модулей VFOV ~70–90°,
/// плюс бочкообразная дисторсия — объекты по краям «сжимаются».
/// Здесь: шире FOV + поправка на радиус от центра кадра.
class DistanceEstimator {
  /// Вертикальный угол обзора OV5640 wide (градусы → радианы).
  static const double verticalFovRad = 78 * pi / 180;

  /// Сила barrel-дисторсии (0 = нет, 0.15–0.35 типично для wide OV5640).
  static const double barrelK = 0.25;

  /// Высота камеры на очках, м.
  static const double cameraHeightM = 1.55;

  /// Наклон камеры вниз, градусы.
  static const double pitchDownDeg = 15;

  static const Map<String, double> _realHeightsM = {
    'person': 1.70,
    'bicycle': 1.10,
    'motorcycle': 1.20,
    'car': 1.50,
    'bus': 3.00,
    'truck': 3.20,
    'stop sign': 2.50,
    'traffic light': 3.50,
    'dog': 0.55,
    'bench': 0.80,
    'fire hydrant': 0.75,
  };

  static const Map<String, String> labelRu = {
    'person': 'человек',
    'bicycle': 'велосипед',
    'motorcycle': 'мотоцикл',
    'car': 'машина',
    'bus': 'автобус',
    'truck': 'грузовик',
    'stop sign': 'знак стоп',
    'traffic light': 'светофор',
    'dog': 'собака',
    'bench': 'скамейка',
    'fire hydrant': 'гидрант',
  };

  /// Нормализованный радиус от центра кадра (0..√2).
  static double _radiusFromCenter(double cy, double cx) {
    final dy = cy - 0.5;
    final dx = cx - 0.5;
    return sqrt(dx * dx + dy * dy);
  }

  /// Коэффициент «растяжения» размера bbox из‑за barrel (у краёв объект меньше).
  static double _sizeBoostForRadius(double r) {
    // r≈0 центр, r≈0.7 угол кадра
    return 1.0 + barrelK * r * r * 2.2;
  }

  /// Угол луча от оптической оси с учётом дисторсии (радианы, знак: + вниз).
  static double _rayAngleFromNormY(double yNorm) {
    final y = (yNorm - 0.5).clamp(-0.5, 0.5);
    final r = (y.abs() * 2).clamp(0.0, 1.0);
    // equidistant-подобная поправка: угол растёт быстрее к краю
    final rCorr = (r * (1.0 + barrelK * r * r)).clamp(0.0, 1.15);
    return y.sign * rCorr * (verticalFovRad / 2);
  }

  /// Оценка дистанции в метрах по bbox.
  static double? estimateMeters(DetectedObject obj) {
    final key = _matchKey(obj.label);
    if (key == null) return null;
    final realH = _realHeightsM[key]!;

    final top = obj.rect[0];
    final left = obj.rect[1];
    final bottom = obj.rect[2];
    final right = obj.rect[3];
    final bboxH = (bottom - top).clamp(0.03, 0.95);
    final bboxW = (right - left).clamp(0.02, 0.95);
    final cx = (left + right) / 2;
    final cy = (top + bottom) / 2;
    final r = _radiusFromCenter(cy, cx);

    // У краёв wide-объектива bbox меньше → без поправки дистанция завышена.
    final hEff = (bboxH * _sizeBoostForRadius(r)).clamp(0.03, 0.98);

    // Для машин иногда надёжнее ширина (высота обрезана кадром).
    double d;
    if (_isVehicleKey(key) && bboxH > 0.55 && bboxW > 0.2) {
      // Частично в кадре — опираемся на ширину ~1.8 м легковой.
      const realW = 1.8;
      final wEff = (bboxW * _sizeBoostForRadius(r)).clamp(0.05, 0.98);
      final dW = realW / (2.0 * wEff * tan(verticalFovRad / 2));
      final dH = realH / (2.0 * hEff * tan(verticalFovRad / 2));
      d = min(dW, dH);
    } else {
      d = realH / (2.0 * hEff * tan(verticalFovRad / 2));
    }

    // Объекты у самого низа кадра почти никогда не дальше ~8–12 м на очках.
    if (bottom > 0.88 && d > 10) d = min(d, 8.0);
    if (bottom > 0.75 && d > 16) d = min(d, 12.0);

    return d.clamp(0.6, 35.0);
  }

  /// Дистанция до точки на земле по Y в кадре (с поправкой FOV/дисторсии).
  static double groundPlaneMeters({
    required double normalizedBottomY,
    double? normalizedCenterX,
  }) {
    final pitch = pitchDownDeg * pi / 180;
    final ray = _rayAngleFromNormY(normalizedBottomY);
    final angleFromHorizon = pitch + ray;
    if (angleFromHorizon < 0.08) return 18.0;

    var d = cameraHeightM / tan(angleFromHorizon);

    // По краям wide-линзы земля «загибается» — слегка уменьшаем дистанцию.
    if (normalizedCenterX != null) {
      final r = _radiusFromCenter(normalizedBottomY, normalizedCenterX);
      d *= 1.0 / (1.0 + 0.35 * r * r);
    }

    // Нижние 15% кадра — зона ног/трости: обычно 0.8–4 м.
    if (normalizedBottomY > 0.88) d = min(d, 4.5);
    if (normalizedBottomY > 0.78) d = min(d, 7.0);

    return d.clamp(0.7, 18.0);
  }

  static String? russianLabel(String label) {
    final key = _matchKey(label);
    return key == null ? null : labelRu[key];
  }

  static bool isHazardLabel(String label) {
    final l = label.toLowerCase();
    return l.contains('person') ||
        l.contains('car') ||
        l.contains('truck') ||
        l.contains('bus') ||
        l.contains('motorcycle') ||
        l.contains('bicycle') ||
        l.contains('dog') ||
        l.contains('stop sign');
  }

  static bool _isVehicleKey(String key) =>
      key == 'car' || key == 'truck' || key == 'bus';

  static String? _matchKey(String label) {
    final l = label.toLowerCase();
    for (final key in _realHeightsM.keys) {
      if (l.contains(key)) return key;
    }
    return null;
  }

  /// Крупные шаги для речи — лучше сказать «около пяти», чем ложные «три».
  static int speakableMeters(double m) {
    if (m < 2.2) return 2;
    if (m < 4.0) return 3;
    if (m < 6.5) return 5;
    if (m < 9.5) return 8;
    if (m < 13) return 10;
    if (m < 18) return 15;
    return 20;
  }
}
