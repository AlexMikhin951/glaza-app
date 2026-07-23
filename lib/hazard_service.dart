import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'ai_detector.dart';
import 'distance_estimator.dart';
import 'hazard_analyzer.dart';
import 'vibration_service.dart';
import 'vision/depth_service.dart';

/// Голосовые предупреждения об опасностях с примерной дистанцией.
///
/// Визуальные ямы/лестницы требуют подтверждения на нескольких кадрах —
/// иначе wide OV5640 даёт кучу ложных срабатываний на тенях.
class HazardService {
  final Future<void> Function(String text, {int? priority}) _enqueue;
  final VibrationService vibration;
  DepthService? depth;

  bool _enabled = true;
  bool _analyzingVisual = false;
  int _lastVisualScanMs = 0;
  int _lastSpeakMs = 0;
  String _lastSpeakKey = '';

  int _holeStreak = 0;
  int _stairsStreak = 0;
  int _lastHoleCandidateMs = 0;
  int _lastStairsCandidateMs = 0;

  static const int _speakCooldownMs = 7000;
  static const int _visualScanIntervalMs = 1100;
  static const int _holeConfirmFrames = 3;
  static const int _stairsConfirmFrames = 2;
  static const int _streakResetMs = 2800;

  HazardService({
    required Future<void> Function(String text, {int? priority}) enqueueCallback,
    required this.vibration,
    this.depth,
  }) : _enqueue = enqueueCallback;

  void enable() => _enabled = true;
  void disable() => _enabled = false;
  bool get isEnabled => _enabled;

  Future<void> init() async {
    debugPrint('✅ HazardService ready (OV5640-tuned)');
  }

  void onFrame({
    required List<DetectedObject> objects,
    required Uint8List jpeg,
  }) {
    if (!_enabled) return;

    _announceYoloHazards(objects, jpeg);

    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastVisualScanMs < _visualScanIntervalMs) return;
    if (_analyzingVisual) return;
    _lastVisualScanMs = now;
    _analyzingVisual = true;

