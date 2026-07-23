// lib/fpv_screen.dart
import 'dart:async';
import 'dart:convert';
import 'dart:math' show max;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:latlong2/latlong.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
// Импортируем только нужные типы — иначе Map/Icon/TextStyle
// конфликтуют с dart:core и Flutter.
import 'package:yandex_maps_mapkit/mapkit.dart'
    show
        MapWindow,
        CameraPosition,
        Point,
        Polyline,
        Geometry,
        BoundingBox,
        MapObjectCollection,
        PolylineMapObject,
        PlacemarkMapObject;
import 'package:yandex_maps_mapkit/mapkit_factory.dart';
import 'package:yandex_maps_mapkit/yandex_map.dart';

import 'ai_detector.dart';
import 'camera_preview_widget.dart';
import 'camera_command.dart';
import 'smart_glasses_services.dart';
import 'perf_logger.dart';
import 'udp_video_pipeline.dart';
import 'setup_screen.dart'; // Нужен для kUdpPort и SetupScreen
import 'caching_tile_provider.dart';
import 'offline_map_storage.dart';
import 'offline_map_preview_screen.dart';
import 'app_theme.dart';
import 'app_widgets.dart';
import 'local_ip.dart';

class FpvScreen extends StatefulWidget {
  final Map<String, String> savedPlaces;
  const FpvScreen({super.key, this.savedPlaces = const {}});

  @override
  State<FpvScreen> createState() => _FpvScreenState();
}

class _FpvScreenState extends State<FpvScreen> with WidgetsBindingObserver {
  final UdpVideoPipeline _udpPipeline = UdpVideoPipeline();
  StreamSubscription<UdpFrameMessage>? _udpFrameSub;

  Uint8List? _latestDisplayFrame;
  Uint8List? _latestFrameForCommands;

  final EspCameraController _espCamera = EspCameraController();
  AppMode? _modeBeforeReading;
  Completer<Uint8List?>? _readingSnapshotCompleter;

  final ValueNotifier<Uint8List?> _frameNotifier = ValueNotifier(null);
  final ValueNotifier<List<DetectedObject>> _detectionsNotifier =
      ValueNotifier([]);
  final ValueNotifier<int> _fpsNotifier = ValueNotifier(0);
  final ValueNotifier<int> _uiFpsNotifier = ValueNotifier(0);
  final ValueNotifier<int> _aiFpsNotifier = ValueNotifier(0);
  final ValueNotifier<int> _kbpsNotifier = ValueNotifier(0);

  final AiDetector _aiDetector = AiDetector();
  final FlutterTts _tts = FlutterTts();
  final stt.SpeechToText _speechToText = stt.SpeechToText();

  late final SmartGlassesServices _services;

  bool _isProcessingAI = false;
  int _lastAiProcessTime = 0;
  int _lastUiUpdateTime = 0;
  int _lastDetectionUiTime = 0;
  Uint8List? _latestAiFrame;
  /// Инкрементируется только при новом UDP-кадре; AI не крутит один JPEG по кругу.
  int _aiFrameGen = 0;
  int _lastProcessedAiGen = 0;
  static const _uiFrameIntervalMs = 40; // до ~25 UI FPS если кадры есть
  static const _detectionUiIntervalMs = 400;

  int _lastSpokenTime = 0;

  int _framesReceivedThisSecond = 0;
  int _uiFramesThisSecond = 0;
  int _aiFramesThisSecond = 0;
  int _bytesReceivedThisSecond = 0;
  Timer? _fpsTimer;

  String _debugInfo = "Ожидание пакетов...";

  bool _isListening = false;
  bool _hasSpokenConnected = false;
  Timer? _listenTimeout;
  Timer? _videoWatchdog;
  int _lastFrameMs = 0;
  bool _connectionLostAnnounced = false;
  bool _awaitingRouteChoiceUi = false;

  // Навигация — карта
  MapWindow? _mapWindow;
  MapObjectCollection? _routeLayer;
  PolylineMapObject? _routePolyline;
  PlacemarkMapObject? _destPlacemark;
  LatLng? _userLatLng;
  LatLng? _destLatLng;
  List<LatLng> _routePoints = [];
  StreamSubscription<Position>? _positionSub;

  // Громче+тише одновременно → микрофон
  DateTime? _volUpDownAt;
  DateTime? _volDownDownAt;
  Timer? _volAloneTimer;
  bool _volChordHandled = false;

  bool _settingsOpen = false;

  // Переменная ожидания двухэтапного диалога набора адреса
  bool _awaitingAddress = false;
  String _navDebugLog = '';

  // Провайдер офлайн-тайлов с in-memory индексом
  final IndexedCachingTileProvider _tileProvider = IndexedCachingTileProvider();

  int _lastLocationUiMs = 0;
  static const _locationUiIntervalMs = 2500;

  AppMode get _currentMode => _services.modeSelector.currentMode;

