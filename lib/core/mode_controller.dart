import 'package:flutter/foundation.dart';

/// Режимы приложения (Seeing AI channels + Envision categories).
enum AppMode {
  /// Улица: фон опасностей + тихая карта.
  standard,

  /// Дом / помещение: препятствия и радар, без карты и дорожных знаков.
  home,

  /// Пошаговая навигация.
  navigation,

  /// OCR / документ.
  reading,

  /// Только бипы радара.
  radar,

  /// Поиск объекта («найди человека»).
  find,

  /// Цвет / свет / купюра / штрихкод.
  identify,

  /// Один кадр → YandexGPT.
  scene,
}

extension AppModeLabel on AppMode {
  String get label {
    switch (this) {
      case AppMode.standard:
        return 'улица';
      case AppMode.home:
        return 'дом';
      case AppMode.navigation:
        return 'навигация';
      case AppMode.reading:
        return 'чтение';
      case AppMode.radar:
        return 'радар';
      case AppMode.find:
        return 'поиск';
      case AppMode.identify:
        return 'идентификация';
      case AppMode.scene:
        return 'сцена';
    }
  }

  String get hint {
    switch (this) {
      case AppMode.standard:
        return 'Детектирую объекты и опасности вокруг.';
      case AppMode.home:
        return 'Домашний режим: препятствия и радар, без улицы и карты. '
            'Скажите: прочитай, найди, какой цвет, что передо мной.';
      case AppMode.navigation:
        return 'Скажите «куда идти» и адрес. Выбор маршрута: один, два, три.';
      case AppMode.reading:
        return 'Наведите на текст и скажите «фото» или «прочитай».';
      case AppMode.radar:
        return 'Бипы ближе — объект ближе. Минимум речи.';
      case AppMode.find:
        return 'Скажите «найди человека» или «найди машину».';
      case AppMode.identify:
        return 'Скажите: какой цвет, свет, какая купюра, штрихкод.';
      case AppMode.scene:
        return 'Скажите «что передо мной» — опишу сцену.';
    }
  }
}

/// Политика слоёв A/B/C для режима.
class ModePolicy {
  final bool safetyOn;
  final bool radarOn;
  final bool mapOn;
  final bool mapLoud;
  final bool cameraStream;
  final bool vibrationOn;
  final bool roadSignsOn;

  const ModePolicy({
    required this.safetyOn,
    required this.radarOn,
    required this.mapOn,
    this.mapLoud = false,
    this.cameraStream = true,
    this.vibrationOn = true,
    this.roadSignsOn = false,
  });

  static ModePolicy forMode(AppMode mode) {
    switch (mode) {
      case AppMode.standard:
        return const ModePolicy(
          safetyOn: true,
          radarOn: true,
          mapOn: true,
          mapLoud: false,
          roadSignsOn: true,
        );
      case AppMode.home:
        return const ModePolicy(
          safetyOn: true,
          radarOn: true,
          mapOn: false,
          roadSignsOn: false,
        );
      case AppMode.navigation:
        return const ModePolicy(
          safetyOn: true,
          radarOn: true,
          mapOn: true,
          mapLoud: true,
          roadSignsOn: true,
        );
      case AppMode.reading:
        return const ModePolicy(
          safetyOn: false,
          radarOn: false,
          mapOn: false,
          vibrationOn: false,
          cameraStream: false,
        );
      case AppMode.radar:
        return const ModePolicy(
          safetyOn: true,
          radarOn: true,
          mapOn: false,
        );
      case AppMode.find:
        return const ModePolicy(
          safetyOn: true,
          radarOn: true,
          mapOn: false,
        );
      case AppMode.identify:
        return const ModePolicy(
          safetyOn: false,
          radarOn: false,
          mapOn: false,
          vibrationOn: false,
        );
      case AppMode.scene:
        return const ModePolicy(
          safetyOn: false,
          radarOn: false,
          mapOn: false,
          vibrationOn: false,
          cameraStream: false,
        );
    }
  }
}

/// Профиль детализации улицы.
enum StreetDetailProfile {
  quiet, // улица тихо
  detailed, // улица подробно
}

extension StreetDetailProfileLabel on StreetDetailProfile {
  String get label =>
      this == StreetDetailProfile.quiet ? 'улица тихо' : 'улица подробно';
}

/// Контроллер режимов + политики слоёв.
class ModeController {
  final Future<void> Function(String text, {int? priority}) _enqueue;

  AppMode _current = AppMode.standard;
  StreetDetailProfile streetProfile = StreetDetailProfile.detailed;
  void Function(AppMode mode)? onModeChanged;

  /// Короткий цикл тройного тапа.
  static const List<AppMode> primaryCycle = [
    AppMode.standard,
    AppMode.home,
    AppMode.navigation,
    AppMode.reading,
  ];

  /// Полный список (голос / меню «ещё»).
  static const List<AppMode> allModes = AppMode.values;

  ModeController({
    required Future<void> Function(String text, {int? priority}) enqueueCallback,
  }) : _enqueue = enqueueCallback;

