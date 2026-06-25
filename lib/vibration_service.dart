import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:vibration/vibration.dart';
import 'ai_detector.dart';

/// Паттерны вибрации:
/// - Опасность (машина близко) — длинная пульсация
/// - Человек рядом — короткая одиночная
/// - Пешеходный переход — двойная (вызывается только из _onSignDetected)
/// - SOS — три коротких, три длинных, три коротких
class VibrationService {
  bool _enabled = false;
  bool _hasVibrator = false;
  int _lastVibrationTime = 0;

  static const int _cooldownMs = 2000;

  Future<void> init() async {
    try {
      _hasVibrator = await Vibration.hasVibrator() ?? false;
      debugPrint('✅ VibrationService initialized, hasVibrator=$_hasVibrator');
    } catch (e) {
      debugPrint('⚠️ VibrationService init error: $e');
    }
  }

  void enable() => _enabled = true;
  void disable() {
    _enabled = false;
    _cancelVibration();
  }

  bool get isEnabled => _enabled;

  /// Анализирует детекции YOLO и вибрирует по ситуации.
  ///
  /// ИСПРАВЛЕНИЕ Проблемы 4: убран вызов crossing() для 'traffic light'.
  /// До исправления crossing() вызывался здесь И в SmartGlassesServices._onSignDetected()
  /// когда YOLO видела светофор рядом с пешеходным знаком — пользователь
  /// получал двойную вибрацию за одно событие.
  /// Теперь crossing() вызывается исключительно из _onSignDetected()
  /// когда HSV-анализатор подтвердил наличие знака пешехода.
  void analyzeObjects(List<DetectedObject> objects) {
    if (!_enabled || !_hasVibrator) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastVibrationTime < _cooldownMs) return;

    for (final obj in objects) {
      final height = obj.rect[2] - obj.rect[0];
      final width = obj.rect[3] - obj.rect[1];
      final size = (height + width) / 2;

      if (_isCar(obj.label) && size > 0.45) {
        danger();
        _lastVibrationTime = now;
        return;
      }
      if (obj.label.contains('person') && size > 0.55) {
        person();
        _lastVibrationTime = now;
        return;
      }
      // traffic light: вибрацию убрали отсюда — см. комментарий выше.
      // stop sign: лёгкая вибрация остаётся — это не дублируется нигде.
      if (obj.label.contains('stop sign')) {
        gentle();
        _lastVibrationTime = now;
        return;
      }
    }
  }

  bool _isCar(String label) =>
      label.contains('car') ||
      label.contains('truck') ||
      label.contains('bus') ||
      label.contains('motorcycle');

  /// Вибрация опасности: три длинных удара
  void danger() {
    if (!_hasVibrator) return;
    try {
      Vibration.vibrate(
        pattern: [0, 400, 100, 400, 100, 400],
        intensities: [0, 255, 0, 255, 0, 255],
      );
    } catch (e) {
      debugPrint('Vibration.danger error: $e');
    }
  }

  /// Вибрация "человек": одна короткая
  void person() {
    if (!_hasVibrator) return;
    try {
      Vibration.vibrate(duration: 150, amplitude: 180);
    } catch (e) {
      debugPrint('Vibration.person error: $e');
    }
  }

  /// Вибрация перекрёстка: два коротких.
  /// Вызывается только из SmartGlassesServices._onSignDetected().
  void crossing() {
    if (!_hasVibrator) return;
    try {
      Vibration.vibrate(
        pattern: [0, 120, 80, 120],
        intensities: [0, 200, 0, 200],
      );
    } catch (e) {
      debugPrint('Vibration.crossing error: $e');
    }
  }

  /// Лёгкая вибрация (знак, порог и т.п.)
  void gentle() {
    if (!_hasVibrator) return;
    try {
      Vibration.vibrate(duration: 80, amplitude: 120);
    } catch (e) {
      debugPrint('Vibration.gentle error: $e');
    }
  }

  /// SOS — три коротких, три длинных, три коротких
  void sos() {
    if (!_hasVibrator) return;
    try {
      Vibration.vibrate(
        pattern: [
          0,
          100, 100,
          100, 100,
          100, 200,
          300, 300,
          100, 300,
          100, 300,
          200, 100,
          100, 100,
          100, 100,
        ],
      );
    } catch (e) {
      debugPrint('Vibration.sos error: $e');
    }
  }

  void _cancelVibration() {
    try {
      Vibration.cancel();
    } catch (_) {}
  }

  void dispose() {
    disable();
  }
}
