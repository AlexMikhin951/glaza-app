// lib/fpv_screen.dart
import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ai_detector.dart';
import 'camera_preview_widget.dart';
import 'camera_command.dart';
import 'smart_glasses_services.dart';
import 'setup_screen.dart'; // Нужен для kUdpPort и SetupScreen
import 'caching_tile_provider.dart';
import 'offline_map_storage.dart';
import 'offline_map_preview_screen.dart';
import 'app_theme.dart';
import 'app_widgets.dart';

class FpvScreen extends StatefulWidget {
  final Map<String, String> savedPlaces;
  const FpvScreen({super.key, this.savedPlaces = const {}});

  @override
  State<FpvScreen> createState() => _FpvScreenState();
}

class _FpvScreenState extends State<FpvScreen> {
  RawDatagramSocket? _udpSocket;

  final Map<int, List<Uint8List?>> _activeFrames = {};
  int _highestFrameId = 0;
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
  static const _uiFrameIntervalMs = 80;
  static const _detectionUiIntervalMs = 250;
  static const _aiMinIntervalMs = 100; // цель: до 10 инференсов/сек

  int _lastSpokenTime = 0;

  int _framesReceivedThisSecond = 0;
  int _uiFramesThisSecond = 0;
  int _aiFramesThisSecond = 0;
  int _bytesReceivedThisSecond = 0;
  Timer? _fpsTimer;

  String _debugInfo = "Ожидание пакетов...";

  bool _isListening = false;
  bool _hasSpokenConnected = false;

  // Навигация — карта
  final MapController _mapController = MapController();
  LatLng? _userLatLng;
  LatLng? _destLatLng;
  List<LatLng> _routePoints = [];
  StreamSubscription<Position>? _positionSub;

  bool _settingsOpen = false;

  // Переменная ожидания двухэтапного диалога набора адреса
  bool _awaitingAddress = false;
  String _navDebugLog = '';

  // Провайдер офлайн-тайлов с in-memory индексом
  final IndexedCachingTileProvider _tileProvider = IndexedCachingTileProvider();

  int _lastLocationUiMs = 0;
  static const _locationUiIntervalMs = 2500;

  AppMode get _currentMode => _services.modeSelector.currentMode;

