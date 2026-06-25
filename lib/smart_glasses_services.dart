// lib/smart_glasses_services.dart
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:image/image.dart' as img;

import 'ai_detector.dart';
import 'radar_service.dart';
import 'vibration_service.dart';
import 'map_awareness_service.dart';
import 'reading_service.dart';
import 'traffic_light_analyzer.dart';
import 'road_sign_analyzer.dart';
import 'voice_mode_selector.dart';
import 'navigation_service.dart';

export 'radar_service.dart';
export 'vibration_service.dart';
export 'map_awareness_service.dart';
export 'reading_service.dart';
export 'traffic_light_analyzer.dart';
export 'road_sign_analyzer.dart';
export 'voice_mode_selector.dart';
export 'navigation_service.dart';

/// Декодирование JPEG в отдельном изолированном потоке.
img.Image? _decodeJpg(Uint8List bytes) => img.decodeJpg(bytes);

class _TtsMessage {
  final String text;
  final int priority;
  final int timestamp;
  _TtsMessage(this.text, this.priority)
    : timestamp = DateTime.now().millisecondsSinceEpoch;
}

/// Центральный координатор всех сервисов приложения.
class SmartGlassesServices {
  final FlutterTts tts;
  final Map<String, String> savedPlaces;

  late final NavigationService navigation;
  late final RadarService radar;
  late final VibrationService vibration;
  late final MapAwarenessService map;
  late final ReadingService reading;
  late final VoiceModeSelector modeSelector;

  bool _initialized = false;

  final List<_TtsMessage> _ttsQueue = [];
  bool _ttsBusy = false;
  String _lastSpokenText = '';

  int lastTrafficLightAnalysisTime = 0;
  String lastTrafficLightColor = '';
  int lastSignAnalysisTime = 0;
  String lastSignLabel = '';
  int _lastFullScanTime = 0;

  SmartGlassesServices(this.tts, {this.savedPlaces = const {}}) {
    radar = RadarService();
    vibration = VibrationService();
    map = MapAwarenessService(tts, enqueueCallback: _enqueueTts);
    reading = ReadingService(enqueueCallback: _enqueueTts);
    modeSelector = VoiceModeSelector(tts, enqueueCallback: _enqueueTts);

    navigation = NavigationService(
      tts,
      enqueueCallback: _enqueueTts,
      savedPlaces: savedPlaces,
    );
  }

  Future<void> init() async {
    if (_initialized) return;

    debugPrint('🔧 Initializing SmartGlassesServices...');

    await Future.wait([
      radar.init(),
      vibration.init(),
      map.init(),
      reading.init(),
      navigation.init(),
    ]);

    tts.setCompletionHandler(_onTtsComplete);
    tts.setErrorHandler((msg) {
      debugPrint('TTS error: $msg');
      _ttsBusy = false;
      _drainTtsQueue();
    });

    modeSelector.onModeChanged = _onModeChanged;

    _initialized = true;
    debugPrint('✅ SmartGlassesServices ready');
  }

  Future<void> _enqueueTts(String text, {int? priority}) async {
    if (text.isEmpty) return;

    final int p = priority ?? 0;

    if (_ttsQueue.any((m) => m.text == text)) return;

    final msg = _TtsMessage(text, p);

    if (p >= 3 && _ttsBusy && text != _lastSpokenText) {
      await tts.stop();
      _ttsBusy = false;
      _ttsQueue.clear();
    }

    _ttsQueue.add(msg);
    _ttsQueue.sort((a, b) {
      final pc = b.priority.compareTo(a.priority);
      return pc != 0 ? pc : a.timestamp.compareTo(b.timestamp);
    });

    _ttsQueue.removeWhere(
      (m) =>
          m.priority == 0 &&
          DateTime.now().millisecondsSinceEpoch - m.timestamp > 5000,
    );

    if (!_ttsBusy) _drainTtsQueue();
  }

  void _onTtsComplete() {
    _ttsBusy = false;
    _drainTtsQueue();
  }

  void _drainTtsQueue() {
    if (_ttsBusy || _ttsQueue.isEmpty) return;
    final msg = _ttsQueue.removeAt(0);
    _ttsBusy = true;
    _lastSpokenText = msg.text;
    tts.speak(msg.text).catchError((e) {
      debugPrint('TTS drain error: $e');
      _ttsBusy = false;
      _drainTtsQueue();
    });
  }

  void _onModeChanged(AppMode mode) {
    radar.disable();
    vibration.disable();
    map.disable();

    if (mode != AppMode.reading) {
      radar.enable();
    }

    switch (mode) {
      case AppMode.navigation:
        map.enable();
        vibration.enable();
        break;
      case AppMode.standard:
        vibration.enable();
        break;
      case AppMode.reading:
        break;
      case AppMode.radar:
        vibration.enable();
        break;
    }
  }

  void onFrameAnalyzed({
    required List<DetectedObject> objects,
    required Uint8List jpeg,
  }) {
    if (!_initialized) return;

    final mode = modeSelector.currentMode;

    if (radar.isEnabled) {
      radar.updateObjects(objects);
    }

    if (vibration.isEnabled) {
      vibration.analyzeObjects(objects);
    }

    if (mode == AppMode.standard || mode == AppMode.navigation) {
      _analyzeFrameVisuals(objects, jpeg);
    }
  }

