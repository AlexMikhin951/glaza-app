import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

class OsmWay {
  final List<LatLng2> points;
  final Map<String, String> tags;
  OsmWay(this.points, this.tags);
}

class LatLng2 {
  final double lat, lon;
  const LatLng2(this.lat, this.lon);
}

/// Сервис карты: получает позицию GPS, загружает дороги из Overpass API
/// и голосом предупреждает о препятствиях рядом.
///
/// ИСПРАВЛЕНИЕ Проблемы 1: вместо прямого tts.speak() используется
/// [_enqueue] — колбэк, ведущий в приоритетную очередь SmartGlassesServices.
/// Это исключает перебивание голосовых сообщений от других сервисов.
class MapAwarenessService {
  final FlutterTts _tts; // оставлен для совместимости, не используется напрямую
  final Future<void> Function(String text, {int priority}) _enqueue;

  List<OsmWay> _nearbyWays = [];
  Position? _lastPosition;
  double _lastHeading = 0.0;

  bool _enabled = false;
  Timer? _checkTimer;
  Timer? _reloadTimer;

  int _lastAlertTime = 0;
  static const int _alertCooldownMs = 4000;

  static const double _loadRadiusM = 150;
  static const double _alertRadiusM = 12;

  MapAwarenessService(
    this._tts, {
    required Future<void> Function(String text, {int priority}) enqueueCallback,
  }) : _enqueue = enqueueCallback;

  Future<void> init() async {
    try {
      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      debugPrint('✅ MapAwarenessService initialized, perm=$perm');
    } catch (e) {
      debugPrint('⚠️ MapAwarenessService init error: $e');
    }
  }

  void enable() {
    _enabled = true;
    _startTracking();
  }

  void disable() {
    _enabled = false;
    _checkTimer?.cancel();
    _reloadTimer?.cancel();
    _checkTimer = null;
    _reloadTimer = null;
  }

  bool get isEnabled => _enabled;

