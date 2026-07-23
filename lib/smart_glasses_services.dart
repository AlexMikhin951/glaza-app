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
import 'hazard_service.dart';
import 'core/speech_bus.dart';
import 'core/frame_hub.dart';
import 'core/ru_cloud_config.dart';
import 'core/mode_controller.dart';
import 'vision/color_service.dart';
import 'vision/light_service.dart';
import 'vision/currency_service.dart';
import 'vision/barcode_service.dart';
import 'vision/find_service.dart';
import 'vision/depth_service.dart';
import 'vision/face_service.dart';
import 'cloud_ru/yandex_gpt_client.dart';
import 'cloud_ru/yandex_vision_client.dart';
import 'cloud_ru/gigachat_client.dart';
import 'safety/sos_service.dart';
import 'map/soundscape_layer.dart';

export 'radar_service.dart';
export 'vibration_service.dart';
export 'map_awareness_service.dart';
export 'reading_service.dart';
export 'traffic_light_analyzer.dart';
export 'road_sign_analyzer.dart';
export 'voice_mode_selector.dart';
export 'navigation_service.dart';
export 'hazard_service.dart';
export 'core/speech_bus.dart';
export 'core/mode_controller.dart';
export 'core/ru_cloud_config.dart';
export 'map/soundscape_layer.dart';

img.Image? _decodeJpg(Uint8List bytes) => img.decodeJpg(bytes);

/// Центральный координатор всех сервисов приложения.
class SmartGlassesServices {
  final FlutterTts tts;
  final Map<String, String> savedPlaces;

  late final SpeechBus speech;
  late final FrameHub frames;
  late final RuCloudConfig cloud;
  late final NavigationService navigation;
  late final RadarService radar;
  late final VibrationService vibration;
  late final MapAwarenessService map;
  late final ReadingService reading;
  late final ModeController modeSelector;
  late final HazardService hazards;
  late final ColorService colors;
  late final LightService light;
  late final CurrencyService currency;
  late final BarcodeService barcode;
  late final FindService find;
  late final DepthService depth;
  late final FaceService faces;
  late final YandexGptClient yandexGpt;
  late final YandexVisionClient yandexVision;
  late final GigaChatClient gigaChat;
  late final SosService sos;
  late final SoundscapeLayer soundscape;

  bool _initialized = false;
  bool _radarMutedForTts = false;

  int lastTrafficLightAnalysisTime = 0;
  String lastTrafficLightColor = '';
  int lastSignAnalysisTime = 0;
  String lastSignLabel = '';
  int lastSignSpokenMs = 0;
  int _signConfirmStreak = 0;
  String _signConfirmLabel = '';

  /// Внешний колбэк UI при смене режима (ESP snapshot и т.п.).
  void Function(AppMode mode)? onModeChangedExtra;

