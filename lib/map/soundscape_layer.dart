import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart';

/// Soundscape-слой: стерео-якоря POI по компасу (не смешивать с turn-by-turn).
class SoundscapeLayer {
  final Future<void> Function(String text, {int? priority}) _enqueue;

  bool enabled = true;
  int _lastAnnounceMs = 0;
  static const _cooldownMs = 45000;
  static const _samePoiStationaryMs = 240000;
  double? _lastAnnounceLat;
  double? _lastAnnounceLon;
  String? _lastPoiName;
  double? _heading;

  StreamSubscription<CompassEvent>? _compassSub;
  List<SoundscapePoi> _pois = [];

  SoundscapeLayer({
    required Future<void> Function(String text, {int? priority}) enqueueCallback,
  }) : _enqueue = enqueueCallback;

  Future<void> init() async {
    try {
      _compassSub = FlutterCompass.events?.listen((e) {
        if (e.heading != null) _heading = e.heading;
      });
    } catch (e) {
      debugPrint('Soundscape compass: $e');
    }
  }

  void setPois(List<SoundscapePoi> pois) {
    _pois = pois;
  }

  /// Вызывать из GPS-тика рядом с MapAwareness.
  void onLocation(Position pos) {
    if (!enabled || _pois.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastAnnounceMs < _cooldownMs) return;

    final heading = _heading ?? 0;
    SoundscapePoi? best;
    double bestScore = 999;
    String? side;

    for (final p in _pois) {
      final dist = Geolocator.distanceBetween(
        pos.latitude,
        pos.longitude,
        p.lat,
        p.lon,
      );
      if (dist < 25 || dist > 120) continue;
      final bearing = Geolocator.bearingBetween(
        pos.latitude,
        pos.longitude,
        p.lat,
        p.lon,
      );
      final rel = _normalizeAngle(bearing - heading);
      // Предпочитаем боковые якоря (±30–120°)
      final absRel = rel.abs();
      if (absRel < 25 || absRel > 140) continue;
      final score = dist / 50 + (absRel > 90 ? 0.5 : 0);
      if (score < bestScore) {
        bestScore = score;
        best = p;
        side = rel < 0 ? 'слева' : 'справа';
      }
    }

    if (best == null || side == null) return;

    // Та же остановка, пока сидишь — не повторять.
    if (_lastPoiName == best.name &&
        _lastAnnounceLat != null &&
        now - _lastAnnounceMs < _samePoiStationaryMs) {
      final moved = Geolocator.distanceBetween(
        _lastAnnounceLat!,
        _lastAnnounceLon!,
        pos.latitude,
        pos.longitude,
      );
      if (moved < 28) return;
    }

    _lastAnnounceMs = now;
    _lastPoiName = best.name;
    _lastAnnounceLat = pos.latitude;
    _lastAnnounceLon = pos.longitude;
    _enqueue('${best.name} $side.', priority: 1);
  }

  double _normalizeAngle(double deg) {
    var a = deg % 360;
    if (a > 180) a -= 360;
    if (a < -180) a += 360;
    return a;
  }

  void dispose() {
    _compassSub?.cancel();
  }
}

class SoundscapePoi {
  final String name;
  final double lat;
  final double lon;
  SoundscapePoi(this.name, this.lat, this.lon);
}
