import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../ai_detector.dart';
import '../distance_estimator.dart';
import '../radar_service.dart';

/// Поиск объекта в кадре (Envision Find).
class FindService {
  final Future<void> Function(String text, {int? priority}) _enqueue;
  final RadarService radar;

  String? _target; // coco label key or russian synonym resolved
  String? _targetRu;
  bool _active = false;
  int _startedMs = 0;
  int _lastAnnounceMs = 0;
  bool _foundOnce = false;
  Timer? _timeout;

  static const _timeoutSec = 30;
  static const _announceCooldownMs = 2500;

  static const Map<String, List<String>> _aliases = {
    'person': ['человек', 'людей', 'человека', 'люди', 'пешеход'],
    'car': ['машина', 'машину', 'авто', 'автомобиль', 'машине'],
    'bus': ['автобус', 'автобуса'],
    'truck': ['грузовик', 'фура'],
    'bicycle': ['велосипед', 'велик'],
    'motorcycle': ['мотоцикл', 'мопед'],
    'dog': ['собака', 'собаку', 'пёс', 'пес'],
    'cat': ['кошка', 'кот', 'кошку'],
    'chair': ['стул', 'стула'],
    'couch': ['диван', 'дивана'],
    'bench': ['скамейка', 'лавка'],
    'bottle': ['бутылка', 'бутылку'],
    'cup': ['кружка', 'чашка'],
    'book': ['книга', 'книгу'],
    'cell phone': ['телефон', 'смартфон'],
    'backpack': ['рюкзак'],
    'handbag': ['сумка', 'сумку'],
    'umbrella': ['зонт'],
    'traffic light': ['светофор'],
    'stop sign': ['стоп', 'знак стоп'],
  };

  FindService({
    required Future<void> Function(String text, {int? priority}) enqueueCallback,
    required this.radar,
  }) : _enqueue = enqueueCallback;

  bool get isActive => _active;
  String? get targetRu => _targetRu;

  /// Парсит «найди человека» / «найти машину».
  Future<bool> handleCommand(String command) async {
    final cmd = command.toLowerCase().trim();
    if (!(cmd.contains('найди') ||
        cmd.contains('найти') ||
        cmd.contains('ищи') ||
        cmd.startsWith('поиск '))) {
      return false;
    }

    String? label;
    String? ru;
    for (final e in _aliases.entries) {
      for (final a in e.value) {
        if (cmd.contains(a)) {
          label = e.key;
          ru = e.value.first;
          break;
        }
      }
      if (label != null) break;
    }

    if (label == null) {
      await _enqueue(
        'Что искать? Скажите: найди человека, машину, стул, собаку.',
        priority: 1,
      );
      return true;
    }

    start(label, ru!);
    return true;
  }

  void start(String cocoLabel, String ruName) {
    stop(announce: false);
    _target = cocoLabel;
    _targetRu = ruName;
    _active = true;
    _foundOnce = false;
    _startedMs = DateTime.now().millisecondsSinceEpoch;
    _enqueue('Ищу: $ruName.', priority: 1);
    _timeout?.cancel();
    _timeout = Timer(const Duration(seconds: _timeoutSec), () {
      if (_active) {
        _enqueue('Поиск остановлен по времени.', priority: 1);
        stop(announce: false);
      }
    });
    debugPrint('FindService start: $cocoLabel');
  }

  void stop({bool announce = true}) {
    _timeout?.cancel();
    _timeout = null;
    final was = _active;
    _active = false;
    _target = null;
    if (was && announce) {
      _enqueue('Поиск остановлен.', priority: 1);
    }
  }

  void onFrame({
    required List<DetectedObject> objects,
    required Uint8List jpeg,
  }) {
    if (!_active || _target == null) return;

    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _startedMs > _timeoutSec * 1000) {
      stop();
      return;
    }

    DetectedObject? best;
    double bestArea = 0;
    for (final o in objects) {
      if (!_labelMatches(o.label, _target!)) continue;
      final area =
          (o.rect[2] - o.rect[0]).abs() * (o.rect[3] - o.rect[1]).abs();
      if (area > bestArea) {
        bestArea = area;
        best = o;
      }
    }

    if (best == null) {
      if (!_foundOnce && now - _lastAnnounceMs > 6000) {
        _lastAnnounceMs = now;
        _enqueue('Ищу ${_targetRu ?? 'объект'}...', priority: 0);
      }
      return;
    }

    _foundOnce = true;
    // Усиливаем радар на найденном объекте
    radar.updateObjects([best]);

    if (now - _lastAnnounceMs < _announceCooldownMs) return;
    _lastAnnounceMs = now;

    final cx = (best.rect[1] + best.rect[3]) / 2;
    final side = cx < 0.35
        ? 'слева'
        : (cx > 0.65 ? 'справа' : 'по центру');
    final meters = DistanceEstimator.estimateMeters(best);
    final dist = meters != null
        ? ' примерно ${meters < 10 ? meters.toStringAsFixed(0) : meters.toStringAsFixed(0)} метров'
        : '';
    _enqueue(
      '${_targetRu ?? 'Объект'} $side$dist.',
      priority: 1,
    );
  }

  bool _labelMatches(String detected, String target) {
    final d = detected.toLowerCase();
    final t = target.toLowerCase();
    return d.contains(t) || t.contains(d);
  }

  void dispose() {
    _timeout?.cancel();
  }
}