  AppMode get currentMode => _current;
  ModePolicy get policy => ModePolicy.forMode(_current);

  Future<bool> processCommand(String command) async {
    final cmd = command.toLowerCase().trim();

    if (_match(cmd, ['навигация', 'навигацию', 'карта', 'карту', 'gps'])) {
      await setMode(AppMode.navigation);
      return true;
    }
    if (_match(cmd, [
      'режим дом',
      'домашний',
      'домашний режим',
      'помещение',
      'режим помещение',
      'indoor',
    ]) ||
        cmd == 'дом' ||
        cmd == 'дома') {
      await setMode(AppMode.home);
      return true;
    }
    if (_match(cmd, [
      'чтение',
      'читай',
      'прочитай',
      'этикетку',
      'ценник',
      'режим чтение',
    ])) {
      await setMode(AppMode.reading);
      return true;
    }
    if (_match(cmd, ['радар', 'радаром', 'парктроник', 'бипы', 'звуковой'])) {
      await setMode(AppMode.radar);
      return true;
    }
    if (cmd == 'поиск' ||
        cmd.contains('режим поиск') ||
        cmd.contains('режим поиска')) {
      await setMode(AppMode.find);
      return true;
    }
    if (_match(cmd, [
      'идентификация',
      'распознавание',
      'режим цвет',
      'режим купюра',
    ])) {
      await setMode(AppMode.identify);
      return true;
    }
    if (cmd == 'сцена' ||
        cmd.contains('режим сцена') ||
        cmd.contains('режим сцены')) {
      await setMode(AppMode.scene);
      return true;
    }
    if (_match(cmd, [
      'улица',
      'стандартный',
      'обычный',
      'обычный режим',
      'камера',
    ])) {
      await setMode(AppMode.standard);
      return true;
    }

    if (cmd.contains('режим') &&
        (cmd.contains('какой') || cmd.contains('текущий'))) {
      await _enqueue('Текущий режим: ${_current.label}', priority: 0);
      return true;
    }

    if (cmd.contains('режимы') ||
        cmd.contains('что умеешь') ||
        cmd.contains('помощь команды')) {
      await _enqueue(
        'Режимы: улица, дом, навигация, чтение, поиск, радар, идентификация, сцена. '
        'Тройной тап листает улица, дом, навигация, чтение. '
        'Команды: куда идти, прочитай, найди человека, какой цвет, какая купюра, '
        'что передо мной, помощь, стоп.',
        priority: 0,
      );
      return true;
    }

    if (cmd.contains('улица тихо')) {
      streetProfile = StreetDetailProfile.quiet;
      await _enqueue('Профиль: улица тихо.', priority: 0);
      return true;
    }
    if (cmd.contains('улица подробно')) {
      streetProfile = StreetDetailProfile.detailed;
      await _enqueue('Профиль: улица подробно.', priority: 0);
      return true;
    }

    return false;
  }

  bool _match(String cmd, List<String> keys) =>
      keys.any((k) => cmd.contains(k));

  Future<void> setMode(AppMode mode, {bool announce = true}) async {
    if (_current == mode) {
      if (announce) {
        await _enqueue('Уже в режиме ${mode.label}', priority: 0);
      }
      return;
    }
    _current = mode;
    onModeChanged?.call(mode);
    if (!announce) return;
    if (mode == AppMode.home) {
      await _enqueue(
        'Домашний режим. Препятствия и радар. Карта и дорожные знаки выключены.',
        priority: 0,
      );
    } else if (mode == AppMode.reading) {
      await _enqueue(
        'Режим чтения. Наведите камеру на текст и скажите: фото.',
        priority: 0,
      );
    } else if (mode == AppMode.find) {
      await _enqueue(
        'Режим поиска. Скажите: найди человека, машину или стул.',
        priority: 0,
      );
    } else if (mode == AppMode.identify) {
      await _enqueue(
        'Режим идентификации. Скажите: какой цвет, свет, какая купюра или штрихкод.',
        priority: 0,
      );
    } else if (mode == AppMode.scene) {
      await _enqueue(
        'Режим сцены. Скажите: что передо мной.',
        priority: 0,
      );
    } else {
      await _enqueue('Режим: ${mode.label}', priority: 0);
    }
    debugPrint('✅ Mode → ${mode.label}');
  }

  Future<void> cycleMode() async {
    final idx = primaryCycle.indexOf(_current);
    final next = primaryCycle[(idx < 0 ? 0 : idx + 1) % primaryCycle.length];
    await setMode(next);
  }

  Future<void> speakWelcome() async {
    await _enqueue(
      'Очки подключены. Режим улица. '
      'Двойной тап — микрофон, тройной — смена режима, долгое нажатие — помощь. '
      'Скажите: дом, куда идти, прочитай, найди, что передо мной. Отмена — стоп.',
      priority: 0,
    );
  }

  Future<String?> getContextHelp() async => _current.hint;
}