  SmartGlassesServices(this.tts, {this.savedPlaces = const {}}) {
    speech = SpeechBus(tts);
    frames = FrameHub();
    cloud = RuCloudConfig();

    Future<void> enqueue(String text, {int? priority}) =>
        speech.enqueue(text, priority: priority);

    radar = RadarService();
    vibration = VibrationService();
    map = MapAwarenessService(tts, enqueueCallback: enqueue);
    reading = ReadingService(enqueueCallback: enqueue);
    modeSelector = ModeController(enqueueCallback: enqueue);
    // hazards создаётся ниже после depth
    colors = ColorService(enqueueCallback: enqueue);
    light = LightService(enqueueCallback: enqueue);
    currency = CurrencyService(enqueueCallback: enqueue);
    barcode = BarcodeService(enqueueCallback: enqueue);
    find = FindService(enqueueCallback: enqueue, radar: radar);
    depth = DepthService();
    faces = FaceService(enqueueCallback: enqueue);
    hazards = HazardService(
      enqueueCallback: enqueue,
      vibration: vibration,
      depth: depth,
    );
    yandexGpt = YandexGptClient(cloud);
    yandexVision = YandexVisionClient(cloud);
    gigaChat = GigaChatClient(cloud);
    yandexGpt.gigaFallback = (sys, user) => gigaChat.complete(sys, user);
    sos = SosService(
      config: cloud,
      vibration: vibration,
      enqueueCallback: enqueue,
    );
    soundscape = SoundscapeLayer(enqueueCallback: enqueue);

    navigation = NavigationService(
      tts,
      enqueueCallback: enqueue,
      interruptTts: interruptSpeaking,
      speakAndWait: speakAndWait,
      savedPlaces: savedPlaces,
      onNavFocus: (focus) {
        if (focus) {
          speech.beginNavFocus();
          map.disable();
        } else {
          speech.endNavFocus();
          final policy = modeSelector.policy;
          if (policy.mapOn) map.enable();
        }
      },
    );

    speech.onMuteRadar = () {
      if (radar.isEnabled && !_radarMutedForTts) {
        _radarMutedForTts = true;
        radar.disable();
      }
    };
    speech.onUnmuteRadar = () {
      if (!_radarMutedForTts) return;
      _radarMutedForTts = false;
      final policy = modeSelector.policy;
      if (policy.radarOn) radar.enable();
    };
  }

  Future<void> init() async {
    if (_initialized) return;

    debugPrint('🔧 Initializing SmartGlassesServices...');
    await cloud.load();
    await speech.init();
    await tts.setSpeechRate(cloud.speechRate);

    reading.cloudOcrFallback = (jpeg) => yandexVision.recognizeText(jpeg);
    soundscape.enabled = cloud.soundscapeEnabled;
    if (cloud.streetQuiet) {
      modeSelector.streetProfile = StreetDetailProfile.quiet;
    }

    await Future.wait([
      radar.init(),
      vibration.init(),
      map.init(),
      reading.init(),
      navigation.init(),
      hazards.init(),
      light.init(),
      depth.init(),
      faces.init(),
      soundscape.init(),
    ]);

    frames.subscribe(
      'safety',
      ({required jpeg, required objects, required timestampMs}) {
        final policy = modeSelector.policy;
        if (!policy.safetyOn) return;
        hazards.onFrame(objects: objects, jpeg: jpeg);
        // Радар по глубине
        depth.nearestMeters(jpeg).then((m) {
          radar.depthMeters = m;
        }).catchError((_) {});
      },
      minIntervalMs: 120,
    );

    frames.subscribe(
      'faces',
      ({required jpeg, required objects, required timestampMs}) {
        final mode = modeSelector.currentMode;
        if (mode == AppMode.reading ||
            mode == AppMode.scene ||
            mode == AppMode.identify) {
          return;
        }
        faces.onFrame(jpeg);
      },
      minIntervalMs: 2000,
    );

    frames.subscribe(
      'find',
      ({required jpeg, required objects, required timestampMs}) {
        if (modeSelector.currentMode != AppMode.find && !find.isActive) {
          return;
        }
        find.onFrame(objects: objects, jpeg: jpeg);
      },
      minIntervalMs: 120,
    );

    frames.subscribe(
      'live_ocr',
      ({required jpeg, required objects, required timestampMs}) {
        if (modeSelector.currentMode != AppMode.reading) return;
        reading.liveOcrTick(jpeg);
      },
      minIntervalMs: 1000,
    );

    modeSelector.onModeChanged = (mode) {
      _onModeChanged(mode);
      onModeChangedExtra?.call(mode);
    };

    _initialized = true;
    _onModeChanged(modeSelector.currentMode);
    debugPrint('✅ SmartGlassesServices ready');
  }

  Future<void> interruptSpeaking() => speech.interrupt();

  Future<void> speakAndWait(String text, {int? priority}) =>
      speech.speakAndWait(text, priority: priority);

