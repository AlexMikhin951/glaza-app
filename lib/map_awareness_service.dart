import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:yandex_maps_mapkit/mapkit.dart' show Point, Geometry;
import 'package:yandex_maps_mapkit/search.dart';

class OsmFeature {
  final List<LatLng2> points;
  final Map<String, String> tags;
  final String kind; // crossing | steps | bus_stop | road | other
  OsmFeature(this.points, this.tags, this.kind);

  bool get isPoint => points.length == 1;
}

class LatLng2 {
  final double lat, lon;
  const LatLng2(this.lat, this.lon);
}

/// Картографическая осведомлённость:
/// - OSM Overpass: переходы, лестницы, остановки, дороги
/// - Яндекс MapKit Search: остановки ОТ (в РФ обычно полнее OSM)
class MapAwarenessService {
  final FlutterTts _tts;
  final Future<void> Function(String text, {int priority}) _enqueue;

  List<OsmFeature> _features = [];
  Position? _lastPosition;
  double _lastHeading = 0.0;

  bool _enabled = false;
  Timer? _checkTimer;
  Timer? _reloadTimer;
  StreamSubscription<Position>? _posSub;

  int _lastAlertTime = 0;
  String _lastAlertKey = '';
  double? _lastAlertLat;
  double? _lastAlertLon;
  /// Пока стоишь на месте — не долбить одно и то же (остановка/дорога).
  static const int _alertCooldownMs = 20000;
  static const int _sameAlertStationaryMs = 300000; // 5 мин
  static const double _sameAlertMoveM = 28;

  static const double _loadRadiusM = 220;
  static const double _alertCrossingM = 22;
  static const double _alertStepsM = 18;
  static const double _alertStopM = 25;
  static const double _alertRoadM = 8;
  static const double _alertHazardM = 12;

  SearchManager? _yandexSearch;
  SearchSession? _yandexSession;
  bool _yandexSearchOk = true;

  MapAwarenessService(
    this._tts, {
    required Future<void> Function(String text, {int priority}) enqueueCallback,
  }) : _enqueue = enqueueCallback;

  List<OsmFeature> get features => List.unmodifiable(_features);

  /// POI для Soundscape (остановки и т.п.).
  List<({String name, double lat, double lon})> soundscapePois() {
    final out = <({String name, double lat, double lon})>[];
    for (final f in _features) {
      if (f.kind != 'bus_stop' &&
          f.kind != 'bus_stop_yandex' &&
          f.kind != 'crossing') {
        continue;
      }
      if (f.points.isEmpty) continue;
      final name = f.tags['name'];
      final label = (name != null && name.isNotEmpty)
          ? name
          : (f.kind.startsWith('bus') ? 'Остановка' : 'Переход');
      out.add((
        name: label,
        lat: f.points.first.lat,
        lon: f.points.first.lon,
      ));
    }
    return out;
  }

  Future<void> init() async {
    try {
      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      try {
        _yandexSearch = SearchFactory.instance.createSearchManager(
          SearchManagerType.Online,
        );
        debugPrint('✅ MapAwareness: Yandex Search ready');
      } catch (e) {
        _yandexSearchOk = false;
        debugPrint('⚠️ Yandex Search unavailable: $e');
      }
      debugPrint('✅ MapAwarenessService initialized, perm=$perm');
    } catch (e) {
      debugPrint('⚠️ MapAwarenessService init error: $e');
    }
  }

  void enable() {
    if (_enabled) return;
    _enabled = true;
    _startTracking();
  }

  void disable() {
    _enabled = false;
    _checkTimer?.cancel();
    _reloadTimer?.cancel();
    _posSub?.cancel();
    _checkTimer = null;
    _reloadTimer = null;
    _posSub = null;
    _yandexSession?.cancel();
    _yandexSession = null;
  }

  bool get isEnabled => _enabled;