  Future<void> _analyzeFrameVisuals(
    List<DetectedObject> objects,
    Uint8List jpeg,
  ) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final trafficDue = now - lastTrafficLightAnalysisTime >= 2000;
    final signDue = now - lastSignAnalysisTime >= 2500;
    if (!trafficDue && !signDue) return;

    final decoded = await compute(_decodeJpg, jpeg);
    if (decoded == null) return;
    _analyzeTrafficLights(objects, decoded);
    _analyzeRoadSigns(objects, jpeg, decoded);
  }

  void _analyzeTrafficLights(List<DetectedObject> objects, img.Image decoded) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - lastTrafficLightAnalysisTime < 2000) return;

    for (final obj in objects) {
      if (!obj.label.contains('traffic light')) continue;
      final color = TrafficLightAnalyzer.detectColorFromImage(decoded, obj.rect);
      if (color.isEmpty || color == lastTrafficLightColor) continue;
      lastTrafficLightColor = color;
      lastTrafficLightAnalysisTime = now;
      _enqueueTts('Светофор: $color', priority: 1);
      break;
    }
  }

  void _analyzeRoadSigns(
    List<DetectedObject> objects,
    Uint8List jpeg,
    img.Image decoded,
  ) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - lastSignAnalysisTime < 2500) return;

    for (final obj in objects) {
      if (!obj.label.contains('stop sign') &&
          !obj.label.contains('traffic sign')) {
        continue;
      }
      final sign = RoadSignAnalyzer.analyzeFromImage(decoded, obj.rect);
      if (sign == null || sign.label == lastSignLabel) continue;
      lastSignLabel = sign.label;
      lastSignAnalysisTime = now;
      _enqueueTts(sign.label, priority: 1);
      break;
    }

    if (now - _lastFullScanTime >= 8000) {
      _runFullScanAsync(jpeg, now);
    }
  }

  Future<void> _runFullScanAsync(Uint8List jpeg, int triggerTime) async {
    try {
      final sign = RoadSignAnalyzer.scanFullFrame(jpeg);
      if (sign != null && sign.label != lastSignLabel) {
        lastSignLabel = sign.label;
        lastSignAnalysisTime = triggerTime;
        _lastFullScanTime = triggerTime;
        await _enqueueTts(sign.label, priority: 1);
      }
    } catch (e) {
      debugPrint('Full scan error: $e');
    }
  }

  bool _matchesPhotoCommand(String cmd) =>
      cmd.contains('фото') ||
      cmd.contains('сними') ||
      cmd.contains('сделай снимок') ||
      cmd.contains('сфотографируй') ||
      cmd.contains('сканируй');

  Future<bool> processVoiceCommand(
    String command, {
    Uint8List? currentFrame,
    Future<Uint8List?> Function()? captureFreshFrame,
  }) async {
    final cmd = command.toLowerCase();

    if (cmd.startsWith('иду') ||
        cmd.startsWith('маршрут') ||
        cmd.startsWith('построй маршрут') ||
        cmd.startsWith('поведи')) {
      await navigation.handleVoiceDestination(cmd);
      return true;
    }

    if (await modeSelector.processCommand(command)) return true;

    if (modeSelector.currentMode == AppMode.reading &&
        _matchesPhotoCommand(cmd)) {
      await _enqueueTts('Сканирую...', priority: 0);
      var frame = currentFrame;
      if (captureFreshFrame != null) {
        frame = await captureFreshFrame();
      }
      if (frame == null) {
        await _enqueueTts(
          'Нет изображения. Наведите камеру и переключитесь в режим чтения.',
          priority: 0,
        );
        return true;
      }
      await reading.analyzePhoto(frame);
      return true;
    }

    if (cmd.contains('добавь аллерген')) {
      for (final a in reading.availableAllergens) {
        if (cmd.contains(a)) {
          final updated = [...reading.userAllergens, a];
          await reading.saveProfile(updated);
          await _enqueueTts('Добавлен аллерген: $a', priority: 0);
          return true;
        }
      }
      await _enqueueTts(
        'Не понял какой аллерген. Скажите: добавь аллерген глютен, или лактоза, или арахис.',
        priority: 0,
      );
      return true;
    }

    if (cmd.contains('мои аллергены') || cmd.contains('список аллергенов')) {
      final list = reading.userAllergens;
      if (list.isEmpty) {
        await _enqueueTts('Список аллергенов пуст.', priority: 0);
      } else {
        await _enqueueTts('Ваши аллергены: ${list.join(', ')}', priority: 0);
      }
      return true;
    }

    if (cmd.contains('статус') || cmd.contains('режим')) {
      final help = await modeSelector.getContextHelp();
      await _enqueueTts(help ?? 'Всё работает', priority: 0);
      return true;
    }

    return false;
  }

  Future<void> speak(String text, {int priority = 0}) =>
      _enqueueTts(text, priority: priority);

  void dispose() {
    radar.dispose();
    vibration.dispose();
    map.dispose();
    reading.dispose();
    navigation.dispose();
    _ttsQueue.clear();
    _initialized = false;
  }
}