  void _onModeChanged(AppMode mode) {
    final policy = ModePolicy.forMode(mode);
    radar.disable();
    vibration.disable();
    map.disable();
    hazards.disable();
    frames.setEnabled('safety', policy.safetyOn);
    frames.setEnabled('live_ocr', mode == AppMode.reading);
    frames.setEnabled('find', mode == AppMode.find || find.isActive);
    _radarMutedForTts = false;

    if (policy.radarOn) radar.enable();
    if (policy.safetyOn) hazards.enable();
    if (policy.vibrationOn) vibration.enable();
    if (policy.mapOn) map.enable();

    soundscape.enabled = cloud.soundscapeEnabled &&
        (mode == AppMode.standard || mode == AppMode.navigation);

    if (mode != AppMode.find && find.isActive) {
      find.stop(announce: false);
    }
  }

  void onFrameAnalyzed({
    required List<DetectedObject> objects,
    required Uint8List jpeg,
  }) {
    if (!_initialized) return;

    frames.publish(jpeg: jpeg, objects: objects);

    final policy = modeSelector.policy;
    final mode = modeSelector.currentMode;

    if (radar.isEnabled) {
      radar.updateObjects(objects);
    }

    if (vibration.isEnabled && !hazards.isEnabled) {
      vibration.analyzeObjects(objects);
    }

    if (policy.safetyOn ||
        mode == AppMode.standard ||
        mode == AppMode.navigation ||
        mode == AppMode.radar ||
        mode == AppMode.find) {
      // hazards уже через FrameHub; дублируем только если safety off в hub
    }

    if (policy.roadSignsOn) {
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

    final hasTraffic =
        trafficDue && objects.any((o) => o.label.contains('traffic light'));
    final hasYoloSign = objects.any(
      (o) =>
          o.label.contains('stop sign') || o.label.contains('traffic sign'),
    );
    final needSignScan = signDue;
    if (!hasTraffic && !needSignScan) return;

    final decoded = await compute(_decodeJpg, jpeg);
    if (decoded == null) return;
    if (hasTraffic) _analyzeTrafficLights(objects, decoded);
    if (needSignScan) {
      _analyzeRoadSigns(objects, jpeg, decoded, hasYoloSign: hasYoloSign);
    }
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
      speech.enqueue('Светофор: $color', priority: SpeechPriority.info);
      break;
    }
  }

  void _analyzeRoadSigns(
    List<DetectedObject> objects,
    Uint8List jpeg,
    img.Image decoded, {
    required bool hasYoloSign,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - lastSignAnalysisTime < 2500) return;
    lastSignAnalysisTime = now;

    // Только по bbox YOLO — без полного скана кадра (пол/плитка давали ложные переходы).
    if (!hasYoloSign) {
      _signConfirmStreak = 0;
      _signConfirmLabel = '';
      return;
    }

    DetectedSign? sign;
    for (final obj in objects) {
      if (obj.score < 0.45) continue;
      if (!obj.label.contains('stop sign') &&
          !obj.label.contains('traffic sign')) {
        continue;
      }
      sign = RoadSignAnalyzer.analyzeFromImage(decoded, obj.rect);
      if (sign != null) break;
    }

    if (sign == null) {
      _signConfirmStreak = 0;
      _signConfirmLabel = '';
      if (now - lastSignSpokenMs > 25000) {
        lastSignLabel = '';
      }
      return;
    }

    if (sign.label == _signConfirmLabel) {
      _signConfirmStreak++;
    } else {
      _signConfirmLabel = sign.label;
      _signConfirmStreak = 1;
    }
    // Нужно 2 подряд подтверждения — меньше ложных срабатываний.
    if (_signConfirmStreak < 2) return;

    if (sign.label == lastSignLabel && now - lastSignSpokenMs < 35000) {
      return;
    }
    lastSignLabel = sign.label;
    lastSignSpokenMs = now;
    _signConfirmStreak = 0;
    speech.enqueue(sign.label, priority: SpeechPriority.info);
    if (sign.type == RoadSignType.pedestrianCrossing) {
      vibration.crossing();
    }
  }

