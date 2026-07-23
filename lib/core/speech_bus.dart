import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// Приоритеты озвучки (как в плане Orby/Envision).
abstract final class SpeechPriority {
  static const int chatter = 0; // сцена, цвет — выкидывать старше 5 с
  static const int info = 1; // человек ~8 м, остановка
  static const int navigation = 2; // поворот, выбор маршрута
  static const int hazard = 3; // машина близко, яма
  static const int critical = 4; // SOS, потеря камеры
}

class _TtsMessage {
  final String text;
  final int priority;
  final int timestamp;
  final Completer<void>? done;
  final int id;

  _TtsMessage(this.text, this.priority, {this.done, required this.id})
      : timestamp = DateTime.now().millisecondsSinceEpoch;
}

/// Единая очередь TTS с interrupt, mute radar и логом «что сказал».
class SpeechBus {
  final FlutterTts tts;
  void Function()? onMuteRadar;
  void Function()? onUnmuteRadar;

  final List<_TtsMessage> _queue = [];
  bool _busy = false;
  String _lastSpokenText = '';
  String _lastHeardCommand = '';
  final List<String> _speakLog = [];
  _TtsMessage? _current;
  bool _radarMuted = false;
  bool _initialized = false;
  int _nextId = 1;
  /// Игнор completion от tts.stop() при interrupt — иначе двойная озвучка.
  bool _ignoringCancel = false;
  /// Пока true — отбрасываем озвучку ниже navigation (выбор маршрута / объявление).
  bool _navFocus = false;

  SpeechBus(this.tts);

  String get lastSpokenText => _lastSpokenText;
  String get lastHeardCommand => _lastHeardCommand;
  List<String> get speakLog => List.unmodifiable(_speakLog);
  bool get navFocus => _navFocus;

  void noteHeard(String command) {
    _lastHeardCommand = command;
  }

  /// Приглушить болтовню карты/сцены на время навигационных объявлений.
  void beginNavFocus() {
    _navFocus = true;
    _queue.removeWhere((m) {
      if (m.priority >= SpeechPriority.navigation) return false;
      if (!(m.done?.isCompleted ?? true)) m.done?.complete();
      return true;
    });
  }

  void endNavFocus() {
    _navFocus = false;
  }

  Future<void> init() async {
    if (_initialized) return;
    tts.setCompletionHandler(_onComplete);
    // ВАЖНО: cancel ≠ complete. Раньше stop() вызывал drain и шла какофония.
    try {
      tts.setCancelHandler(() {
        debugPrint('SpeechBus: TTS cancelled (ignored as completion)');
      });
    } catch (_) {}
    tts.setErrorHandler((msg) {
      debugPrint('SpeechBus TTS error: $msg');
      if (_ignoringCancel) return;
      _finishCurrent();
      _drain();
    });
    _initialized = true;
  }

  Future<void> interrupt() async {
    for (final m in _queue) {
      if (!(m.done?.isCompleted ?? true)) m.done?.complete();
    }
    _queue.clear();
    final cur = _current;
    _current = null;
    if (cur != null && !(cur.done?.isCompleted ?? true)) {
      cur.done?.complete();
    }
    _ignoringCancel = true;
    try {
      await tts.stop();
    } catch (_) {}
    _ignoringCancel = false;
    _busy = false;
    _unmuteRadar();
  }

  Future<void> speakAndWait(String text, {int? priority}) async {
    if (text.isEmpty) return;
    final done = Completer<void>();
    await enqueue(text, priority: priority, done: done);
    try {
      await done.future.timeout(const Duration(seconds: 45));
    } catch (_) {}
  }