  void _moveMapTo(LatLng target, {double zoom = 16.0}) {
    final mapWindow = _mapWindow;
    if (mapWindow == null) return;
    try {
      mapWindow.map.move(
        CameraPosition(
          Point(latitude: target.latitude, longitude: target.longitude),
          zoom: zoom,
          azimuth: 0.0,
          tilt: 0.0,
        ),
      );
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      mapkit.onStart();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      mapkit.onStop();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    HardwareKeyboard.instance.addHandler(_onHardwareKey);
    mapkit.onStart();

    _services = SmartGlassesServices(_tts, savedPlaces: widget.savedPlaces);

    _setupAIandVoice().then((_) {
      if (mounted) _startUdpServer(kUdpPort);
    });

    _fpsTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        _fpsNotifier.value = _framesReceivedThisSecond;
        _uiFpsNotifier.value = _uiFramesThisSecond;
        _aiFpsNotifier.value = _aiFramesThisSecond;
        _kbpsNotifier.value = _bytesReceivedThisSecond ~/ 1024;

        // Логируем FPS/bandwidth каждую секунду
        final perf = PerfLogger.instance;
        perf.log('fps_udp', _framesReceivedThisSecond);
        perf.log('fps_ai', _aiFramesThisSecond);
        perf.log('fps_ui', _uiFramesThisSecond);
        perf.log('kbps', _bytesReceivedThisSecond ~/ 1024);
        perf.flush();

        _framesReceivedThisSecond = 0;
        _uiFramesThisSecond = 0;
        _aiFramesThisSecond = 0;
        _bytesReceivedThisSecond = 0;
      }
    });

    _startLocationTracking();
  }

  void _startLocationTracking() {
    _positionSub =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 8,
          ),
        ).listen((pos) {
          if (!mounted) return;
          final ll = LatLng(pos.latitude, pos.longitude);
          _userLatLng = ll;
          _services.soundscape.onLocation(pos);
          final pois = _services.map.soundscapePois();
          if (pois.isNotEmpty) {
            _services.soundscape.setPois([
              for (final p in pois) SoundscapePoi(p.name, p.lat, p.lon),
            ]);
          }

          final now = DateTime.now().millisecondsSinceEpoch;
          final shouldRefreshUi =
              now - _lastLocationUiMs >= _locationUiIntervalMs;
          if (!shouldRefreshUi) return;

          _lastLocationUiMs = now;
          if (_currentMode == AppMode.navigation) {
            setState(() {});
            _moveMapTo(ll);
          }
        });

    Geolocator.getCurrentPosition(desiredAccuracy: LocationAccuracy.high)
        .then((pos) {
          if (!mounted) return;
          _userLatLng = LatLng(pos.latitude, pos.longitude);
          setState(() {});
        })
        .catchError((_) {});
  }

  void _cancelRoute() {
    _awaitingAddress = false;
    _awaitingRouteChoiceUi = false;
    if (_isListening) {
      _stopListening(announce: false);
    }
    _services.navigation.stopNavigation(announce: true);
    _clearRouteOnMap();
    if (mounted) {
      setState(() {
        _routePoints = [];
        _destLatLng = null;
        _navDebugLog = '';
      });
    }
  }

  void _clearRouteOnMap() {
    try {
      _routeLayer?.clear();
    } catch (_) {}
    _routePolyline = null;
    _destPlacemark = null;
  }

  void _drawRouteOnMap(List<LatLng> points, LatLng dest) {
    final mapWindow = _mapWindow;
    if (mapWindow == null) return;
    try {
      _routeLayer ??= mapWindow.map.mapObjects.addCollection();
      _routeLayer!.clear();
      _routePolyline = null;
      _destPlacemark = null;

      if (points.length >= 2) {
        final geo = points
            .map((p) => Point(latitude: p.latitude, longitude: p.longitude))
            .toList();
        final poly = _routeLayer!.addPolylineWithGeometry(Polyline(geo));
        poly.setStrokeColor(const Color(0xFF1E88E5));
        poly.strokeWidth = 10;
        poly.outlineColor = const Color(0xFFFFFFFF);
        poly.outlineWidth = 2;
        _routePolyline = poly;
      }

      _destPlacemark = _routeLayer!.addPlacemarkWithPoint(
        Point(latitude: dest.latitude, longitude: dest.longitude),
      );

      _fitMapToRoute(points, dest);
    } catch (e) {
      debugPrint('drawRouteOnMap: $e');
    }
  }

  void _fitMapToRoute(List<LatLng> points, LatLng dest) {
    final mapWindow = _mapWindow;
    if (mapWindow == null) return;
    final all = <LatLng>[...points, dest];
    if (_userLatLng != null) all.add(_userLatLng!);
    if (all.isEmpty) return;
    try {
      var minLat = all.first.latitude;
      var maxLat = all.first.latitude;
      var minLon = all.first.longitude;
      var maxLon = all.first.longitude;
      for (final p in all) {
        if (p.latitude < minLat) minLat = p.latitude;
        if (p.latitude > maxLat) maxLat = p.latitude;
        if (p.longitude < minLon) minLon = p.longitude;
        if (p.longitude > maxLon) maxLon = p.longitude;
      }
      final padLat = max(0.002, (maxLat - minLat) * 0.2);
      final padLon = max(0.002, (maxLon - minLon) * 0.2);
      final box = BoundingBox(
        Point(latitude: minLat - padLat, longitude: minLon - padLon),
        Point(latitude: maxLat + padLat, longitude: maxLon + padLon),
      );
      final cam = mapWindow.map.cameraPositionForGeometry(
        Geometry.fromBoundingBox(box),
      );
      mapWindow.map.move(cam);
    } catch (e) {
      debugPrint('fitMapToRoute: $e');
      if (points.isNotEmpty) _moveMapTo(points.first, zoom: 14);
    }
  }

  void _onRouteUpdated(List<LatLng> points, LatLng dest) {
    if (!mounted) return;
    if (points.isEmpty) {
      _clearRouteOnMap();
      setState(() {
        _routePoints = [];
        _destLatLng = null;
      });
      return;
    }
    setState(() {
      _routePoints = points;
      _destLatLng = dest;
    });
    _drawRouteOnMap(points, dest);
  }

  Future<void> _setupAIandVoice() async {
    // Инициализируем логгер производительности
    await PerfLogger.instance.init();

    debugPrint("🔧 Initializing AI detector...");
    try {
      await _aiDetector.initModel().timeout(
        const Duration(seconds: 15),
        onTimeout: () => debugPrint("⚠️ initModel timeout"),
      );
      debugPrint("✅ AI detector initialized");
    } catch (e) {
      debugPrint("⚠️ AI init error: $e");
    }

    try {
      await _tts.setLanguage("ru-RU");
      await _tts.setSpeechRate(0.5);
    } catch (e) {
      debugPrint("⚠️ TTS setup error: $e");
    }

    try {
      await _speechToText.initialize();
    } catch (e) {
      debugPrint("⚠️ STT init error: $e");
    }

    await _services.init();

    // UI-колбэк не затирает внутренний _onModeChanged сервисов.
    _services.onModeChangedExtra = _handleModeChanged;

    _services.navigation.onRouteReady = _onRouteUpdated;
    _services.navigation.onDebugLog = (message) {
      if (!mounted) return;
      setState(() => _navDebugLog = message);
    };
    _services.navigation.onAwaitingRouteChoice = (awaiting) {
      if (!mounted) return;
      setState(() => _awaitingRouteChoiceUi = awaiting);
      // Микрофон НЕ включаем здесь — только после озвучки (onReadyForRouteChoiceListen).
    };
    _services.navigation.onReadyForRouteChoiceListen = () {
      if (!mounted || !_awaitingRouteChoiceUi || _isListening) return;
      _startListening();
    };

    _startVideoWatchdog();

    await _services.speakWelcome();
  }

  void _startVideoWatchdog() {
    _videoWatchdog?.cancel();
    final startedAt = DateTime.now().millisecondsSinceEpoch;
    _videoWatchdog = Timer.periodic(const Duration(seconds: 3), (_) async {
      if (!mounted) return;
      final now = DateTime.now().millisecondsSinceEpoch;
      // Раньше watchdog молчал, пока не пришёл ни один кадр — тогда 0 FPS навсегда.
      final gap = _lastFrameMs == 0
          ? (now - startedAt)
          : (now - _lastFrameMs);
      if (_lastFrameMs == 0 && gap < 5000) return;
      if (gap > 4000) {
        // Сначала STREAM/PING (ESP учит DEST из source IP команды).
        await _espCamera.resumeVideoStream();
        await _espCamera.ping();
        final ip = await resolvePhoneIpv4();
        if (ip != null) {
          await _espCamera.updateVideoDestination(ip);
        }
      }
      if (gap > 5000) {
        if (!_connectionLostAnnounced) {
          _connectionLostAnnounced = true;
          _hasSpokenConnected = false;
          _services.vibration.danger();
          _services
              .speak(
                'Связь с камерой потеряна. Проверьте очки, Wi‑Fi и выключите VPN.',
                priority: 3,
              )
              .catchError((_) {});
        }
      }
    });
  }

  void _startUdpServer(int port) async {
    try {
      await _udpPipeline.start(
        port: port,
        rcvBufBytes: 32 * 1024 * 1024, // 32 MB SO_RCVBUF (ОС), latest-only доставка
      );
      debugPrint(
        "✅ UDP isolate на 0.0.0.0:$port (rcvbuf=32MB, latest-only mailbox)",
      );
      if (mounted) {
        setState(() => _debugInfo = "UDP OK :$port — 32MB + latest-only");
      }

      await _udpFrameSub?.cancel();
      _udpFrameSub = _udpPipeline.frames.listen((msg) {
        _bytesReceivedThisSecond += msg.bytes;
        _espCamera.updateAddress(msg.source);

        if (!_hasSpokenConnected) {
          _hasSpokenConnected = true;
          _connectionLostAnnounced = false;
          _services
              .speak("Очки успешно подключены.", priority: 0)
              .catchError((_) {});
          // STREAM/PING: ESP берёт DEST из source IP пакета (надёжнее guess).
          // DEST с resolvePhoneIpv4 оставляем как доп. подсказку — прошивка
          // больше не гасит fallback .1 при ошибке.
          _espCamera.resumeVideoStream();
          _espCamera.ping();
          resolvePhoneIpv4().then((ip) {
            if (ip != null) _espCamera.updateVideoDestination(ip);
          });
        }
        _lastFrameMs = DateTime.now().millisecondsSinceEpoch;

        _onVideoFrameComplete(msg.jpeg);
      });
    } catch (e) {
      debugPrint("❌ ОШИБКА UDP isolate: $e");
      if (mounted) setState(() => _debugInfo = "Ошибка UDP: $e");
      Future.delayed(const Duration(seconds: 1), () {
        if (mounted) _startUdpServer(port);
      });
    }
  }

  AppMode _lastKnownMode = AppMode.standard;

  void _handleModeChanged(AppMode mode) {
    final previous = _lastKnownMode;
    _lastKnownMode = mode;

    if (mode == AppMode.reading) {
      if (previous != AppMode.reading) {
        _modeBeforeReading = previous;
      }
      _espCamera.captureReadingSnapshot();
    } else if (previous == AppMode.reading) {
      _espCamera.resumeVideoStream();
      _modeBeforeReading = null;
    }

    if (mounted) setState(() {});

    if (mode == AppMode.navigation) {
      Future.delayed(const Duration(milliseconds: 300), () {
        if (!mounted || _lastKnownMode != AppMode.navigation) return;
        // Карта могла пересоздаться — восстановить линию маршрута.
        if (_routePoints.isNotEmpty && _destLatLng != null) {
          _drawRouteOnMap(_routePoints, _destLatLng!);
        } else if (_userLatLng != null) {
          _moveMapTo(_userLatLng!);
        }
      });
    }
  }

  void _onVideoFrameComplete(Uint8List fullJpeg) {
    _framesReceivedThisSecond++;

    final now = DateTime.now().millisecondsSinceEpoch;
    _latestFrameForCommands = fullJpeg;

    if (_currentMode == AppMode.reading) {
      _latestDisplayFrame = fullJpeg;
      _frameNotifier.value = fullJpeg;
      _lastUiUpdateTime = now;
      _readingSnapshotCompleter?.complete(fullJpeg);
      _readingSnapshotCompleter = null;
      return;
    }

    _latestAiFrame = fullJpeg;
    _aiFrameGen++;

    final showVideo = _currentMode != AppMode.navigation;
    if (showVideo && now - _lastUiUpdateTime >= _uiFrameIntervalMs) {
      _latestDisplayFrame = fullJpeg;
      _frameNotifier.value = fullJpeg;
      _lastUiUpdateTime = now;
      _uiFramesThisSecond++;
    }

    // AI не должен блокировать приём — только планируем
    _tryScheduleAi(now);
  }

  Future<Uint8List?> _captureReadingSnapshot() async {
    if (_espCamera.espAddress == null) return _latestFrameForCommands;

    final completer = Completer<Uint8List?>();
    _readingSnapshotCompleter = completer;

    final sent = await _espCamera.captureReadingSnapshot();
    if (!sent) {
      _readingSnapshotCompleter = null;
      return _latestFrameForCommands;
    }

    try {
      return await completer.future.timeout(
        const Duration(seconds: 4),
        onTimeout: () {
          debugPrint('📷 Reading snapshot timeout, using last frame');
          return _latestFrameForCommands;
        },
      );
    } finally {
      if (_readingSnapshotCompleter == completer) {
        _readingSnapshotCompleter = null;
      }
    }
  }

  /// Запуск AI только на новом кадре (не перегоняем тот же JPEG).
  void _tryScheduleAi(int now) {
    if (_isProcessingAI || _latestAiFrame == null) return;
    if (_aiFrameGen == _lastProcessedAiGen) return;
    if (_currentMode == AppMode.reading) return;
    // В режиме карты чуть реже, чтобы не душить MapKit (~6–8 AI FPS макс.)
    if (_currentMode == AppMode.navigation &&
        now - _lastAiProcessTime < 120) {
      return;
    }
    _runAI();
  }

  Future<void> _runAI() async {
    if (_isProcessingAI || _latestAiFrame == null) return;
    if (_aiFrameGen == _lastProcessedAiGen) return;
    if (!_aiDetector.isReady) return;
    _isProcessingAI = true;
    _lastAiProcessTime = DateTime.now().millisecondsSinceEpoch;
    // Берём самый свежий кадр на момент старта (latest-only).
    final frame = _latestAiFrame!;
    final gen = _aiFrameGen;
    _lastProcessedAiGen = gen;
    try {
      final List<DetectedObject> objects = await _aiDetector
          .processFrame(frame)
          .timeout(
            const Duration(seconds: 2),
            onTimeout: () {
              debugPrint('⚠️ AI inference timeout — пропускаем кадр');
              return <DetectedObject>[];
            },
          );
      _aiFramesThisSecond++;

      if (mounted) {
        final now = DateTime.now().millisecondsSinceEpoch;
        // Всегда обновляем (в т.ч. пустой список) — иначе на экране
        // залипает старый ложный бокс.
        if (objects.isEmpty ||
            now - _lastDetectionUiTime >= _detectionUiIntervalMs) {
          _detectionsNotifier.value = objects;
          _lastDetectionUiTime = now;
        }
      }

      // Знаки/светофор + HazardService (дистанция, ямы, лестницы).
      _services.onFrameAnalyzed(objects: objects, jpeg: frame);
    } catch (e) {
      debugPrint("❌ _runAI error: $e");
    } finally {
      _isProcessingAI = false;
      if (mounted && _aiFrameGen != _lastProcessedAiGen) {
        _tryScheduleAi(DateTime.now().millisecondsSinceEpoch);
      }
    }
  }

  void _stopListening({bool announce = false}) {
    _listenTimeout?.cancel();
    _listenTimeout = null;
    try {
      _speechToText.stop();
    } catch (_) {}
    if (mounted && _isListening) {
      setState(() => _isListening = false);
    } else {
      _isListening = false;
    }
    if (announce) {
      _services.speak('Слушание остановлено.', priority: 0).catchError((_) {});
    }
  }

  Future<void> _startListening() async {
    if (!mounted) return;
    try {
      final available = await _speechToText.initialize(
        onError: (e) {
          debugPrint('[STT] error: $e');
          if (mounted) setState(() => _isListening = false);
          _listenTimeout?.cancel();
        },
        onStatus: (status) {
          debugPrint('[STT] status: $status');
          if (!mounted) return;
          if (status == 'done' || status == 'notListening') {
            if (_isListening) setState(() => _isListening = false);
            _listenTimeout?.cancel();
          }
        },
      );
      if (!available || !mounted) {
        _services.speak('Микрофон недоступен.', priority: 0).catchError((_) {});
        return;
      }

      setState(() => _isListening = true);
      _listenTimeout?.cancel();
      _listenTimeout = Timer(const Duration(seconds: 12), () {
        if (!mounted || !_isListening) return;
        _stopListening();
        if (_awaitingRouteChoiceUi) {
          Future.delayed(const Duration(milliseconds: 400), () {
            if (mounted && _awaitingRouteChoiceUi && !_isListening) {
              _startListening();
            }
          });
        } else {
          _services
              .speak('Не расслышал. Повторите команду.', priority: 1)
              .catchError((_) {});
        }
      });

      await _speechToText.listen(
        onResult: (result) {
          final heard = result.recognizedWords.toLowerCase().trim();
          if (heard.isEmpty) return;

          // Цифру выбора ловим сразу (partial), чтобы не слушать до конца озвучки.
          if (_awaitingRouteChoiceUi &&
              !result.finalResult &&
              _parseEarlyChoice(heard) != null) {
            _listenTimeout?.cancel();
            setState(() => _isListening = false);
            try {
              _speechToText.stop();
            } catch (_) {}
            _processVoiceCommand(heard);
            return;
          }

          if (result.finalResult) {
            debugPrint('[STT] Услышано: "$heard"');
            _listenTimeout?.cancel();
            setState(() {
              _isListening = false;
              _navDebugLog = 'Услышано: "$heard"';
            });
            _processVoiceCommand(heard);
          }
        },
        listenFor: const Duration(seconds: 12),
        pauseFor: const Duration(seconds: 3),
        partialResults: true,
        cancelOnError: true,
        localeId: 'ru_RU',
      );
    } catch (e) {
      debugPrint('[STT] start error: $e');
      if (mounted) setState(() => _isListening = false);
      _services.speak('Микрофон недоступен.', priority: 0).catchError((_) {});
    }
  }

  int? _parseEarlyChoice(String cmd) {
    if (RegExp(r'\b(1|один|перв)\b').hasMatch(cmd)) return 1;
    if (RegExp(r'\b(2|два|втор)\b').hasMatch(cmd)) return 2;
    if (RegExp(r'\b(3|три|трет)\b').hasMatch(cmd)) return 3;
    return null;
  }

  Future<void> _listenCommand() async {
    if (_isListening) {
      _stopListening(announce: true);
      return;
    }
    _awaitingAddress = false;
    await _services.speakAndWait('Слушаю', priority: 0);
    if (mounted) await _startListening();
  }

  int _a11yTapCount = 0;
  Timer? _a11yTapTimer;

  /// Двойной тап — микрофон, тройной — смена режима, долгое — SOS.
  void _onAccessibilityTap() {
    _a11yTapCount++;
    _a11yTapTimer?.cancel();
    _a11yTapTimer = Timer(const Duration(milliseconds: 450), () {
      final n = _a11yTapCount;
      _a11yTapCount = 0;
      if (!mounted) return;
      if (n >= 3) {
        _services.modeSelector.cycleMode().then((_) {
          if (mounted) setState(() {});
        });
      } else if (n == 2) {
        _listenCommand();
      }
      // одиночный тап игнорируем — случайные касания
    });
  }

  void _onAccessibilityLongPress() {
    _a11yTapCount = 0;
    _a11yTapTimer?.cancel();
    _services.sos.trigger();
  }

  Future<void> _processVoiceCommand(String command) async {
    debugPrint('[STT] Команда: "$command"');
    if (_awaitingAddress) {
      setState(() => _navDebugLog = 'Адрес: "$command"');
    }

    final cmd = command.toLowerCase().trim();

    // Выбор варианта маршрута (один/два/три) — до прочих команд.
    if (_services.navigation.awaitingRouteChoice || _awaitingRouteChoiceUi) {
      final handled =
          await _services.navigation.handleRouteChoiceCommand(command);
      if (handled) {
        if (mounted) setState(() {});
        return;
      }
    }

    // Отмена: маршрут, диалог адреса, прослушивание, выбор, поиск
    if (cmd == 'отмена' ||
        cmd == 'отменить' ||
        cmd == 'стоп' ||
        cmd.contains('отмени') ||
        cmd.contains('отмена') ||
        cmd.contains('остановить навигацию') ||
        cmd.contains('стоп маршрут')) {
      _awaitingAddress = false;
      _stopListening();
      if (_services.find.isActive) {
        _services.find.stop();
      }
      // Всегда гасим поиск/маршрут — иначе «отмена» во время поиска не работает.
      _cancelRoute();
      return;
    }

    // Если мы ждали адрес на втором этапе диалога
    if (_awaitingAddress) {
      _awaitingAddress = false;
      if (_services.modeSelector.currentMode != AppMode.navigation) {
        _services.modeSelector.processCommand('режим навигация');
      }
      await _services.navigation.handleVoiceDestination(command);
      if (mounted) setState(() {});
      return;
    }

    // Перехватываем команду на запуск двухэтапного набора адреса
    if (cmd == "построй маршрут" ||
        cmd == "проложи маршрут" ||
        cmd == "куда идти" ||
        cmd == "поехали") {
      setState(() => _awaitingAddress = true);
      await _services.speakAndWait("Назовите адрес или место", priority: 1);
      if (mounted) await _startListening();
      return;
    }

    final handled = await _services.processVoiceCommand(
      command,
      currentFrame: _latestFrameForCommands,
      captureFreshFrame: _currentMode == AppMode.reading
          ? _captureReadingSnapshot
          : null,
    );
    if (handled) {
      if (mounted) setState(() {});
      return;
    }

    if (command.contains("раздачу") ||
        command.contains("точка доступа") ||
        command.contains("интернет")) {
      _services.speak("Скажите: Окей Гугл, включи точку доступа.", priority: 0);
    } else {
      _services.speak(
        "Команда не распознана. Скажите: режимы — для списка доступных режимов.",
        priority: 0,
      );
    }
  }

  void _openSettings() async {
    if (_settingsOpen) return;
    _settingsOpen = true;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (_) => _SettingsSheet(
        savedPlaces: Map.from(widget.savedPlaces),
        tileProvider: _tileProvider,
        readingService: _services.reading,
        services: _services,
        onSaved: (places) {
          _services.navigation.updateSavedPlaces(places);
        },
      ),
    );
    _settingsOpen = false;
  }

  bool _onHardwareKey(KeyEvent event) {
    final isUp = event.logicalKey == LogicalKeyboardKey.audioVolumeUp;
    final isDown = event.logicalKey == LogicalKeyboardKey.audioVolumeDown;
    if (!isUp && !isDown) return false;

    final now = DateTime.now();

    if (event is KeyUpEvent) {
      if (isUp) _volUpDownAt = null;
      if (isDown) _volDownDownAt = null;
      if (_volUpDownAt == null && _volDownDownAt == null) {
        _volChordHandled = false;
      }
      return true;
    }

    if (event is! KeyDownEvent) return false;

    if (isUp) _volUpDownAt = now;
    if (isDown) _volDownDownAt = now;

    final otherHeld = isUp
        ? HardwareKeyboard.instance
            .isLogicalKeyPressed(LogicalKeyboardKey.audioVolumeDown)
        : HardwareKeyboard.instance
            .isLogicalKeyPressed(LogicalKeyboardKey.audioVolumeUp);

    final partnerRecent = isUp
        ? (_volDownDownAt != null &&
            now.difference(_volDownDownAt!).inMilliseconds < 600)
        : (_volUpDownAt != null &&
            now.difference(_volUpDownAt!).inMilliseconds < 600);

    // Одновременное громче+тише → микрофон (нейросеть / голосовые команды).
    if (!_volChordHandled && (otherHeld || partnerRecent)) {
      _volChordHandled = true;
      _volAloneTimer?.cancel();
      _listenCommand();
      return true;
    }

    // Одиночное нажатие — с задержкой, чтобы успел прийти второй ключ аккорда.
    _volAloneTimer?.cancel();
    final aloneUp = isUp;
    _volAloneTimer = Timer(const Duration(milliseconds: 280), () {
      if (_volChordHandled) return;
      if (aloneUp) {
        _listenCommand();
      } else {
        _services.speech.repeatLast();
      }
    });
    return true;
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onHardwareKey);
    WidgetsBinding.instance.removeObserver(this);
    _fpsTimer?.cancel();
    _listenTimeout?.cancel();
    _videoWatchdog?.cancel();
    _volAloneTimer?.cancel();
    _udpFrameSub?.cancel();
    _udpPipeline.stop();
    _aiDetector.dispose();
    _services.dispose();
    _tts.stop();
    _speechToText.stop();
    _a11yTapTimer?.cancel();
    _positionSub?.cancel();
    _frameNotifier.dispose();
    _detectionsNotifier.dispose();
    _fpsNotifier.dispose();
    _uiFpsNotifier.dispose();
    _aiFpsNotifier.dispose();
    _kbpsNotifier.dispose();
    PerfLogger.instance.dispose();
    mapkit.onStop();
    super.dispose();
  }

  Color _modeColor(AppMode mode) {
    switch (mode) {
      case AppMode.navigation:
        return AppColors.accent;
      case AppMode.home:
        return const Color(0xFF34D399);
      case AppMode.reading:
        return const Color(0xFFFB923C);
      case AppMode.radar:
        return AppColors.success;
      case AppMode.find:
        return const Color(0xFF38BDF8);
      case AppMode.identify:
        return const Color(0xFFE879F9);
      case AppMode.scene:
        return const Color(0xFFF472B6);
      case AppMode.standard:
        return AppColors.textSecondary;
    }
  }

  IconData _modeIcon(AppMode mode) {
    switch (mode) {
      case AppMode.navigation:
        return Icons.map;
      case AppMode.home:
        return Icons.home_rounded;
      case AppMode.reading:
        return Icons.menu_book_rounded;
      case AppMode.radar:
        return Icons.spatial_audio;
      case AppMode.find:
        return Icons.search_rounded;
      case AppMode.identify:
        return Icons.palette_rounded;
      case AppMode.scene:
        return Icons.visibility_rounded;
      case AppMode.standard:
        return Icons.videocam_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final topPad = mq.padding.top + 8;
    final bottomPad = mq.padding.bottom + 8;

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: _currentMode == AppMode.navigation
                ? _buildNavigationBackground()
                : Stack(
                    fit: StackFit.expand,
                    children: [
                      RepaintBoundary(
                        child: ValueListenableBuilder<Uint8List?>(
                          valueListenable: _frameNotifier,
                          builder: (context, frame, _) {
                            if (frame == null) {
                              return _buildWaitingForVideo();
                            }
                            if (_currentMode == AppMode.reading) {
                              return ReadingPhotoPreview(jpegBytes: frame);
                            }
                            return CameraVideoLayer(jpegBytes: frame);
                          },
                        ),
                      ),
                      RepaintBoundary(
                        child: ValueListenableBuilder<List<DetectedObject>>(
                          valueListenable: _detectionsNotifier,
                          builder: (context, detections, _) {
                            if (_currentMode == AppMode.reading) {
                              return const SizedBox.shrink();
                            }
                            return DetectionOverlay(detections: detections);
                          },
                        ),
                      ),
                    ],
                  ),
          ),

          // Карту не снимаем с дерева при смене режима — иначе линия маршрута пропадает.
          Visibility(
            visible: _currentMode == AppMode.navigation,
            maintainState: true,
            maintainAnimation: true,
            child: _buildMapOverlay(topPad, bottomPad),
          ),

          // Баннер маршрута виден в любом режиме, пока ведение активно.
          if (_services.navigation.isNavigating &&
              _currentMode != AppMode.navigation)
            Positioned(
              top: topPad + 52,
              left: 12,
              right: 12,
              child: Material(
                color: Colors.transparent,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: hudPanelDecoration(accentColor: AppColors.accent),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.navigation_rounded,
                        color: AppColors.accent,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _services.navigation.destinationName.isNotEmpty
                              ? 'Маршрут: ${_services.navigation.destinationName}'
                              : 'Маршрут активен',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      TextButton(
                        onPressed: () {
                          _services.modeSelector
                              .processCommand('режим навигация');
                        },
                        child: const Text('Карта'),
                      ),
                      IconButton(
                        tooltip: 'Отменить маршрут',
                        onPressed: _cancelRoute,
                        icon: const Icon(
                          Icons.close_rounded,
                          color: AppColors.error,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // Доступность: двойной тап = микрофон, тройной = смена режима.
          // Поверх всего экрана, включая карту.
          Positioned.fill(
            child: Semantics(
              label: _isListening
                  ? 'Идёт прослушивание. Двойной тап — остановить. Тройной тап — сменить режим.'
                  : 'Двойной тап — голосовая команда. Тройной тап — сменить режим.',
              button: true,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: _onAccessibilityTap,
                onLongPress: _onAccessibilityLongPress,
                child: Container(
                color: _isListening
                    ? AppColors.accent.withValues(alpha: 0.15)
                    : Colors.transparent,
                child: _isListening
                    ? Center(
                        child: Container(
                          width: 120,
                          height: 120,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: AppColors.gradientPrimary,
                            boxShadow: [
                              BoxShadow(
                                color: AppColors.primary.withValues(alpha: 0.5),
                                blurRadius: 30,
                                spreadRadius: 4,
                              ),
                            ],
                          ),
                          child: const Icon(
                            Icons.mic_rounded,
                            size: 56,
                            color: Colors.white,
                          ),
                        ),
                      )
                    : null,
              ),
            ),
            ),
          ),

          Positioned(
            top: topPad,
            right: 16,
            child: ValueListenableBuilder<int>(
              valueListenable: _fpsNotifier,
              builder: (context, netFps, _) {
                return ValueListenableBuilder<int>(
                  valueListenable: _uiFpsNotifier,
                  builder: (context, uiFps, __) {
                    return ValueListenableBuilder<int>(
                      valueListenable: _aiFpsNotifier,
                      builder: (context, aiFps, ___) {
                        return ValueListenableBuilder<int>(
                          valueListenable: _kbpsNotifier,
                          builder: (context, kbps, ____) {
                            final netOk = netFps > 10;
                            final uiOk = uiFps > 8;
                            final aiOk = aiFps >= 8;
                            return Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              decoration: hudPanelDecoration(),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Container(
                                        width: 8,
                                        height: 8,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: netOk
                                              ? AppColors.success
                                              : AppColors.error,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        "NET $netFps",
                                        style: TextStyle(
                                          color: netOk
                                              ? AppColors.success
                                              : AppColors.error,
                                          fontSize: 13,
                                          fontWeight: FontWeight.w700,
                                          fontFeatures: const [
                                            FontFeature.tabularFigures(),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Container(
                                        width: 8,
                                        height: 8,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: aiOk
                                              ? AppColors.success
                                              : AppColors.error,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        "AI $aiFps",
                                        style: TextStyle(
                                          color: aiOk
                                              ? AppColors.success
                                              : AppColors.error,
                                          fontSize: 13,
                                          fontWeight: FontWeight.w700,
                                          fontFeatures: const [
                                            FontFeature.tabularFigures(),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                  if (_currentMode != AppMode.navigation) ...[
                                    const SizedBox(height: 4),
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Container(
                                          width: 8,
                                          height: 8,
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            color: uiOk
                                                ? AppColors.success
                                                : AppColors.warning,
                                          ),
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          "UI $uiFps",
                                          style: TextStyle(
                                            color: uiOk
                                                ? AppColors.success
                                                : AppColors.warning,
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600,
                                            fontFeatures: const [
                                              FontFeature.tabularFigures(),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                  const SizedBox(height: 4),
                                  Text(
                                    "$kbps KB/s",
                                    style: const TextStyle(
                                      color: AppColors.textSecondary,
                                      fontSize: 12,
                                      fontFeatures: [
                                        FontFeature.tabularFigures(),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        );
                      },
                    );
                  },
                );
              },
            ),
          ),

          Positioned(
            top: topPad,
            left: 16,
            child: Container(
              decoration: hudPanelDecoration(),
              child: IconButton(
                icon: const Icon(Icons.settings_rounded, color: Colors.white),
                onPressed: _openSettings,
                tooltip: "Настройки",
              ),
            ),
          ),

          Positioned(
            bottom: bottomPad + 46,
            left: 16,
            right: 16,
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: hudPanelDecoration(accentColor: AppColors.glassBorder),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _buildModeButton(AppMode.standard, 'Улица', Icons.videocam_rounded),
                    _buildModeButton(AppMode.home, 'Дом', Icons.home_rounded),
                    _buildModeButton(AppMode.navigation, 'Карта', Icons.map_rounded),
                    _buildModeButton(AppMode.reading, 'Чтение', Icons.menu_book_rounded),
                    _buildModeButton(AppMode.find, 'Поиск', Icons.search_rounded),
                  ],
                ),
              ),
            ),
          ),

          Positioned(
            bottom: bottomPad + 4,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      _modeColor(_currentMode).withValues(alpha: 0.2),
                      _modeColor(_currentMode).withValues(alpha: 0.05),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: _modeColor(_currentMode).withValues(alpha: 0.6),
                    width: 1,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: _modeColor(_currentMode).withValues(alpha: 0.2),
                      blurRadius: 12,
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _modeIcon(_currentMode),
                      color: _modeColor(_currentMode),
                      size: 16,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      _currentMode.label.toUpperCase(),
                      style: TextStyle(
                        color: _modeColor(_currentMode),
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.5,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWaitingForVideo() {
    if (_currentMode == AppMode.reading) {
      return Container(
        decoration: const BoxDecoration(
          gradient: AppColors.gradientBackground,
        ),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.menu_book_rounded,
                  size: 72,
                  color: _modeColor(AppMode.reading),
                ),
                const SizedBox(height: 20),
                const Text(
                  'Режим чтения',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Делается HD-снимок для чтения.\nНаведите камеру на ценник или этикетку,\n'
                  'затем нажмите экран и скажите «сканируй».',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 14,
                    height: 1.4,
                  ),
                ),
                if (_services.navigation.isNavigating) ...[
                  const SizedBox(height: 20),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.accent.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: AppColors.accent.withValues(alpha: 0.4),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.navigation_rounded,
                          color: AppColors.accent,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            'Маршрут активен: ${_services.navigation.destinationName}',
                            style: const TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      decoration: const BoxDecoration(
        gradient: AppColors.gradientBackground,
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: AppColors.gradientPrimary,
                boxShadow: [
                  BoxShadow(
                    color: AppColors.primary.withValues(alpha: 0.4),
                    blurRadius: 24,
                  ),
                ],
              ),
              child: const Padding(
                padding: EdgeInsets.all(18),
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              "Ожидание видео с очков...",
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                decoration: hudPanelDecoration(
                  accentColor: AppColors.error,
                ),
                child: Text(
                  _debugInfo,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNavigationBackground() {
    return Container(
      decoration: const BoxDecoration(
        gradient: AppColors.gradientBackground,
      ),
      child: Center(
        child: ValueListenableBuilder<List<DetectedObject>>(
          valueListenable: _detectionsNotifier,
          builder: (context, detections, _) {
            return Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.visibility_rounded,
                  size: 48,
                  color: AppColors.accent.withValues(alpha: 0.7),
                ),
                const SizedBox(height: 16),
                const Text(
                  'Режим навигации',
                  style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  detections.isEmpty
                      ? 'Нейросеть анализирует окружение...'
                      : 'Обнаружено объектов: ${detections.length}',
                  style: const TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 14,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildMapOverlay(double topPad, double bottomPad) {
    final center = _userLatLng ?? const LatLng(55.751244, 37.618423);

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      bottom: bottomPad + 96,
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(16)),
        child: Stack(
          children: [
            YandexMap(
              onMapCreated: (mapWindow) {
                _mapWindow = mapWindow;
                _routeLayer = null;
                _routePolyline = null;
                _destPlacemark = null;
                mapkit.onStart();
                if (_routePoints.isNotEmpty && _destLatLng != null) {
                  _drawRouteOnMap(_routePoints, _destLatLng!);
                } else {
                  _moveMapTo(center);
                }
              },
            ),
            Positioned(
              top: topPad + 52,
              right: 16,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    decoration: hudPanelDecoration(accentColor: AppColors.accent),
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: () {
                          if (_userLatLng != null) {
                            _moveMapTo(_userLatLng!);
                          }
                        },
                        borderRadius: BorderRadius.circular(14),
                        child: const Padding(
                          padding: EdgeInsets.all(10),
                          child: Icon(
                            Icons.my_location_rounded,
                            color: AppColors.accent,
                            size: 22,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    decoration: hudPanelDecoration(
                      accentColor: _isListening
                          ? AppColors.error
                          : AppColors.accent,
                    ),
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: _listenCommand,
                        borderRadius: BorderRadius.circular(14),
                        child: Padding(
                          padding: const EdgeInsets.all(10),
                          child: Icon(
                            _isListening
                                ? Icons.mic_rounded
                                : Icons.mic_none_rounded,
                            color: _isListening
                                ? AppColors.error
                                : AppColors.accent,
                            size: 22,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (_services.navigation.destinationName.isNotEmpty ||
                _routePoints.isNotEmpty ||
                _services.navigation.isNavigating ||
                _awaitingRouteChoiceUi)
              Positioned(
                bottom: 8,
                left: 12,
                right: 12,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  decoration: hudPanelDecoration(accentColor: AppColors.accent),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.navigation_rounded,
                        color: AppColors.accent,
                        size: 16,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _services.navigation.destinationName.isNotEmpty
                              ? _services.navigation.destinationName
                              : 'Маршрут активен',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      GestureDetector(
                        onTap: _cancelRoute,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.error.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: AppColors.error.withValues(alpha: 0.6),
                            ),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.close_rounded,
                                color: AppColors.error,
                                size: 14,
                              ),
                              SizedBox(width: 4),
                              Text(
                                'Отменить',
                                style: TextStyle(
                                  color: AppColors.error,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            if (_navDebugLog.isNotEmpty)
              Positioned(
                top: topPad + 8,
                left: 12,
                right: 12,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.75),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: AppColors.accent.withValues(alpha: 0.5),
                    ),
                  ),
                  child: Text(
                    _navDebugLog,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 11,
                      height: 1.35,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildModeButton(AppMode mode, String label, IconData icon) {
    final isActive = _currentMode == mode;
    final color = _modeColor(mode);
    return GestureDetector(
      onTap: () {
        _services.modeSelector.processCommand(mode.label);
        if (mounted) setState(() {});
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 72,
        margin: const EdgeInsets.symmetric(horizontal: 2),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          gradient: isActive
              ? LinearGradient(
                  colors: [
                    color.withValues(alpha: 0.9),
                    color.withValues(alpha: 0.6),
                  ],
                )
              : null,
          color: isActive ? null : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              color: isActive ? Colors.white : AppColors.textMuted,
              size: 20,
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: isActive ? Colors.white : AppColors.textMuted,
                fontSize: 11,
                fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _UserMarker extends StatelessWidget {
  const _UserMarker();
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: AppColors.gradientPrimary,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: [
          BoxShadow(
            color: AppColors.accent.withValues(alpha: 0.5),
            blurRadius: 10,
          ),
        ],
      ),
    );
  }
}

class _SettingsSheet extends StatefulWidget {
  final Map<String, String> savedPlaces;
  final IndexedCachingTileProvider tileProvider;
  final ReadingService readingService;
  final SmartGlassesServices services;
  final void Function(Map<String, String>) onSaved;

  const _SettingsSheet({
    required this.savedPlaces,
    required this.tileProvider,
    required this.readingService,
    required this.services,
    required this.onSaved,
  });

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  late Map<String, String> _places;
  late Set<String> _selectedAllergens;
  final TextEditingController _nameCtrl = TextEditingController();
  final TextEditingController _addrCtrl = TextEditingController();
  final TextEditingController _customAllergenCtrl = TextEditingController();
  final TextEditingController _regionCtrl = TextEditingController();
  final TextEditingController _sosPhoneCtrl = TextEditingController();
  final TextEditingController _sosNameCtrl = TextEditingController();
  final TextEditingController _apiKeyCtrl = TextEditingController();
  final TextEditingController _folderCtrl = TextEditingController();
  final TextEditingController _gigaCtrl = TextEditingController();

  bool _offlineOnly = false;
  bool _soundscape = true;
  double _speechRate = 0.5;
  String _calibStatus = '';
  bool _isDownloading = false;
  double _downloadProgress = 0.0;
  String _downloadStatus = '';

  List<OfflineMapRegion> _offlineRegions = [];
  bool _loadingRegions = true;
  Map<String, int> _regionSizes = {};

  @override
  void initState() {
    super.initState();
    _places = Map.from(widget.savedPlaces);
    _selectedAllergens = widget.readingService.userAllergens.toSet();
    final c = widget.services.cloud;
    _offlineOnly = c.offlineOnly;
    _soundscape = c.soundscapeEnabled;
    _speechRate = c.speechRate;
    _sosPhoneCtrl.text = c.sosPhone;
    _sosNameCtrl.text = c.sosContactName;
    _apiKeyCtrl.text = c.apiKey;
    _folderCtrl.text = c.folderId;
    _gigaCtrl.text = c.gigachatAuthKey;
    _loadOfflineRegions();
  }

  Future<void> _loadOfflineRegions() async {
    setState(() => _loadingRegions = true);
    try {
      final regions = await listOfflineRegions();
      final sizes = <String, int>{};
      for (final r in regions) {
        sizes[r.id] = await getRegionSizeBytes(r.id);
      }
      if (mounted) {
        setState(() {
          _offlineRegions = regions;
          _regionSizes = sizes;
          _loadingRegions = false;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loadingRegions = false);
    }
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Future<void> _confirmDeleteRegion(OfflineMapRegion region) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Удалить карту?'),
        content: Text(
          'Удалить офлайн-карту «${region.name}»?\n'
          'Освободится ~${_formatSize(_regionSizes[region.id] ?? region.estimateSizeBytes())}.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Удалить',
              style: TextStyle(color: AppColors.error),
            ),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    await deleteOfflineRegion(region.id);
    await widget.tileProvider.refreshIndex();
    await _loadOfflineRegions();
  }

  void _viewRegion(OfflineMapRegion region) {
    Navigator.pop(context);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => OfflineMapPreviewScreen(region: region),
      ),
    );
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _addrCtrl.dispose();
    _regionCtrl.dispose();
    _customAllergenCtrl.dispose();
    _sosPhoneCtrl.dispose();
    _sosNameCtrl.dispose();
    _apiKeyCtrl.dispose();
    _folderCtrl.dispose();
    _gigaCtrl.dispose();
    super.dispose();
  }

  Future<void> _saveAllergens() async {
    await widget.readingService.saveProfile(_selectedAllergens.toList());
  }

  void _toggleAllergen(String allergen, bool selected) {
    setState(() {
      if (selected) {
        _selectedAllergens.add(allergen);
      } else {
        _selectedAllergens.remove(allergen);
      }
    });
    _saveAllergens();
  }

  void _addCustomAllergen() {
    final value = _customAllergenCtrl.text.trim().toLowerCase();
    if (value.isEmpty) return;
    setState(() => _selectedAllergens.add(value));
    _customAllergenCtrl.clear();
    _saveAllergens();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('saved_places', jsonEncode(_places));
    widget.onSaved(_places);
  }

  void _add() {
    final name = _nameCtrl.text.trim().toLowerCase();
    final addr = _addrCtrl.text.trim();
    if (name.isEmpty || addr.isEmpty) return;
    setState(() => _places[name] = addr);
    _save();
    _nameCtrl.clear();
    _addrCtrl.clear();
  }

  Future<void> _startMapDownload() async {
    final region = _regionCtrl.text.trim();
    if (region.isEmpty) return;

    setState(() {
      _isDownloading = true;
      _downloadProgress = 0.0;
      _downloadStatus = 'Поиск региона...';
    });

    try {
      final (lat, lon, displayName) = await geocodeRegion(region);

      if (mounted) {
        setState(() {
          _downloadStatus =
              'Найдено: ${displayName.split(',').first}. Подготовка тайлов...';
        });
      }

      await downloadMapRegionNamed(lat, lon, region, (progress, status) {
        if (mounted) {
          setState(() {
            _downloadProgress = progress;
            _downloadStatus = status;
          });
        }
      });

      await widget.tileProvider.refreshIndex();
      await _loadOfflineRegions();
      _regionCtrl.clear();
    } catch (e) {
      if (mounted) {
        setState(() {
          _downloadStatus =
              'Ошибка: ${e.toString().replaceAll('Exception: ', '')}';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isDownloading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      expand: false,
      builder: (_, ctrl) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: ListView(
            controller: ctrl,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.textMuted,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                "Настройки",
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),

              const SizedBox(height: 24),
              GlassCard(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SectionHeader(
                      title: "Доступность и облако РФ",
                      subtitle:
                          "Только офлайн, SOS-контакт, Яндекс Cloud, скорость речи",
                      icon: Icons.accessibility_new_rounded,
                    ),
                    const SizedBox(height: 12),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Только офлайн',
                          style: TextStyle(color: AppColors.textPrimary)),
                      subtitle: const Text(
                        'Без YandexGPT и Vision. Улица и OCR на устройстве.',
                        style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                      ),
                      value: _offlineOnly,
                      onChanged: (v) async {
                        setState(() => _offlineOnly = v);
                        await widget.services.cloud.setOfflineOnly(v);
                      },
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Soundscape POI',
                          style: TextStyle(color: AppColors.textPrimary)),
                      subtitle: const Text(
                        'Редкие якоря «магазин слева» по компасу',
                        style: TextStyle(color: AppColors.textMuted, fontSize: 12),
                      ),
                      value: _soundscape,
                      onChanged: (v) async {
                        setState(() => _soundscape = v);
                        widget.services.cloud.soundscapeEnabled = v;
                        widget.services.soundscape.enabled = v;
                        await widget.services.cloud.save();
                      },
                    ),
                    Text(
                      'Скорость речи: ${_speechRate.toStringAsFixed(2)}',
                      style: const TextStyle(color: AppColors.textSecondary),
                    ),
                    Slider(
                      value: _speechRate,
                      min: 0.25,
                      max: 0.85,
                      onChanged: (v) => setState(() => _speechRate = v),
                      onChangeEnd: (v) =>
                          widget.services.applySpeechRate(v),
                    ),
                    TextField(
                      controller: _sosNameCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Имя контакта SOS',
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _sosPhoneCtrl,
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(
                        labelText: 'Телефон SOS (SMS)',
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _folderCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Yandex Folder ID',
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _apiKeyCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Yandex Cloud API Key',
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _gigaCtrl,
                      decoration: const InputDecoration(
                        labelText: 'GigaChat Auth Key (опционально)',
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: () async {
                          final c = widget.services.cloud;
                          c.apiKey = _apiKeyCtrl.text.trim();
                          c.folderId = _folderCtrl.text.trim();
                          c.gigachatAuthKey = _gigaCtrl.text.trim();
                          await c.setSosContact(
                            phone: _sosPhoneCtrl.text,
                            name: _sosNameCtrl.text,
                          );
                          await c.save();
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Сохранено')),
                            );
                          }
                        },
                        child: const Text('Сохранить облако и SOS'),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 24),
              GlassCard(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SectionHeader(
                      title: 'Калибровка камеры (глубина)',
                      subtitle:
                          'Наведите центр кадра на объект на 1, 3 или 5 м',
                      icon: Icons.straighten_rounded,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      widget.services.depth.modelLoaded
                          ? 'Depth TFLite: загружена'
                          : 'Depth: эвристика (положите depth_anything.tflite в assets/models)',
                      style: const TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 12,
                      ),
                    ),
                    Text(
                      'Точек калибровки: ${widget.services.depth.sampleCount}',
                      style: const TextStyle(color: AppColors.textSecondary),
                    ),
                    if (_calibStatus.isNotEmpty)
                      Text(
                        _calibStatus,
                        style: const TextStyle(color: AppColors.accent),
                      ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final m in [1.0, 3.0, 5.0])
                          OutlinedButton(
                            onPressed: () async {
                              final frame =
                                  widget.services.frames.latestJpeg;
                              if (frame == null) {
                                setState(
                                  () => _calibStatus = 'Нет кадра с очков',
                                );
                                return;
                              }
                              final msg = await widget.services.depth
                                  .calibrateAt(m, frame);
                              setState(() => _calibStatus = msg);
                            },
                            child: Text('${m.round()} м'),
                          ),
                      ],
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 24),
              GlassCard(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SectionHeader(
                      title: "Офлайн-карты",
                      subtitle:
                          "Скачайте карту города для работы без интернета",
                      icon: Icons.download_rounded,
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _regionCtrl,
                            decoration: const InputDecoration(
                              labelText: "Город (напр: Екатеринбург)",
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          decoration: BoxDecoration(
                            gradient: _isDownloading
                                ? null
                                : AppColors.gradientPrimary,
                            color: _isDownloading
                                ? AppColors.surfaceLight
                                : null,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Material(
                            color: Colors.transparent,
                            child: InkWell(
                              onTap: _isDownloading ? null : _startMapDownload,
                              borderRadius: BorderRadius.circular(14),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 14,
                                ),
                                child: _isDownloading
                                    ? const SizedBox(
                                        width: 18,
                                        height: 18,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: AppColors.accent,
                                        ),
                                      )
                                    : const Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            Icons.download_rounded,
                                            size: 18,
                                            color: Colors.white,
                                          ),
                                          SizedBox(width: 6),
                                          Text(
                                            "Скачать",
                                            style: TextStyle(
                                              color: Colors.white,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ],
                                      ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (_downloadStatus.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(
                        _downloadStatus,
                        style: const TextStyle(
                          color: AppColors.warning,
                          fontSize: 13,
                        ),
                      ),
                      if (_isDownloading) ...[
                        const SizedBox(height: 8),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: _downloadProgress,
                            backgroundColor: AppColors.surfaceLight,
                            valueColor: const AlwaysStoppedAnimation<Color>(
                              AppColors.accent,
                            ),
                            minHeight: 6,
                          ),
                        ),
                      ],
                    ],
                    const SizedBox(height: 16),
                    if (_loadingRegions)
                      const Center(
                        child: Padding(
                          padding: EdgeInsets.all(12),
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppColors.accent,
                          ),
                        ),
                      )
                    else if (_offlineRegions.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 4),
                        child: Text(
                          'Скачанных карт пока нет',
                          style: TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 13,
                          ),
                        ),
                      )
                    else ...[
                      const Divider(height: 24),
                      const Text(
                        'Скачанные карты',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 8),
                      ..._offlineRegions.map((r) {
                        final size = _regionSizes[r.id] ?? r.estimateSizeBytes();
                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.surfaceLight,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: AppColors.glassBorder),
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.map_rounded,
                                color: AppColors.accent,
                                size: 22,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      r.name,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.w600,
                                        color: AppColors.textPrimary,
                                        fontSize: 14,
                                      ),
                                    ),
                                    Text(
                                      '${r.tileCount} плиток · ${_formatSize(size)}',
                                      style: const TextStyle(
                                        color: AppColors.textMuted,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                icon: const Icon(
                                  Icons.visibility_rounded,
                                  color: AppColors.accent,
                                  size: 20,
                                ),
                                tooltip: 'Просмотр',
                                onPressed: () => _viewRegion(r),
                              ),
                              IconButton(
                                icon: const Icon(
                                  Icons.delete_outline_rounded,
                                  color: AppColors.error,
                                  size: 20,
                                ),
                                tooltip: 'Удалить',
                                onPressed: () => _confirmDeleteRegion(r),
                              ),
                            ],
                          ),
                        );
                      }),
                    ],
                  ],
                ),
              ),

              const SizedBox(height: 16),
              GlassCard(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SectionHeader(
                      title: "Мои аллергены",
                      subtitle:
                          "Используются в режиме чтения при анализе состава",
                      icon: Icons.no_food_rounded,
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: widget.readingService.availableAllergens.map((
                        allergen,
                      ) {
                        final selected = _selectedAllergens.contains(allergen);
                        return FilterChip(
                          label: Text(allergen),
                          selected: selected,
                          onSelected: (v) => _toggleAllergen(allergen, v),
                          selectedColor: AppColors.warning.withValues(
                            alpha: 0.25,
                          ),
                          checkmarkColor: AppColors.warning,
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _customAllergenCtrl,
                            decoration: const InputDecoration(
                              labelText: "Свой аллерген",
                              isDense: true,
                            ),
                            onSubmitted: (_) => _addCustomAllergen(),
                          ),
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          onPressed: _addCustomAllergen,
                          icon: const Icon(Icons.add_circle_rounded),
                          color: AppColors.accent,
                        ),
                      ],
                    ),
                    if (_selectedAllergens.isEmpty)
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text(
                          'Аллергены не выбраны — проверка состава будет пропущена.',
                          style: TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 12,
                          ),
                        ),
                      )
                    else
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: _selectedAllergens.map((a) {
                            return Chip(
                              label: Text(a),
                              deleteIcon: const Icon(Icons.close, size: 16),
                              onDeleted: () => _toggleAllergen(a, false),
                            );
                          }).toList(),
                        ),
                      ),
                  ],
                ),
              ),

              const SizedBox(height: 16),
              GlassCard(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SectionHeader(
                      title: "Мои места",
                      subtitle: 'Скажите «иду домой», «иду в аптеку» и т.д.',
                      icon: Icons.place_rounded,
                    ),
                    const SizedBox(height: 16),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          flex: 2,
                          child: TextField(
                            controller: _nameCtrl,
                            decoration: const InputDecoration(
                              labelText: "«домой», «работа»...",
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          flex: 3,
                          child: TextField(
                            controller: _addrCtrl,
                            decoration: const InputDecoration(
                              labelText: "Адрес",
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          decoration: BoxDecoration(
                            gradient: AppColors.gradientPrimary,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Material(
                            color: Colors.transparent,
                            child: InkWell(
                              onTap: _add,
                              borderRadius: BorderRadius.circular(14),
                              child: const SizedBox(
                                width: 48,
                                height: 48,
                                child: Icon(
                                  Icons.add_rounded,
                                  color: Colors.white,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (_places.isEmpty)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          "Мест нет.",
                          style: TextStyle(color: AppColors.textMuted),
                        ),
                      )
                    else
                      ..._places.entries.map(
                        (e) => PlaceChip(
                          name: e.key,
                          address: e.value,
                          onDelete: () {
                            setState(() => _places.remove(e.key));
                            _save();
                          },
                        ),
                      ),
                  ],
                ),
              ),

              const SizedBox(height: 16),
              GlassCard(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: ListTile(
                  leading: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      gradient: AppColors.gradientPrimary,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.bluetooth_connected_rounded,
                      color: Colors.white,
                      size: 20,
                    ),
                  ),
                  title: const Text(
                    "Wi-Fi / Bluetooth",
                    style: TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: const Text(
                    "Переподключить очки",
                    style: TextStyle(fontSize: 12),
                  ),
                  trailing: const Icon(
                    Icons.chevron_right_rounded,
                    color: AppColors.textMuted,
                  ),
                  onTap: () {
                    Navigator.pop(context);
                    Navigator.of(context).pushReplacement(
                      MaterialPageRoute(builder: (_) => const SetupScreen()),
                    );
                  },
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}