  bool _matchesPhotoCommand(String cmd) =>
      cmd.contains('фото') ||
      cmd.contains('сними') ||
      cmd.contains('сделай снимок') ||
      cmd.contains('сфотографируй') ||
      cmd.contains('сканируй') ||
      cmd.contains('прочитай') ||
      cmd == 'читай';

  bool _matchesSos(String cmd) =>
      cmd.contains('помощь') ||
      cmd.contains('sos') ||
      cmd.contains('соос') ||
      cmd.contains('спасите') ||
      cmd.contains('тревога');

  bool _matchesScene(String cmd) =>
      cmd.contains('что передо мной') ||
      cmd.contains('что перед') ||
      cmd.contains('опиши') ||
      cmd.contains('что вокруг') ||
      cmd.contains('что я вижу');

  bool _matchesColor(String cmd) =>
      cmd.contains('какой цвет') ||
      cmd.contains('какого цвета') ||
      cmd.contains('цвет');

  bool _matchesLight(String cmd) =>
      cmd.contains('какой свет') ||
      cmd == 'свет' ||
      cmd.contains('темно') ||
      cmd.contains('освещение');

  bool _matchesCurrency(String cmd) =>
      cmd.contains('какая купюра') ||
      cmd.contains('какая банкнота') ||
      cmd.contains('купюра') ||
      cmd.contains('банкнота') ||
      cmd.contains('сколько денег');

  bool _matchesBarcode(String cmd) =>
      cmd.contains('штрихкод') ||
      cmd.contains('штрих код') ||
      cmd.contains('баркод') ||
      cmd.contains('qr') ||
      cmd.contains('куар');

