// lib/perf_logger.dart
import 'dart:io';
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Логирует метрики производительности в файл для офлайн-анализа.
/// Файл: <app_dir>/perf_log.csv
class PerfLogger {
  static PerfLogger? _instance;
  static PerfLogger get instance => _instance ??= PerfLogger._();

  PerfLogger._();

  IOSink? _sink;
  bool _ready = false;
  String? _filePath;

  /// Путь к лог-файлу (доступен после init).
  String? get filePath => _filePath;

  Future<void> init() async {
    if (_ready) return;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/perf_log.csv');
      _filePath = file.path;

      // Если файл новый — пишем заголовок
      final exists = await file.exists();
      _sink = file.openWrite(mode: FileMode.append);
      if (!exists) {
        _sink!.writeln(
          'timestamp_ms,event,value_ms,extra',
        );
      }
      _ready = true;
      debugPrint('📊 PerfLogger: $filePath');
    } catch (e) {
      debugPrint('PerfLogger init error: $e');
    }
  }

  /// Записывает одну строку метрики.
  /// [event] — тип события (inference, decode, nms, frame_received, fps, etc.)
  /// [valueMs] — длительность в мс (или счётчик)
  /// [extra] — любая доп. инфо (размер кадра, кол-во объектов и т.д.)
  void log(String event, int valueMs, {String extra = ''}) {
    if (!_ready || _sink == null) return;
    try {
      final ts = DateTime.now().millisecondsSinceEpoch;
      _sink!.writeln('$ts,$event,$valueMs,$extra');
    } catch (_) {
      // IOSink уже закрыт / занят (dispose во время AI) — игнорируем.
      _ready = false;
    }
  }

  /// Периодический сброс буфера (вызывать раз в секунду из FPS-таймера).
  void flush() {
    if (!_ready) return;
    try {
      _sink?.flush();
    } catch (_) {}
  }

  void dispose() {
    _ready = false;
    final sink = _sink;
    _sink = null;
    try {
      sink?.flush();
      sink?.close();
    } catch (_) {}
    _instance = null;
  }
}