  void _startTracking() {
    Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 3,
      ),
    ).listen((pos) {
      if (!_enabled) return;
      _lastPosition = pos;
      _lastHeading = pos.heading;
    });

    _checkTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_enabled && _lastPosition != null) {
        _checkSurroundings();
      }
    });

    _reloadTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (_enabled && _lastPosition != null) {
        _loadNearbyWays(_lastPosition!);
      }
    });

    Geolocator.getCurrentPosition()
        .then((pos) {
          _lastPosition = pos;
          _loadNearbyWays(pos);
        })
        .catchError((e) => debugPrint('GPS error: $e'));
  }

  Future<void> _loadNearbyWays(Position pos) async {
    try {
      final lat = pos.latitude;
      final lon = pos.longitude;
      final d = _loadRadiusM / 111000;

      final bbox = '${lat - d},${lon - d},${lat + d},${lon + d}';
      final query =
          '[out:json][timeout:10];\n'
          '(\n'
          '  way["highway"~"^(footway|path|pedestrian|crossing|steps|'
          'primary|secondary|tertiary|residential|service)\$"]'
          '($bbox);\n'
          ');\n'
          'out body;\n'
          '>;\n'
          'out skel qt;\n';

      final response = await http
          .post(
            Uri.parse('https://overpass-api.de/api/interpreter'),
            body: query,
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        _parseOsmResponse(json);
        debugPrint(
          '✅ OSM loaded ${_nearbyWays.length} ways around ($lat,$lon)',
        );
      }
    } catch (e) {
      debugPrint('⚠️ OSM load error: $e');
    }
  }

  void _parseOsmResponse(Map<String, dynamic> json) {
    final elements = json['elements'] as List? ?? [];

    final nodes = <int, LatLng2>{};
    for (final el in elements) {
      if (el['type'] == 'node') {
        nodes[el['id'] as int] = LatLng2(
          (el['lat'] as num).toDouble(),
          (el['lon'] as num).toDouble(),
        );
      }
    }

    final ways = <OsmWay>[];
    for (final el in elements) {
      if (el['type'] == 'way') {
        final nodeIds = (el['nd'] as List? ?? []).cast<int>();
        final tags = ((el['tags'] as Map?) ?? {}).cast<String, String>();
        final points = nodeIds
            .map((id) => nodes[id])
            .whereType<LatLng2>()
            .toList();
        if (points.length >= 2) {
          ways.add(OsmWay(points, tags));
        }
      }
    }

    _nearbyWays = ways;
  }

  void _checkSurroundings() {
    if (_lastPosition == null) return;
    final pos = LatLng2(_lastPosition!.latitude, _lastPosition!.longitude);
    final heading = _lastHeading;
    final alerts = <({String text, int priority})>[];

    for (final way in _nearbyWays) {
      final dist = _distanceToWay(pos, way);
      if (dist > _alertRadiusM * 2) continue;

      final side = _whichSide(pos, heading, way);
      final highway = way.tags['highway'] ?? '';

      if (highway == 'crossing' && dist < _alertRadiusM) {
        final signals = way.tags['crossing:signals'] == 'yes'
            ? ' со светофором'
            : '';
        // Перекрёсток — приоритет 2
        alerts.add((
          text: 'Пешеходный переход$signals через ${dist.round()} метров',
          priority: 2,
        ));
      } else if (highway == 'steps' && dist < _alertRadiusM) {
        alerts.add((text: 'Впереди лестница', priority: 1));
      } else if (_isRoad(highway) && dist < 8) {
        if (side == 'right') {
          // Дорога — приоритет 2 (опасность)
          alerts.add((text: 'Внимание, дорога справа', priority: 2));
        } else if (side == 'left') {
          alerts.add((text: 'Осторожно, дорога слева', priority: 2));
        }
      }
    }

    if (alerts.isNotEmpty) {
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastAlertTime > _alertCooldownMs) {
        _lastAlertTime = now;
        // Передаём в очередь с приоритетом вместо прямого tts.speak()
        _enqueue(alerts.first.text, priority: alerts.first.priority)
            .catchError((_) {});
      }
    }
  }

  bool _isRoad(String highway) => const {
    'primary',
    'secondary',
    'tertiary',
    'residential',
    'service',
    'unclassified',
  }.contains(highway);

  double _distanceToWay(LatLng2 pos, OsmWay way) {
    double minDist = double.infinity;
    for (int i = 0; i < way.points.length - 1; i++) {
      final d = _pointToSegmentDist(pos, way.points[i], way.points[i + 1]);
      if (d < minDist) minDist = d;
    }
    return minDist;
  }

  double _pointToSegmentDist(LatLng2 p, LatLng2 a, LatLng2 b) {
    final dx = b.lat - a.lat;
    final dy = b.lon - a.lon;
    if (dx == 0 && dy == 0) return _haversineM(p, a);
    final t =
        ((p.lat - a.lat) * dx + (p.lon - a.lon) * dy) / (dx * dx + dy * dy);
    final tc = t.clamp(0.0, 1.0);
    final closest = LatLng2(a.lat + tc * dx, a.lon + tc * dy);
    return _haversineM(p, closest);
  }

  double _haversineM(LatLng2 a, LatLng2 b) {
    const R = 6371000.0;
    final dLat = _rad(b.lat - a.lat);
    final dLon = _rad(b.lon - a.lon);
    final sinLat = sin(dLat / 2);
    final sinLon = sin(dLon / 2);
    final h =
        sinLat * sinLat + cos(_rad(a.lat)) * cos(_rad(b.lat)) * sinLon * sinLon;
    return 2 * R * asin(sqrt(h));
  }

  double _rad(double deg) => deg * pi / 180;

  String _whichSide(LatLng2 pos, double headingDeg, OsmWay way) {
    LatLng2? nearest;
    double minDist = double.infinity;
    for (final pt in way.points) {
      final d = _haversineM(pos, pt);
      if (d < minDist) {
        minDist = d;
        nearest = pt;
      }
    }
    if (nearest == null) return 'ahead';

    final dLat = nearest.lat - pos.lat;
    final dLon = nearest.lon - pos.lon;
    final bearingRad = atan2(dLon, dLat);
    final bearingDeg = (bearingRad * 180 / pi + 360) % 360;

    final rel = (bearingDeg - headingDeg + 360) % 360;

    if (rel < 45 || rel > 315) return 'ahead';
    if (rel >= 45 && rel < 180) return 'right';
    return 'left';
  }

  void dispose() {
    disable();
  }
}