  Future<bool> processVoiceCommand(
    String command, {
    Uint8List? currentFrame,
    Future<Uint8List?> Function()? captureFreshFrame,
  }) async {
    final cmd = command.toLowerCase();
    speech.noteHeard(command);

    if (await navigation.handleRouteChoiceCommand(command)) {
      return true;
    }

    if (_matchesSos(cmd)) {
      await sos.trigger();
      return true;
    }

    if (cmd.contains('отправь локацию') ||
        cmd.contains('отправь координаты') ||
        cmd.contains('где я маме') ||
        cmd.contains('поделись локацией')) {
      await sos.shareLocation();
      return true;
    }

    if (cmd.contains('повтор') ||
        cmd.contains('повтори') ||
        cmd.contains('ещё раз') ||
        cmd.contains('еще раз')) {
      await speech.repeatLast();
      return true;
    }

    if (cmd.contains('статус лог') ||
        (cmd.contains('статус') && cmd.contains('голос'))) {
      await speech.enqueue(speech.statusReport(), priority: 0);
      return true;
    }

    if (cmd.contains('который час') ||
        cmd.contains('сколько время') ||
        cmd.contains('который время')) {
      final now = DateTime.now();
      await speech.enqueue(
        'Сейчас ${now.hour} часов ${now.minute.toString().padLeft(2, '0')}.',
        priority: 1,
      );
      return true;
    }

    // Калибровка глубины: «калибровка один метр»
    if (cmd.contains('калибров')) {
      double? meters;
      if (cmd.contains('пять') || RegExp(r'\b5\b').hasMatch(cmd)) {
        meters = 5;
      } else if (cmd.contains('три') || RegExp(r'\b3\b').hasMatch(cmd)) {
        meters = 3;
      } else if (cmd.contains('один') ||
          cmd.contains('метр') ||
          RegExp(r'\b1\b').hasMatch(cmd)) {
        meters = 1;
      }
      if (meters == null) {
        await speech.enqueue(
          'Калибровка. Наведите центр на объект. Скажите: калибровка один метр, три метра или пять метров.',
          priority: 1,
        );
        return true;
      }
      final frame = await _resolveFrame(currentFrame, captureFreshFrame);
      if (frame == null) {
        await speech.enqueue('Нет кадра для калибровки.', priority: 1);
        return true;
      }
      final msg = await depth.calibrateAt(meters, frame);
      await speech.enqueue(msg, priority: 1);
      return true;
    }

    final frameForFace = await _resolveFrame(currentFrame, captureFreshFrame);
    if (await faces.handleCommand(command, frameForFace)) {
      return true;
    }

    if (cmd.startsWith('иду') ||
        cmd.startsWith('маршрут') ||
        cmd.startsWith('построй маршрут') ||
        cmd.startsWith('поведи')) {
      await navigation.handleVoiceDestination(cmd);
      return true;
    }

    // Поиск объекта — до переключения режимов («найди человека»).
    if (await find.handleCommand(command)) {
      if (modeSelector.currentMode != AppMode.find) {
        await modeSelector.setMode(AppMode.find, announce: false);
      }
      frames.setEnabled('find', true);
      return true;
    }

    if (_matchesScene(cmd)) {
      await _runScene(currentFrame: currentFrame, captureFreshFrame: captureFreshFrame);
      return true;
    }

    if (_matchesColor(cmd) &&
        (cmd.contains('цвет') &&
            (cmd.contains('какой') ||
                cmd.contains('какого') ||
                modeSelector.currentMode == AppMode.identify))) {
      final frame = await _resolveFrame(currentFrame, captureFreshFrame);
      if (frame == null) {
        await speech.enqueue('Нет изображения с камеры.', priority: 0);
        return true;
      }
      await colors.announceColor(frame);
      return true;
    }

    if (_matchesLight(cmd) &&
        (cmd.contains('свет') ||
            cmd.contains('темно') ||
            cmd.contains('освещение'))) {
      final frame = await _resolveFrame(currentFrame, captureFreshFrame);
      if (frame == null) {
        await speech.enqueue('Нет изображения с камеры.', priority: 0);
        return true;
      }
      await light.announceLight(frame);
      return true;
    }

    if (_matchesCurrency(cmd)) {
      final frame = await _resolveFrame(currentFrame, captureFreshFrame);
      if (frame == null) {
        await speech.enqueue('Нет изображения с камеры.', priority: 0);
        return true;
      }
      await currency.recognize(frame);
      return true;
    }

    if (_matchesBarcode(cmd)) {
      final frame = await _resolveFrame(currentFrame, captureFreshFrame);
      if (frame == null) {
        await speech.enqueue('Нет изображения с камеры.', priority: 0);
        return true;
      }
      await barcode.scan(frame);
      return true;
    }

    if (cmd.contains('спроси') && reading.lastText.isNotEmpty) {
      final q = command.toLowerCase().replaceFirst('спроси', '').trim();
      if (q.isEmpty) {
        await speech.enqueue('Скажите вопрос по тексту, например: спроси где срок годности.', priority: 0);
        return true;
      }
      if (cloud.offlineOnly || !cloud.hasYandexCloud) {
        await speech.enqueue(
          'Вопросы по тексту нужны интернет и ключ Яндекс Облака.',
          priority: 0,
        );
        return true;
      }
      final answer = await yandexGpt.askAboutText(reading.lastText, q);
      await speech.enqueue(
        answer ?? 'Не удалось ответить. Попробуйте ещё раз.',
        priority: 0,
      );
      return true;
    }

    if (await modeSelector.processCommand(command)) return true;

    if ((modeSelector.currentMode == AppMode.reading ||
            _matchesPhotoCommand(cmd)) &&
        _matchesPhotoCommand(cmd)) {
      if (modeSelector.currentMode != AppMode.reading) {
        await modeSelector.setMode(AppMode.reading, announce: false);
      }
      await speech.enqueue('Сканирую...', priority: 0);
      final frame = await _resolveFrame(currentFrame, captureFreshFrame);
      if (frame == null) {
        await speech.enqueue(
          'Нет изображения. Наведите камеру и скажите: фото.',
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
          await speech.enqueue('Добавлен аллерген: $a', priority: 0);
          return true;
        }
      }
      await speech.enqueue(
        'Не понял какой аллерген. Скажите: добавь аллерген глютен, или лактоза, или арахис.',
        priority: 0,
      );
      return true;
    }

    if (cmd.contains('мои аллергены') || cmd.contains('список аллергенов')) {
      final list = reading.userAllergens;
      if (list.isEmpty) {
        await speech.enqueue('Список аллергенов пуст.', priority: 0);
      } else {
        await speech.enqueue(
          'Ваши аллергены: ${list.join(', ')}',
          priority: 0,
        );
      }
      return true;
    }

    if (cmd.contains('только офлайн') || cmd.contains('режим офлайн')) {
      await cloud.setOfflineOnly(true);
      await speech.enqueue('Только офлайн. Облако Яндекса выключено.', priority: 1);
      return true;
    }
    if (cmd.contains('включи облако') || cmd.contains('разрешить интернет')) {
      await cloud.setOfflineOnly(false);
      await speech.enqueue('Облако разрешено.', priority: 1);
      return true;
    }

    if (cmd.contains('статус') || (cmd.contains('режим') && !cmd.contains('режим '))) {
      final help = await modeSelector.getContextHelp();
      await speech.enqueue(help ?? 'Всё работает', priority: 0);
      return true;
    }

    return false;
  }