  Future<void> enqueue(
    String text, {
    int? priority,
    Completer<void>? done,
  }) async {
    if (text.isEmpty) {
      done?.complete();
      return;
    }

    final p = priority ?? SpeechPriority.chatter;

    if (_navFocus && p < SpeechPriority.navigation) {
      done?.complete();
      return;
    }

    if (_queue.any((m) => m.text == text) ||
        (_current?.text == text && _busy)) {
      done?.complete();
      return;
    }

    final msg = _TtsMessage(text, p, done: done, id: _nextId++);

    // Прерываем ТОЛЬКО если новый приоритет строго выше текущего.
    // P2 не рвёт другой P2 — иначе выбор маршрута режется алертами карты.
    final curPri = _current?.priority ?? -1;
    if (_busy && p > curPri && p >= SpeechPriority.hazard) {
      _ignoringCancel = true;
      try {
        await tts.stop();
      } catch (_) {}
      _ignoringCancel = false;

      final cur = _current;
      _current = null;
      if (cur != null && !(cur.done?.isCompleted ?? true)) {
        cur.done?.complete();
      }
      _busy = false;

      _queue.removeWhere((m) {
        if (m.priority >= p) return false;
        if (!(m.done?.isCompleted ?? true)) m.done?.complete();
        return true;
      });
    }

    _queue.add(msg);
    _queue.sort((a, b) {
      final pc = b.priority.compareTo(a.priority);
      return pc != 0 ? pc : a.timestamp.compareTo(b.timestamp);
    });

    _queue.removeWhere((m) {
      final stale = m.priority == SpeechPriority.chatter &&
          DateTime.now().millisecondsSinceEpoch - m.timestamp > 5000;
      if (stale && !(m.done?.isCompleted ?? true)) m.done?.complete();
      return stale;
    });

    if (!_busy) _drain();
  }

  Future<void> repeatLast() async {
    if (_lastSpokenText.isEmpty) {
      await enqueue('Нечего повторять.', priority: SpeechPriority.info);
      return;
    }
    await enqueue(_lastSpokenText, priority: SpeechPriority.info);
  }

  String statusReport() {
    final heard = _lastHeardCommand.isEmpty ? 'нет' : _lastHeardCommand;
    final said = _lastSpokenText.isEmpty ? 'нет' : _lastSpokenText;
    return 'Услышал: $heard. Сказал: $said.';
  }

  void _finishCurrent() {
    final cur = _current;
    _current = null;
    if (cur != null && !(cur.done?.isCompleted ?? true)) {
      cur.done?.complete();
    }
    _busy = false;
    _unmuteRadar();
  }

  void _onComplete() {
    if (_ignoringCancel) return;
    _finishCurrent();
    _drain();
  }

  void _drain() {
    if (_busy || _queue.isEmpty) {
      if (!_busy) _unmuteRadar();
      return;
    }
    final msg = _queue.removeAt(0);
    _busy = true;
    _current = msg;
    _lastSpokenText = msg.text;
    _speakLog.add(msg.text);
    if (_speakLog.length > 40) _speakLog.removeAt(0);
    _muteRadar();
    final spokenId = msg.id;
    tts.speak(msg.text).catchError((e) {
      debugPrint('SpeechBus drain error: $e');
      if (_current?.id == spokenId) {
        _finishCurrent();
        _drain();
      }
    });

    // Запасной таймер, если completion не пришёл. Не трогаем чужое сообщение.
    final approxMs = (msg.text.length * 75).clamp(900, 25000);
    Future.delayed(Duration(milliseconds: approxMs + 600), () {
      if (_current?.id == spokenId) {
        debugPrint('SpeechBus: watchdog finish id=$spokenId');
        _finishCurrent();
        _drain();
      }
    });
  }

  void _muteRadar() {
    if (_radarMuted) return;
    _radarMuted = true;
    onMuteRadar?.call();
  }

  void _unmuteRadar() {
    if (!_radarMuted) return;
    if (_busy || _queue.isNotEmpty) return;
    _radarMuted = false;
    onUnmuteRadar?.call();
  }

  void dispose() {
    _queue.clear();
    _initialized = false;
    _navFocus = false;
  }
}