  @override
  void initState() {
    super.initState();

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

          final now = DateTime.now().millisecondsSinceEpoch;
          final shouldRefreshUi =
              now - _lastLocationUiMs >= _locationUiIntervalMs;
          if (!shouldRefreshUi) return;

          _lastLocationUiMs = now;
          if (_currentMode == AppMode.navigation) {
            setState(() {});
            try {
              _mapController.move(ll, _mapController.camera.zoom);
            } catch (_) {}
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
    _services.navigation.stopNavigation();
    if (mounted) {
      setState(() {
        _routePoints = [];
        _destLatLng = null;
        _navDebugLog = '';
      });
    }
    _services.speak("Маршрут отменён.", priority: 2).catchError((_) {});
  }

  void _onRouteUpdated(List<LatLng> points, LatLng dest) {
    if (!mounted) return;
    setState(() {
      _routePoints = points;
      _destLatLng = dest;
    });
    if (points.isNotEmpty) {
      try {
        _mapController.move(points.first, 16.0);
      } catch (_) {}
    }
  }

  Future<void> _setupAIandVoice() async {
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

    _services.modeSelector.onModeChanged = (mode) {
      _handleModeChanged(mode);
    };

    _services.navigation.onRouteReady = _onRouteUpdated;
    _services.navigation.onDebugLog = (message) {
      if (!mounted) return;
      setState(() => _navDebugLog = message);
    };

    _tts
        .speak(
          "Приложение запущено. Ожидаю видео. Нажмите на экран для голосовой команды.",
        )
        .catchError((e) => debugPrint("TTS error: $e"));
  }

  void _startUdpServer(int port) async {
    try {
      _udpSocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        port,
        reuseAddress: true,
      );
      debugPrint("✅ UDP сервер запущен на 0.0.0.0:$port");
      if (mounted) setState(() => _debugInfo = "UDP OK :$port — ждём пакеты");

      _udpSocket!.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          Datagram? dg;
          while ((dg = _udpSocket!.receive()) != null) {
            final data = dg!.data;
            _bytesReceivedThisSecond += data.length;
            _processPacket(data, dg.address);
          }
        }
      });
    } catch (e) {
      debugPrint("❌ ОШИБКА UDP: $e");
      _udpSocket?.close();
      _udpSocket = null;
      if (mounted) setState(() => _debugInfo = "Ошибка UDP: $e");
      Future.delayed(const Duration(seconds: 1), () {
        if (mounted && _udpSocket == null) _startUdpServer(port);
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

    if (mode == AppMode.navigation && _userLatLng != null) {
      Future.delayed(const Duration(milliseconds: 300), () {
        try {
          _mapController.move(_userLatLng!, 16.0);
        } catch (_) {}
      });
    }
  }

  void _processPacket(Uint8List data, InternetAddress source) {
    _espCamera.updateAddress(source);

    if (!_hasSpokenConnected) {
      _hasSpokenConnected = true;
      _services
          .speak("Очки успешно подключены.", priority: 0)
          .catchError((_) {});
    }

    if (data.length < 9) return;

    final header = ByteData.sublistView(data, 0, 8);
    final fId    = header.getUint32(0, Endian.little);
    final cId    = header.getUint16(4, Endian.little);
    final tChunks = header.getUint16(6, Endian.little);
    final payload = data.sublist(8);

    _assembleFrame(
      fId: fId,
      cId: cId,
      tChunks: tChunks,
      payload: payload,
    );
  }

  void _assembleFrame({
    required int fId,
    required int cId,
    required int tChunks,
    required Uint8List payload,
  }) {
    if (fId < _highestFrameId - 50) {
      _highestFrameId = 0;
      _activeFrames.clear();
    }
    if (fId < _highestFrameId - 2) return;
    if (fId > _highestFrameId) {
      _highestFrameId = fId;
      _activeFrames.removeWhere((key, _) => key < fId - 2);
    }

    final existing = _activeFrames[fId];
    if (existing == null || existing.length != tChunks) {
      _activeFrames[fId] = List<Uint8List?>.filled(tChunks, null);
    }
    if (cId < _activeFrames[fId]!.length) {
      _activeFrames[fId]![cId] = payload;
    }

    if (!_activeFrames[fId]!.contains(null)) {
      final builder = BytesBuilder();
      for (final chunk in _activeFrames[fId]!) {
        builder.add(chunk!);
      }
      _activeFrames.remove(fId);
      _onVideoFrameComplete(builder.toBytes());
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

    final showVideo = _currentMode != AppMode.navigation;
    if (showVideo && now - _lastUiUpdateTime > _uiFrameIntervalMs) {
      _latestDisplayFrame = fullJpeg;
      _frameNotifier.value = fullJpeg;
      _lastUiUpdateTime = now;
      _uiFramesThisSecond++;
    }

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

  /// Запуск AI только если не заняты.
  void _tryScheduleAi(int now) {
    if (_isProcessingAI || _latestAiFrame == null) return;
    if (_currentMode == AppMode.reading) return;
    if (now - _lastAiProcessTime < _aiMinIntervalMs) return;
    _runAI();
  }

  Future<void> _runAI() async {
    if (_isProcessingAI || _latestAiFrame == null) return;
    _isProcessingAI = true;
    _lastAiProcessTime = DateTime.now().millisecondsSinceEpoch;
    // Самый свежий JPEG на момент старта — не «следующий по порядку» из очереди.
    final frame = _latestAiFrame!;
    try {
      final List<DetectedObject> objects = await _aiDetector.processFrame(
        frame,
      );
      _aiFramesThisSecond++;
      if (mounted) {
        final now = DateTime.now().millisecondsSinceEpoch;
        if (now - _lastDetectionUiTime >= _detectionUiIntervalMs) {
          _detectionsNotifier.value = objects;
          _lastDetectionUiTime = now;
        }
      }

      _services.onFrameAnalyzed(objects: objects, jpeg: frame);

      if ((_currentMode == AppMode.standard ||
              _currentMode == AppMode.navigation) &&
          !_isListening) {
        _analyzeAndSpeak(objects);
      }
    } catch (e) {
      debugPrint("❌ _runAI error: $e");
    } finally {
      _isProcessingAI = false;
      if (mounted) {
        _tryScheduleAi(DateTime.now().millisecondsSinceEpoch);
      }
    }
  }

  void _analyzeAndSpeak(List<DetectedObject> objects) {
    int now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastSpokenTime < 3000) return;
    for (var obj in objects) {
      if (obj.label.contains("car") ||
          obj.label.contains("truck") ||
          obj.label.contains("bus")) {
        if (obj.rect[2] - obj.rect[0] > 0.5) {
          _services.speak("Внимание! Близко машина!", priority: 3);
          _lastSpokenTime = now;
          break;
        }
      } else if (obj.label.contains("person")) {
        if (obj.rect[2] - obj.rect[0] > 0.6) {
          _services.speak("Впереди человек!", priority: 1);
          _lastSpokenTime = now;
          break;
        }
      } else if (obj.label.contains("stop sign")) {
        _services.speak("Впереди знак стоп.", priority: 1);
        _lastSpokenTime = now;
        break;
      }
    }
  }

  void _startListening() async {
    bool available = await _speechToText.initialize();
    if (available && mounted) {
      setState(() => _isListening = true);
      _speechToText.listen(
        listenOptions: stt.SpeechListenOptions(localeId: "ru_RU"),
        onResult: (result) {
          if (result.finalResult) {
            final heard = result.recognizedWords.toLowerCase();
            debugPrint('[STT] Услышано: "$heard"');
            setState(() {
              _isListening = false;
              _navDebugLog = 'Услышано: "$heard"';
            });
            _processVoiceCommand(heard);
          }
        },
      );
    } else {
      _services.speak("Микрофон недоступен.", priority: 0).catchError((_) {});
    }
  }

  void _listenCommand() {
    if (!_isListening) {
      _awaitingAddress =
          false; // Сбрасываем флаг ожидания при новом ручном нажатии
      _services.speak("Слушаю", priority: 0).catchError((_) {});
      _startListening();
    } else {
      setState(() => _isListening = false);
      _speechToText.stop();
    }
  }

  Future<void> _processVoiceCommand(String command) async {
    debugPrint('[STT] Команда: "$command"');
    if (_awaitingAddress) {
      setState(() => _navDebugLog = 'Адрес: "$command"');
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

    final cmd = command.toLowerCase().trim();

    // Отмена маршрута
    if (cmd.contains("отмени маршрут") ||
        cmd.contains("отменить маршрут") ||
        cmd.contains("стоп маршрут") ||
        cmd.contains("остановить навигацию") ||
        cmd.contains("отмена маршрут") ||
        cmd == "стоп") {
      _cancelRoute();
      return;
    }

    // Перехватываем команду на запуск двухэтапного набора адреса
    if (cmd == "построй маршрут" ||
        cmd == "проложи маршрут" ||
        cmd == "навигация" ||
        cmd == "куда идти" ||
        cmd == "поехали") {
      setState(() => _awaitingAddress = true);
      await _services.speak("Назовите адрес или место", priority: 1);

      await Future.delayed(const Duration(milliseconds: 2000));

      if (mounted) {
        _startListening();
      }
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
        onSaved: (places) {
          _services.navigation.updateSavedPlaces(places);
        },
      ),
    );
    _settingsOpen = false;
  }

  @override
  void dispose() {
    _fpsTimer?.cancel();
    _udpSocket?.close();
    _aiDetector.dispose();
    _services.dispose();
    _tts.stop();
    _speechToText.stop();
    _positionSub?.cancel();
    _frameNotifier.dispose();
    _detectionsNotifier.dispose();
    _fpsNotifier.dispose();
    _uiFpsNotifier.dispose();
    _aiFpsNotifier.dispose();
    _kbpsNotifier.dispose();
    super.dispose();
  }

  Color _modeColor(AppMode mode) {
    switch (mode) {
      case AppMode.navigation:
        return AppColors.accent;
      case AppMode.reading:
        return const Color(0xFFFB923C);
      case AppMode.radar:
        return AppColors.success;
      case AppMode.standard:
        return AppColors.textSecondary;
    }
  }

  IconData _modeIcon(AppMode mode) {
    switch (mode) {
      case AppMode.navigation:
        return Icons.map;
      case AppMode.reading:
        return Icons.menu_book_rounded;
      case AppMode.radar:
        return Icons.spatial_audio;
      case AppMode.standard:
        return Icons.visibility;
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

          if (_currentMode == AppMode.navigation)
            _buildMapOverlay(topPad, bottomPad),

          if (_currentMode != AppMode.navigation || _isListening)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: _listenCommand,
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
              child: Row(
                children: [
                  _buildModeButton(AppMode.standard, 'Камера', Icons.videocam_rounded),
                  _buildModeButton(AppMode.navigation, 'Карта', Icons.map_rounded),
                  _buildModeButton(AppMode.reading, 'Чтение', Icons.menu_book_rounded),
                ],
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

    final markers = <Marker>[
      if (_userLatLng != null)
        Marker(
          point: _userLatLng!,
          width: 36,
          height: 36,
          child: const _UserMarker(),
        ),
      if (_destLatLng != null)
        Marker(
          point: _destLatLng!,
          width: 36,
          height: 36,
          child: const Icon(Icons.location_pin, color: Colors.red, size: 36),
        ),
    ];

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      bottom: bottomPad + 96,
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(bottom: Radius.circular(16)),
        child: Stack(
          children: [
            FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: center,
                initialZoom: 16.0,
                interactionOptions: const InteractionOptions(
                  flags: InteractiveFlag.all,
                ),
                onTap: (tapPosition, point) => _listenCommand(),
              ),
              children: [
                TileLayer(
                  urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                  userAgentPackageName: 'com.smartglasses.app',
                  tileProvider: _tileProvider,
                ),
                if (_routePoints.length >= 2)
                  PolylineLayer(
                    polylines: [
                      Polyline(
                        points: _routePoints,
                        color: AppColors.accent,
                        strokeWidth: 5.0,
                      ),
                    ],
                  ),
                MarkerLayer(markers: markers),
              ],
            ),
            Positioned(
              top: topPad + 52,
              right: 16,
              child: Container(
                decoration: hudPanelDecoration(accentColor: AppColors.accent),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () {
                      if (_userLatLng != null) {
                        _mapController.move(_userLatLng!, 16.0);
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
            ),
            if (_services.navigation.destinationName.isNotEmpty ||
                _routePoints.isNotEmpty)
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
    return Expanded(
      child: GestureDetector(
        onTap: () {
          _services.modeSelector.processCommand(mode.label);
          if (mounted) setState(() {});
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
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
                  fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ],
          ),
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
  final void Function(Map<String, String>) onSaved;

  const _SettingsSheet({
    required this.savedPlaces,
    required this.tileProvider,
    required this.readingService,
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

  bool _isDownloading = false;
  double _downloadProgress = 0.0;
  String _downloadStatus = '';
  final TextEditingController _regionCtrl = TextEditingController();

  List<OfflineMapRegion> _offlineRegions = [];
  bool _loadingRegions = true;
  Map<String, int> _regionSizes = {};

  @override
  void initState() {
    super.initState();
    _places = Map.from(widget.savedPlaces);
    _selectedAllergens = widget.readingService.userAllergens.toSet();
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
