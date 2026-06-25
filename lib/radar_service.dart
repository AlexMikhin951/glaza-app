import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'ai_detector.dart';

/// Звук-радар: чем ближе объект — тем чаще пищит.
/// Левый/правый канал определяется позицией объекта в кадре.
class RadarService {
  final AudioPlayer _playerLeft = AudioPlayer();
  final AudioPlayer _playerRight = AudioPlayer();

  bool _enabled = false;
  Timer? _beepTimer;

  // Текущие объекты для радара
  List<DetectedObject> _objects = [];

  Future<void> init() async {
    try {
      // Предзагружаем короткий бип-звук из assets
      await _playerLeft.setAsset('assets/sounds/beep.mp3');
      await _playerRight.setAsset('assets/sounds/beep.mp3');
      debugPrint('✅ RadarService initialized');
    } catch (e) {
      debugPrint('⚠️ RadarService init error: $e');
    }
  }

  void enable() {
    _enabled = true;
    _startLoop();
  }

  void disable() {
    _enabled = false;
    _beepTimer?.cancel();
    _beepTimer = null;
  }

  bool get isEnabled => _enabled;

  /// Обновляем список объектов из YOLO детектора.
  void updateObjects(List<DetectedObject> objects) {
    _objects = objects;
  }

  void _startLoop() {
    _beepTimer?.cancel();
    // Пересчитываем интервал каждые 80 мс
    _beepTimer = Timer.periodic(const Duration(milliseconds: 80), (_) {
      if (!_enabled) return;
      _processRadar();
    });
  }

  void _processRadar() {
    if (_objects.isEmpty) return;

    // Берём самый близкий (крупный) объект
    DetectedObject? closest;
    double maxWidth = 0.0;
    for (final obj in _objects) {
      final width = obj.rect[3] - obj.rect[1]; // right - left
      if (width > maxWidth) {
        maxWidth = width;
        closest = obj;
      }
    }

    if (closest == null || maxWidth < 0.15) return; // объект слишком маленький

    // Интервал бипа: 500мс при маленьком объекте → 80мс при вплотную
    final intervalMs = (500 - maxWidth * 400).clamp(80.0, 500.0).toInt();

    // Позиция по X: 0.0 = левый край, 1.0 = правый
    final centerX = (closest.rect[1] + closest.rect[3]) / 2;
    final pan = (centerX - 0.5) * 2.0; // -1.0 .. +1.0

    // Триггер бипа с нужным интервалом через простой счётчик
    final now = DateTime.now().millisecondsSinceEpoch;
    if ((now % intervalMs) < 80) {
      _playBeep(pan: pan, volume: (maxWidth * 1.5).clamp(0.3, 1.0));
    }
  }

  void _playBeep({required double pan, required double volume}) {
    try {
      if (pan < -0.2) {
        // Левый канал
        _playerLeft.setVolume(volume);
        _playerLeft.seek(Duration.zero);
        _playerLeft.play();
      } else if (pan > 0.2) {
        // Правый канал
        _playerRight.setVolume(volume);
        _playerRight.seek(Duration.zero);
        _playerRight.play();
      } else {
        // По центру — оба
        _playerLeft.setVolume(volume * 0.7);
        _playerRight.setVolume(volume * 0.7);
        _playerLeft.seek(Duration.zero);
        _playerRight.seek(Duration.zero);
        _playerLeft.play();
        _playerRight.play();
      }
    } catch (e) {
      debugPrint('RadarService beep error: $e');
    }
  }

  /// Генерируем простой синусоидальный бип программно (запасной вариант).
  /// Используется если assets/sounds/beep.mp3 не найден.
  static Uint8List generateBeepWav({
    int sampleRate = 44100,
    double frequency = 880,
    double durationMs = 60,
  }) {
    final numSamples = (sampleRate * durationMs / 1000).round();
    final data = Int16List(numSamples);
    for (int i = 0; i < numSamples; i++) {
      final t = i / sampleRate;
      // Затухание в конце
      final envelope = (1.0 - i / numSamples);
      data[i] = (32767 * envelope * 0.5 * _sin(2 * 3.14159 * frequency * t))
          .round()
          .clamp(-32768, 32767);
    }
    return _buildWavHeader(data.buffer.asUint8List(), sampleRate);
  }

  static double _sin(double x) {
    // Быстрая аппроксимация sin для генерации бипа
    x = x % (2 * 3.14159);
    if (x < 0) x += 2 * 3.14159;
    // Taylor series approximation
    final x2 = x * x;
    return x * (1 - x2 / 6 * (1 - x2 / 20));
  }

  static Uint8List _buildWavHeader(Uint8List pcmData, int sampleRate) {
    final bytes = BytesBuilder();
    final dataSize = pcmData.length;
    void writeInt32(int v) {
      bytes.addByte(v & 0xFF);
      bytes.addByte((v >> 8) & 0xFF);
      bytes.addByte((v >> 16) & 0xFF);
      bytes.addByte((v >> 24) & 0xFF);
    }

    void writeInt16(int v) {
      bytes.addByte(v & 0xFF);
      bytes.addByte((v >> 8) & 0xFF);
    }

    bytes.add([82, 73, 70, 70]); // RIFF
    writeInt32(36 + dataSize);
    bytes.add([87, 65, 86, 69]); // WAVE
    bytes.add([102, 109, 116, 32]); // fmt
    writeInt32(16);
    writeInt16(1); // PCM
    writeInt16(1); // mono
    writeInt32(sampleRate);
    writeInt32(sampleRate * 2);
    writeInt16(2);
    writeInt16(16);
    bytes.add([100, 97, 116, 97]); // data
    writeInt32(dataSize);
    bytes.add(pcmData);
    return bytes.toBytes();
  }

  void dispose() {
    disable();
    _playerLeft.dispose();
    _playerRight.dispose();
  }
}