  Future<void> _runScene({
    Uint8List? currentFrame,
    Future<Uint8List?> Function()? captureFreshFrame,
  }) async {
    if (cloud.offlineOnly && !cloud.hasYandexCloud) {
      // офлайн YOLO всё равно работает
    } else if (cloud.offlineOnly) {
      await speech.enqueue(
        'Режим только офлайн: опишу по детектору без ЯндексGPT.',
        priority: 0,
      );
    }

    final prev = modeSelector.currentMode;
    await modeSelector.setMode(AppMode.scene, announce: false);
    await speech.enqueue('Смотрю...', priority: 1);

    final frame = await _resolveFrame(currentFrame, captureFreshFrame);
    final objects = frames.latestObjects;

    if (frame == null) {
      await speech.enqueue('Нет кадра с камеры.', priority: 1);
      await modeSelector.setMode(prev, announce: false);
      return;
    }

    try {
      final text = await yandexGpt
          .describeScene(jpeg: frame, objects: objects)
          .timeout(const Duration(seconds: 8));
      await speech.enqueue(text, priority: 1);
    } catch (_) {
      await speech.enqueue(
        'Не удалось описать сцену, попробуйте ещё раз.',
        priority: 1,
      );
    }

    // Вернуть предыдущий уличный режим через 2–3 с политики safety
    await Future.delayed(const Duration(milliseconds: 500));
    if (prev != AppMode.scene) {
      await modeSelector.setMode(prev, announce: false);
    } else {
      await modeSelector.setMode(AppMode.standard, announce: false);
    }
  }

  Future<Uint8List?> _resolveFrame(
    Uint8List? currentFrame,
    Future<Uint8List?> Function()? captureFreshFrame,
  ) async {
    if (captureFreshFrame != null) {
      final fresh = await captureFreshFrame();
      if (fresh != null) return fresh;
    }
    return currentFrame ?? frames.latestJpeg;
  }

  Future<void> speak(String text, {int priority = 0}) =>
      speech.enqueue(text, priority: priority);

  Future<void> speakWelcome() => modeSelector.speakWelcome();

  Future<void> applySpeechRate(double rate) async {
    await cloud.setSpeechRate(rate);
    await tts.setSpeechRate(cloud.speechRate);
  }

  void dispose() {
    radar.dispose();
    vibration.dispose();
    map.dispose();
    reading.dispose();
    navigation.dispose();
    hazards.dispose();
    light.dispose();
    currency.dispose();
    barcode.dispose();
    find.dispose();
    faces.dispose();
    depth.dispose();
    soundscape.dispose();
    speech.dispose();
    frames.clear();
    _initialized = false;
  }
}
