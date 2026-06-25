import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// Режимы работы приложения
enum AppMode {
  navigation,
  reading,
  radar,
  standard,
}

extension AppModeLabel on AppMode {
  String get label {
    switch (this) {
      case AppMode.navigation:
        return 'навигация';
      case AppMode.reading:
        return 'чтение';
      case AppMode.radar:
        return 'радар';
      case AppMode.standard:
        return 'стандартный';
    }
  }
}

/// Менеджер голосового переключения режимов.
class VoiceModeSelector {
  final FlutterTts _tts;
  final Future<void> Function(String text, {int priority}) _enqueue;

  AppMode _currentMode = AppMode.standard;
  void Function(AppMode)? onModeChanged;

  VoiceModeSelector(
    this._tts, {
    required Future<void> Function(String text, {int priority}) enqueueCallback,
  }) : _enqueue = enqueueCallback;

  AppMode get currentMode => _currentMode;

  /// Обрабатывает голосовую команду. Возвращает true если команда обработана.
  Future<bool> processCommand(String command) async {
    final cmd = command.toLowerCase().trim();

    if (_matchesNavigation(cmd)) {
      await _setMode(AppMode.navigation);
      return true;
    }
    if (_matchesReading(cmd)) {
      await _setMode(AppMode.reading);
      return true;
    }
    if (_matchesRadar(cmd)) {
      await _setMode(AppMode.radar);
      return true;
    }
    if (_matchesStandard(cmd)) {
      await _setMode(AppMode.standard);
      return true;
    }

    if (cmd.contains('режим') &&
        (cmd.contains('какой') || cmd.contains('текущий'))) {
      await _enqueue('Текущий режим: ${_currentMode.label}', priority: 0);
      return true;
    }

    if (cmd.contains('режимы') || cmd.contains('что умеешь')) {
      await _enqueue(
        'Доступные режимы: стандартный, навигация, радар, чтение. '
        'Скажите название режима для переключения.',
        priority: 0,
      );
      return true;
    }

    return false;
  }

  bool _matchesNavigation(String cmd) =>
      cmd.contains('навигация') ||
      cmd.contains('навигацию') ||
      cmd.contains('карта') ||
      cmd.contains('карту') ||
      cmd.contains('где я') ||
      cmd.contains('маршрут') ||
      cmd.contains('gps');

  bool _matchesReading(String cmd) =>
      cmd.contains('чтение') ||
      cmd.contains('читай') ||
      cmd.contains('прочитай') ||
      cmd.contains('этикетку') ||
      cmd.contains('ценник');

  bool _matchesRadar(String cmd) =>
      cmd.contains('радар') ||
      cmd.contains('радаром') ||
      cmd.contains('парктроник') ||
      cmd.contains('расстояние') ||
      cmd.contains('бипы') ||
      cmd.contains('звуковой');

  bool _matchesStandard(String cmd) =>
      cmd.contains('стандартный') ||
      cmd.contains('обычный') ||
      cmd.contains('обычный режим') ||
      cmd.contains('назад') ||
      cmd.contains('камера');

  Future<void> _setMode(AppMode mode) async {
    if (_currentMode == mode) {
      await _enqueue('Уже в режиме ${mode.label}', priority: 0);
      return;
    }
    _currentMode = mode;
    onModeChanged?.call(mode);
    if (mode == AppMode.reading) {
      await _enqueue(
        'Режим чтения. Наведите камеру на текст и скажите: фото.',
        priority: 0,
      );
    } else {
      await _enqueue('Режим: ${mode.label}', priority: 0);
    }
    debugPrint('✅ Mode changed to: ${mode.label}');
  }

  Future<void> speakWelcome() async {
    await _enqueue(
      'Режим ${_currentMode.label}. '
      'Нажмите и скажите: навигация, радар, чтение или стандартный.',
      priority: 0,
    );
  }

  Future<String?> getContextHelp() async {
    switch (_currentMode) {
      case AppMode.reading:
        return 'Скажите «фото» — камера снимет этикетку или ценник в максимальном качестве.';
      case AppMode.navigation:
        return 'Хожу по карте. Скажите «где я» для текущей позиции.';
      case AppMode.radar:
        return 'Радар активен. Чем ближе объект, тем чаще бипы.';
      case AppMode.standard:
        return 'Детектирую объекты. Скажите «режимы» для списка.';
    }
  }
}