    Future(() async {
      try {
        final depthSvc = depth;
        var depthHole = false;
        if (depthSvc != null) {
          depthHole = await depthSvc.holeCandidate(jpeg);
        }
        final hazards = await HazardAnalyzer.analyzeJpeg(jpeg);
        if (!_enabled) return;
        _onVisualCandidates(hazards, now, depthHoleHint: depthHole);
      } catch (e) {
        debugPrint('HazardService visual error: $e');
      } finally {
        _analyzingVisual = false;
      }
    });
  }

  void _onVisualCandidates(
    List<VisualHazard> hazards,
    int now, {
    bool depthHoleHint = false,
  }) {
    VisualHazard? hole;
    VisualHazard? stairs;
    for (final h in hazards) {
      if (h.type == VisualHazardType.hole &&
          h.confidence >= 0.58 &&
          h.distanceM <= 5.0) {
        if (hole == null || h.confidence > hole.confidence) hole = h;
      }
      if (h.type == VisualHazardType.stairs &&
          h.confidence >= 0.60 &&
          h.distanceM <= 9.0) {
        if (stairs == null || h.confidence > stairs.confidence) stairs = h;
      }
    }

    // Depth провал усиливает яму; один HSV без depth — слабее (нужен больший streak).
    final holeHit = hole != null || depthHoleHint;
    if (holeHit) {
      if (now - _lastHoleCandidateMs > _streakResetMs) _holeStreak = 0;
      _lastHoleCandidateMs = now;
      _holeStreak += depthHoleHint && hole != null ? 2 : 1;
    } else if (now - _lastHoleCandidateMs > _streakResetMs) {
      _holeStreak = 0;
    }

    if (stairs != null) {
      if (now - _lastStairsCandidateMs > _streakResetMs) _stairsStreak = 0;
      _lastStairsCandidateMs = now;
      _stairsStreak++;
    } else if (now - _lastStairsCandidateMs > _streakResetMs) {
      _stairsStreak = 0;
    }

    final needHole = depthHoleHint ? _holeConfirmFrames : (_holeConfirmFrames + 1);
    if (holeHit && _holeStreak >= needHole) {
      _announceConfirmed(
        hole ??
            const VisualHazard(
              type: VisualHazardType.hole,
              labelRu: 'яма',
              confidence: 0.7,
              distanceM: 2.5,
              bbox: [0.6, 0.3, 1.0, 0.7],
            ),
      );
      _holeStreak = 0;
    } else if (stairs != null && _stairsStreak >= _stairsConfirmFrames) {
      _announceConfirmed(stairs);
      _stairsStreak = 0;
    }
  }

  void _announceConfirmed(VisualHazard h) {
    final m = DistanceEstimator.speakableMeters(h.distanceM);
    final text = h.type == VisualHazardType.stairs
        ? 'Впереди лестница, примерно через $m ${_metersWord(m)}.'
        : 'Внизу возможна неровность или яма, примерно через $m ${_metersWord(m)}. Будьте осторожны.';
    final priority = h.distanceM < 3.5 ? 3 : 2;
    _speakHit(
      HazardHit(
        key: '${h.type.name}_$m',
        text: text,
        priority: priority,
        meters: h.distanceM,
        vibeDanger: h.type == VisualHazardType.hole && h.distanceM < 4,
        vibePerson: false,
      ),
    );
  }

  void _announceYoloHazards(List<DetectedObject> objects, Uint8List jpeg) {
    Future(() async {
      HazardHit? best;
      final depthSvc = depth;
      Float32List? map;
      if (depthSvc != null) {
        map = await depthSvc.process(jpeg);
      }
      for (final obj in objects) {
        if (obj.score < 0.55) continue;
        if (!DistanceEstimator.isHazardLabel(obj.label)) continue;
        double? meters;
        if (depthSvc != null) {
          meters = await depthSvc.metersForObject(obj, jpeg, depthMap: map);
        }
        meters ??= DistanceEstimator.estimateMeters(obj);
        if (meters == null) continue;
        final ru = DistanceEstimator.russianLabel(obj.label) ?? obj.label;
        final priority = _priorityFor(obj.label, meters);
        if (priority <= 0) continue;
        final hit = HazardHit(
          key: '${obj.label}_${DistanceEstimator.speakableMeters(meters)}',
          text: _phrase(ru, meters, urgent: meters < 4),
          priority: priority,
          meters: meters,
          vibeDanger: meters < 5 && _isVehicle(obj.label),
          vibePerson: obj.label.contains('person') && meters < 3.5,
        );
        if (best == null ||
            hit.priority > best.priority ||
            (hit.priority == best.priority && hit.meters < best.meters)) {
          best = hit;
        }
      }
      if (best != null) _speakHit(best);
    });
  }

  void _speakHit(HazardHit hit) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (hit.key == _lastSpeakKey && now - _lastSpeakMs < _speakCooldownMs) {
      return;
    }
    // Ямы — отдельный длинный кулдаун, чтобы не долбить ложными.
    if (hit.key.startsWith('hole_') && now - _lastSpeakMs < 10000) {
      return;
    }
    if (now - _lastSpeakMs < 2500 && hit.priority < 3) return;

    _lastSpeakKey = hit.key;
    _lastSpeakMs = now;
    _enqueue(hit.text, priority: hit.priority).catchError((_) {});

    if (hit.vibeDanger) {
      vibration.danger();
    } else if (hit.vibePerson) {
      vibration.person();
    } else if (hit.priority >= 2) {
      vibration.gentle();
    }
  }

  int _priorityFor(String label, double meters) {
    if (_isVehicle(label)) {
      if (meters <= 5) return 3;
      if (meters <= 10) return 2;
      if (meters <= 16) return 1;
      return 0;
    }
    if (label.contains('person') || label.contains('dog')) {
      if (meters <= 2.5) return 2;
      if (meters <= 6) return 1;
      return 0;
    }
    if (label.contains('bicycle') || label.contains('motorcycle')) {
      if (meters <= 4) return 3;
      if (meters <= 8) return 2;
      return 0;
    }
    if (label.contains('stop sign') && meters <= 12) return 1;
    return 0;
  }

  bool _isVehicle(String label) =>
      label.contains('car') ||
      label.contains('truck') ||
      label.contains('bus');

  String _phrase(String ru, double meters, {required bool urgent}) {
    final m = DistanceEstimator.speakableMeters(meters);
    final word = _metersWord(m);
    if (urgent) {
      return 'Внимание! $ru примерно через $m $word. Будьте осторожны.';
    }
    return '$ru примерно через $m $word.';
  }

  String _metersWord(int m) {
    final mod10 = m % 10;
    final mod100 = m % 100;
    if (mod10 == 1 && mod100 != 11) return 'метр';
    if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) {
      return 'метра';
    }
    return 'метров';
  }

  void dispose() {
    _enabled = false;
  }
}

class HazardHit {
  final String key;
  final String text;
  final int priority;
  final double meters;
  final bool vibeDanger;
  final bool vibePerson;

  HazardHit({
    required this.key,
    required this.text,
    required this.priority,
    required this.meters,
    required this.vibeDanger,
    required this.vibePerson,
  });
}