  void _startTracking() {
    _posSub?.cancel();
    _posSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 3,
      ),
    ).listen((pos) {
      if (!_enabled) return;
      _lastPosition = pos;
      if (pos.heading >= 0) _lastHeading = pos.heading;
    });

    _checkTimer?.cancel();
    _checkTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      if (_enabled && _lastPosition != null) {
        _checkSurroundings();
      }
    });

    _reloadTimer?.cancel();
    _reloadTimer = Timer.periodic(const Duration(seconds: 25), (_) {
      if (_enabled && _lastPosition != null) {
        _reloadNearby(_lastPosition!);
      }
    });

    Geolocator.getCurrentPosition()
        .then((pos) {
          _lastPosition = pos;
          _reloadNearby(pos);
        })
        .catchError((e) => debugPrint('GPS error: $e'));
  }

  Future<void> _reloadNearby(Position pos) async {
    await Future.wait([
      _loadOsm(pos),
      _loadYandexStops(pos),
    ]);
  }

  /// OSM: ways + nodes для переходов, лестниц, остановок.
  Future<void> _loadOsm(Position pos) async {
    try {
      final lat = pos.latitude;
      final lon = pos.longitude;
      final d = _loadRadiusM / 111000;
      final bbox = '${lat - d},${lon - d},${lat + d},${lon + d}';

      final query =
          '[out:json][timeout:12];\n'
          '(\n'
          // Дороги и пешеходка
          '  way["highway"~"^(footway|path|pedestrian|crossing|steps|'
          'primary|secondary|tertiary|residential|service|unclassified)\$"]'
          '($bbox);\n'
          // Переходы / лестницы как точки
          '  node["highway"="crossing"]($bbox);\n'
          '  node["highway"="steps"]($bbox);\n'
          '  node["crossing"]($bbox);\n'
          // Опасности для пешехода
          '  node["barrier"~"^(kerb|stile|turnstile|cycle_barrier)\$"]($bbox);\n'
          '  node["kerb"]($bbox);\n'
          '  node["hazard"]($bbox);\n'
          '  node["obstacle"]($bbox);\n'
          '  way["barrier"="kerb"]($bbox);\n'
          '  way["hazard"]($bbox);\n'
          // Остановки
          '  node["highway"="bus_stop"]($bbox);\n'
          '  node["public_transport"="platform"]($bbox);\n'
          '  node["public_transport"="stop_position"]($bbox);\n'
          '  node["railway"="tram_stop"]($bbox);\n'
          '  node["amenity"="bus_station"]($bbox);\n'
          '  way["highway"="steps"]($bbox);\n'
          '  way["public_transport"="platform"]($bbox);\n'
          ');\n'
          'out body;\n'
          '>;\n'
          'out skel qt;\n';

      final response = await http
          .post(
            Uri.parse('https://overpass-api.de/api/interpreter'),
            body: query,
          )
          .timeout(const Duration(seconds: 12));

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        _mergeOsmFeatures(_parseOsmResponse(json));
        debugPrint(
          '✅ OSM features=${_features.length} around ($lat,$lon)',
        );
      }
    } catch (e) {
      debugPrint('⚠️ OSM load error: $e');
    }
  }

  /// Яндекс MapKit: поиск «остановка» рядом — в городах РФ обычно точнее OSM.
  Future<void> _loadYandexStops(Position pos) async {
    if (!_yandexSearchOk || _yandexSearch == null) return;

    final completer = Completer<void>();
    try {
      final point = Point(latitude: pos.latitude, longitude: pos.longitude);
      _yandexSession?.cancel();
      _yandexSession = _yandexSearch!.submit(
        Geometry.fromPoint(point),
        SearchOptions(
          searchTypes: SearchType.Biz,
          resultPageSize: 20,
          userPosition: point,
          geometry: true,
        ),
        SearchSessionSearchListener(
          onSearchResponse: (response) {
            try {
              final added = <OsmFeature>[];
              _collectYandexStops(response.collection, added);
              if (added.isNotEmpty) {
                _mergeFeaturesByKind(added, replaceKind: 'bus_stop_yandex');
                debugPrint('✅ Yandex stops: ${added.length}');
              }
            } catch (e) {
              debugPrint('⚠️ Yandex parse error: $e');
            }
            if (!completer.isCompleted) completer.complete();
          },
          onSearchError: (error) {
            debugPrint('⚠️ Yandex Search error: $error');
            if (!completer.isCompleted) completer.complete();
          },
        ),
        text: 'остановка общественного транспорта',
      );

      await completer.future.timeout(
        const Duration(seconds: 8),
        onTimeout: () {},
      );
    } catch (e) {
      debugPrint('⚠️ Yandex Search submit failed: $e');
      // Не отключаем навсегда — сеть могла моргнуть.
    }
  }

  void _collectYandexStops(
    dynamic collection,
    List<OsmFeature> out, {
    int depth = 0,
  }) {
    if (depth > 4) return;
    final children = collection.children as List;
    for (final child in children) {
      final obj = child.asGeoObject();
      if (obj != null) {
        final name = (obj.name ?? '').toLowerCase();
        final desc = (obj.descriptionText ?? '').toLowerCase();
        final blob = '$name $desc';
        final looksLikeStop = blob.contains('останов') ||
            blob.contains('bus') ||
            blob.contains('трамва') ||
            blob.contains('троллей') ||
            blob.contains('метро') ||
            blob.contains('station') ||
            blob.contains('stop');
        if (!looksLikeStop && name.isEmpty) continue;

        LatLng2? pt;
        for (final g in obj.geometry) {
          final p = g.asPoint();
          if (p != null) {
            pt = LatLng2(p.latitude, p.longitude);
            break;
          }
        }
        if (pt == null && obj.boundingBox != null) {
          final bb = obj.boundingBox!;
          pt = LatLng2(
            (bb.southWest.latitude + bb.northEast.latitude) / 2,
            (bb.southWest.longitude + bb.northEast.longitude) / 2,
          );
        }
        if (pt == null) continue;

        out.add(
          OsmFeature(
            [pt],
            {
              'name': obj.name ?? 'Остановка',
              'source': 'yandex',
            },
            'bus_stop_yandex',
          ),
        );
      }
      final nested = child.asGeoObjectCollection();
      if (nested != null) {
        _collectYandexStops(nested, out, depth: depth + 1);
      }
    }
  }

  List<OsmFeature> _parseOsmResponse(Map<String, dynamic> json) {
    final elements = json['elements'] as List? ?? [];
    final nodes = <int, LatLng2>{};
    final nodeTags = <int, Map<String, String>>{};

    for (final el in elements) {
      if (el['type'] == 'node') {
        final id = el['id'] as int;
        nodes[id] = LatLng2(
          (el['lat'] as num).toDouble(),
          (el['lon'] as num).toDouble(),
        );
        final tags = ((el['tags'] as Map?) ?? {}).cast<String, String>();
        if (tags.isNotEmpty) nodeTags[id] = tags;
      }
    }

    final features = <OsmFeature>[];

    // Point features from tagged nodes
    for (final entry in nodeTags.entries) {
      final kind = _classifyTags(entry.value);
      if (kind == 'other' || kind == 'road') continue;
      final pt = nodes[entry.key];
      if (pt == null) continue;
      features.add(OsmFeature([pt], entry.value, kind));
    }

    // Ways
    for (final el in elements) {
      if (el['type'] != 'way') continue;
      final nodeIds = (el['nd'] as List? ?? []).cast<int>();
      final tags = ((el['tags'] as Map?) ?? {}).cast<String, String>();
      final points =
          nodeIds.map((id) => nodes[id]).whereType<LatLng2>().toList();
      if (points.length < 2) continue;
      features.add(OsmFeature(points, tags, _classifyTags(tags)));
    }

    return features;
  }

  String _classifyTags(Map<String, String> tags) {
    final highway = tags['highway'] ?? '';
    final pt = tags['public_transport'] ?? '';
    final railway = tags['railway'] ?? '';
    final amenity = tags['amenity'] ?? '';

    if (highway == 'bus_stop' ||
        pt == 'platform' ||
        pt == 'stop_position' ||
        railway == 'tram_stop' ||
        amenity == 'bus_station') {
      return 'bus_stop';
    }
    if (highway == 'crossing' || tags.containsKey('crossing')) {
      return 'crossing';
    }
    if (highway == 'steps') return 'steps';
    final barrier = tags['barrier'] ?? '';
    if (barrier == 'kerb' ||
        tags.containsKey('kerb') ||
        tags.containsKey('hazard') ||
        tags.containsKey('obstacle') ||
        barrier == 'stile' ||
        barrier == 'cycle_barrier') {
      return 'hazard';
    }
    if (_isRoad(highway)) return 'road';
    if (highway == 'footway' ||
        highway == 'path' ||
        highway == 'pedestrian') {
      // footway + crossing=yes часто размечают зебру
      if (tags['footway'] == 'crossing' || tags['crossing'] != null) {
        return 'crossing';
      }
    }
    return 'other';
  }

  void _mergeOsmFeatures(List<OsmFeature> osm) {
    // Убираем старые OSM (не яндекс), добавляем новые
    _features.removeWhere((f) => f.tags['source'] != 'yandex');
    _features.addAll(osm);
  }

  void _mergeFeaturesByKind(
    List<OsmFeature> incoming, {
    required String replaceKind,
  }) {
    _features.removeWhere((f) => f.kind == replaceKind);
    _features.addAll(incoming);
  }

  void _checkSurroundings() {
    if (_lastPosition == null) return;
    final pos = LatLng2(_lastPosition!.latitude, _lastPosition!.longitude);
    final heading = _lastHeading;
    final alerts = <({String text, int priority, String key})>[];

    for (final f in _features) {
      final dist = _distanceToFeature(pos, f);
      final side = _whichSide(pos, heading, f);
      final sideRu = switch (side) {
        'left' => 'слева',
        'right' => 'справа',
        _ => 'впереди',
      };

      switch (f.kind) {
        case 'crossing':
          if (dist <= _alertCrossingM &&
              (side == 'ahead' || dist < 10)) {
            final signals = f.tags['crossing:signals'] == 'yes'
                ? ' со светофором'
                : '';
            alerts.add((
              text:
                  'Пешеходный переход$signals $sideRu, ${dist.round()} метров',
              priority: 2,
              key: 'crossing_${sideRu}',
            ));
          }
        case 'steps':
          if (dist <= _alertStepsM &&
              (side == 'ahead' || dist < 10)) {
            alerts.add((
              text:
                  'Впереди лестница, ${dist.round()} метров. Будьте осторожны.',
              priority: dist < 8 ? 2 : 1,
              key: 'steps_ahead',
            ));
          }
        case 'hazard':
          if (dist <= _alertHazardM &&
              (side == 'ahead' || dist < 6)) {
            final what = f.tags['barrier'] == 'kerb'
                ? 'бордюр'
                : (f.tags.containsKey('hazard')
                    ? 'опасность на пути'
                    : 'препятствие');
            alerts.add((
              text: '$what $sideRu, ${dist.round()} метров',
              priority: 2,
              key: 'hazard_$what',
            ));
          }
        case 'bus_stop':
        case 'bus_stop_yandex':
          if (dist <= _alertStopM) {
            final name = f.tags['name'];
            final label = (name != null && name.isNotEmpty)
                ? 'Остановка «$name»'
                : 'Остановка транспорта';
            alerts.add((
              text: '$label $sideRu, ${dist.round()} метров',
              priority: 1,
              key: 'stop_${name ?? f.kind}',
            ));
          }
        case 'road':
          if (dist < _alertRoadM) {
            if (side == 'right') {
              alerts.add((
                text: 'Внимание, дорога справа',
                priority: 2,
                key: 'road_right',
              ));
            } else if (side == 'left') {
              alerts.add((
                text: 'Осторожно, дорога слева',
                priority: 2,
                key: 'road_left',
              ));
            }
          }
      }
    }

    if (alerts.isEmpty) return;
    alerts.sort((a, b) => b.priority.compareTo(a.priority));
    final best = alerts.first;

    final now = DateTime.now().millisecondsSinceEpoch;
    final movedM = (_lastAlertLat != null && _lastPosition != null)
        ? _haversineM(
            LatLng2(_lastAlertLat!, _lastAlertLon!),
            LatLng2(_lastPosition!.latitude, _lastPosition!.longitude),
          )
        : double.infinity;

    // Та же фраза (остановка/дорога), пока почти не сдвинулись — молчим до 5 мин.
    if (best.key == _lastAlertKey &&
        movedM < _sameAlertMoveM &&
        now - _lastAlertTime < _sameAlertStationaryMs) {
      return;
    }
    if (now - _lastAlertTime < _alertCooldownMs && best.priority < 2) {
      return;
    }

    _lastAlertTime = now;
    _lastAlertKey = best.key;
    _lastAlertLat = _lastPosition?.latitude;
    _lastAlertLon = _lastPosition?.longitude;
    _enqueue(best.text, priority: best.priority).catchError((_) {});
  }

  bool _isRoad(String highway) => const {
    'primary',
    'secondary',
    'tertiary',
    'residential',
    'service',
    'unclassified',
  }.contains(highway);

  double _distanceToFeature(LatLng2 pos, OsmFeature f) {
    if (f.points.isEmpty) return double.infinity;
    if (f.isPoint) return _haversineM(pos, f.points.first);
    double minDist = double.infinity;
    for (int i = 0; i < f.points.length - 1; i++) {
      final d = _pointToSegmentDist(pos, f.points[i], f.points[i + 1]);
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

  String _whichSide(LatLng2 pos, double headingDeg, OsmFeature f) {
    LatLng2? nearest;
    double minDist = double.infinity;
    for (final pt in f.points) {
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
