// lib/navigation_service.dart
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

/// Шаг маршрута (поворот/прямо)
class RouteStep {
  final String instruction; // "Поверните направо на ул. Ленина"
  final double distanceM; // метров до следующего шага
  final double lat, lon; // координата точки поворота

  const RouteStep({
    required this.instruction,
    required this.distanceM,
    required this.lat,
    required this.lon,
  });
}

/// Сервис навигации с голосовым вводом пункта назначения.
class NavigationService {
  final FlutterTts _tts;
  final Future<void> Function(String text, {int? priority}) _enqueue;

  List<RouteStep> _steps = [];
  int _currentStepIndex = 0;
  Position? _lastPosition;
  Timer? _guideTimer;
  StreamSubscription<Position>? _positionSub; // Подписка GPS
  bool _isNavigating = false;
  String _destinationName = '';

  Map<String, String> _savedPlaces = {};
  void Function(List<LatLng>, LatLng)? onRouteReady;
  void Function(String message)? onDebugLog;

  void _log(String message) {
    debugPrint('[NAV] $message');
    onDebugLog?.call(message);
  }

  // Дистанция в метрах, при которой переходим к следующему шагу
  static const double _stepAdvanceThresholdM = 20.0;
  // Дистанция, при которой произносим подсказку заранее (предупреждение)
  static const double _preAnnounceM = 40.0;
  bool _preAnnounced = false;

  NavigationService(
    this._tts, {
    required Future<void> Function(String text, {int? priority})
    enqueueCallback,
    Map<String, String> savedPlaces = const {},
  }) : _enqueue = enqueueCallback,
       _savedPlaces = savedPlaces;

  Future<void> init() async {
    debugPrint('✅ NavigationService initialized');
  }

  bool get isNavigating => _isNavigating;
  String get destinationName => _destinationName;
  List<RouteStep> get steps => List.unmodifiable(_steps);
  int get currentStepIndex => _currentStepIndex;

  void updateSavedPlaces(Map<String, String> places) {
    _savedPlaces = places;
  }

  /// Основная точка входа: принимает голосовой запрос пользователя.
  Future<void> handleVoiceDestination(String query) async {
    _log('Услышано: "$query"');

    // ИСПРАВЛЕНИЕ: Теперь регулярное выражение чисто вырезает абсолютно все возможные префиксы,
    // чтобы они не ломали геокодер.
    String cleanQuery = query
        .toLowerCase()
        .replaceFirst(
          RegExp(
            r'^(иду в |иду на |иду |маршрут до |маршрут |построй маршрут до |построй маршрут |проложи маршрут до |проложи маршрут |поведи в |поведи на |поведи )',
          ),
          '',
        )
        .trim();

    // Если место есть в сохраненных, используем его адрес
    if (_savedPlaces.containsKey(cleanQuery)) {
      final saved = _savedPlaces[cleanQuery]!;
      _log('Сохранённое место "$cleanQuery" → "$saved"');
      cleanQuery = saved;
    } else {
      _log('Запрос после очистки: "$cleanQuery"');
    }

    await _enqueue('Ищу: $cleanQuery', priority: 1);

    final pos = await _getCurrentPosition();
    if (pos == null) {
      _log('GPS: не удалось получить координаты');
      await _enqueue('Не удалось определить местоположение.', priority: 1);
      return;
    }
    _log(
      'GPS: ${pos.latitude.toStringAsFixed(6)}, '
      '${pos.longitude.toStringAsFixed(6)}',
    );

    // Пробуем найти как POI (аптека, магазин)
    final poiTarget = await _searchPoi(cleanQuery, pos);
    if (poiTarget != null) {
      _log(
        'POI найден: "${poiTarget.$3}" '
        '(${poiTarget.$1.toStringAsFixed(6)}, ${poiTarget.$2.toStringAsFixed(6)})',
      );
      await _enqueue('Найдено: ${poiTarget.$3}. Строю маршрут.', priority: 1);
      await _buildRoute(pos, poiTarget.$1, poiTarget.$2, poiTarget.$3);
      return;
    }
    _log('POI не найден, пробую геокодирование адреса');

    // Если не нашли POI — геокодируем как адрес
    final geoTarget = await _geocodeAddress(cleanQuery, pos);
    if (geoTarget != null) {
      _log(
        'Адрес на карте: "${geoTarget.$3}" '
        '(${geoTarget.$1.toStringAsFixed(6)}, ${geoTarget.$2.toStringAsFixed(6)})',
      );
      await _enqueue('Распознан адрес: ${geoTarget.$3}.', priority: 1);
      await _buildRoute(pos, geoTarget.$1, geoTarget.$2, geoTarget.$3);
      return;
    }

    _log('Место не найдено ни как POI, ни как адрес');
    await _enqueue('Место не найдено. Уточните запрос.', priority: 1);
  }

  /// Поиск POI через Overpass API
  Future<(double lat, double lon, String name)?> _searchPoi(
    String query,
    Position origin,
  ) async {
    final poiMap = _resolvePoiTags(query);
    if (poiMap == null) return null;

    try {
      final lat = origin.latitude;
      final lon = origin.longitude;
      final overpassQuery =
          '[out:json][timeout:10];\n'
          '(\n'
          '  node$poiMap(around:2000,$lat,$lon);\n'
          '  way$poiMap(around:2000,$lat,$lon);\n'
          ');\n'
          'out center 5;\n';

      final response = await http
          .post(
            Uri.parse('https://overpass-api.de/api/interpreter'),
            body: overpassQuery,
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        _log('Overpass HTTP ${response.statusCode}');
        return null;
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final elements = json['elements'] as List? ?? [];
      if (elements.isEmpty) {
        _log('Overpass: объектов не найдено для "$query"');
        return null;
      }

      (double, double, String)? best;
      double bestDist = double.infinity;

      for (final el in elements) {
        final e = el as Map<String, dynamic>;
        double targetLat, targetLon;
        if (e['type'] == 'node') {
          targetLat = (e['lat'] as num).toDouble();
          targetLon = (e['lon'] as num).toDouble();
        } else {
          final center = e['center'] as Map<String, dynamic>?;
          if (center == null) continue;
          targetLat = (center['lat'] as num).toDouble();
          targetLon = (center['lon'] as num).toDouble();
        }

        final dist = _haversineM(lat, lon, targetLat, targetLon);
        if (dist < bestDist) {
          final tags = (e['tags'] as Map?)?.cast<String, String>() ?? {};
          final name =
              tags['name'] ?? tags['brand'] ?? tags['amenity'] ?? query;
          bestDist = dist;
          best = (targetLat, targetLon, name);
        }
      }

      if (best != null) {
        _log('Overpass: выбран "${best.$3}" (~${bestDist.round()} м)');
      }
      return best;
    } catch (e) {
      _log('Ошибка POI: $e');
      return null;
    }
  }

  /// Геокодирование адреса через Nominatim (OSM)
  Future<(double lat, double lon, String name)?> _geocodeAddress(
    String query,
    Position origin,
  ) async {
    try {
      final uri = Uri.parse('https://nominatim.openstreetmap.org/search')
          .replace(
            queryParameters: {
              'q': query,
              'format': 'json',
              'limit': '1',
              'countrycodes': 'ru',
              'viewbox':
                  '${origin.longitude - 0.1},${origin.latitude + 0.1},'
                  '${origin.longitude + 0.1},${origin.latitude - 0.1}',
              'bounded': '0',
            },
          );

      _log('Nominatim запрос: $uri');

      final response = await http
          .get(uri, headers: {'User-Agent': 'SmartGlassesApp/1.0'})
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        _log('Nominatim HTTP ${response.statusCode}');
        return null;
      }

      final list = jsonDecode(response.body) as List;
      if (list.isEmpty) {
        _log('Nominatim: результатов нет для "$query"');
        return null;
      }

      final place = list.first as Map<String, dynamic>;
      final lat = double.parse(place['lat'] as String);
      final lon = double.parse(place['lon'] as String);
      final name = place['display_name'] as String? ?? query;
      final shortName = name.split(',').first.trim();

      _log('Nominatim: "$shortName" | полный адрес: $name');
      return (lat, lon, shortName);
    } catch (e) {
      _log('Ошибка геокодирования: $e');
      return null;
    }
  }

  /// Строит маршрут через стабильный сервер OpenStreetMap Germany
  Future<void> _buildRoute(
    Position origin,
    double destLat,
    double destLon,
    String destName,
  ) async {
    try {
      _log(
        'Строю маршрут: от (${origin.latitude.toStringAsFixed(6)}, '
        '${origin.longitude.toStringAsFixed(6)}) → "$destName" '
        '(${destLat.toStringAsFixed(6)}, ${destLon.toStringAsFixed(6)})',
      );

      // routed-foot + profile foot; параметр language=ru ломает запрос (HTTP 400)
      final url =
          'https://routing.openstreetmap.de/routed-foot/route/v1/foot/'
          '${origin.longitude},${origin.latitude};'
          '$destLon,$destLat'
          '?steps=true&overview=full&geometries=geojson';

      _log('OSRM URL: $url');

      final response = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 10));

      _log('OSRM HTTP ${response.statusCode}');

      if (response.statusCode != 200) {
        _log('OSRM ответ: ${response.body}');
        await _enqueue('Ошибка построения маршрута.', priority: 1);
        return;
      }

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final code = json['code'] as String? ?? '';
      if (code != 'Ok') {
        final message = json['message'] as String? ?? 'неизвестная ошибка';
        _log('OSRM code=$code: $message');
        await _enqueue('Маршрут не найден: $message', priority: 1);
        return;
      }

      final routes = json['routes'] as List? ?? [];
      if (routes.isEmpty) {
        _log('OSRM: routes пустой');
        await _enqueue('Маршрут не найден.', priority: 1);
        return;
      }

      final route = routes.first as Map<String, dynamic>;

      // Геометрия для карты
      final geometry = route['geometry'] as Map<String, dynamic>?;
      List<LatLng> routePoints = [];
      if (geometry != null && geometry['type'] == 'LineString') {
        final coords = geometry['coordinates'] as List? ?? [];
        for (final coord in coords) {
          if (coord is List && coord.length >= 2) {
            routePoints.add(
              LatLng(
                (coord[1] as num).toDouble(),
                (coord[0] as num).toDouble(),
              ),
            );
          }
        }
      }

      _log('OSRM: ${routePoints.length} точек линии маршрута');

      onRouteReady?.call(routePoints, LatLng(destLat, destLon));

      final legs = route['legs'] as List? ?? [];
      final steps = <RouteStep>[];

      for (final leg in legs) {
        final legSteps = leg['steps'] as List? ?? [];
        for (final step in legSteps) {
          final maneuver = step['maneuver'] as Map<String, dynamic>?;
          if (maneuver == null) continue;

          final type = maneuver['type'] as String? ?? '';
          final modifier = maneuver['modifier'] as String?;
          final distanceM = (step['distance'] as num?)?.toDouble() ?? 0.0;
          final location = maneuver['location'] as List?;

          if (location == null || location.length < 2) continue;
          final stepLon = (location[0] as num).toDouble();
          final stepLat = (location[1] as num).toDouble();

          final streetName = step['name'] as String?;
          final instruction = _buildInstruction(
            type,
            modifier,
            streetName,
            distanceM,
          );

          if (instruction.isNotEmpty) {
            steps.add(
              RouteStep(
                instruction: instruction,
                distanceM: distanceM,
                lat: stepLat,
                lon: stepLon,
              ),
            );
          }
        }
      }

      if (steps.isEmpty) {
        _log('OSRM: шаги маршрута пустые (${legs.length} legs)');
        await _enqueue('Маршрут слишком короткий.', priority: 1);
        return;
      }

      final totalM = (route['distance'] as num?)?.toDouble() ?? 0.0;
      final totalMin = ((route['duration'] as num?)?.toDouble() ?? 0.0) / 60;

      _log('OSRM: ${steps.length} шагов, ${totalM.round()} м');
      _steps = steps;
      _currentStepIndex = 0;
      _destinationName = destName;
      _isNavigating = true;
      _preAnnounced = false;

      await _enqueue(
        'Маршрут построен. До $destName ${_formatDistance(totalM)}, '
        'примерно ${totalMin.round()} минут пешком. '
        '${steps.first.instruction}.',
        priority: 2,
      );

      _log('Маршрут построен успешно');
      _startGuiding();
    } catch (e) {
      _log('Ошибка построения маршрута: $e');
      await _enqueue('Ошибка маршрута: $e', priority: 1);
    }
  }

  void _startGuiding() {
    _guideTimer?.cancel();
    _positionSub?.cancel();

    _guideTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      _updateGuidance();
    });

    _positionSub =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 3,
          ),
        ).listen((pos) {
          if (!_isNavigating) return;
          _lastPosition = pos;
        });
  }

  void _updateGuidance() {
    if (!_isNavigating || _lastPosition == null) return;
    if (_currentStepIndex >= _steps.length) {
      _onArrived();
      return;
    }

    final step = _steps[_currentStepIndex];
    final userPos = _lastPosition!;
    final dist = _haversineM(
      userPos.latitude,
      userPos.longitude,
      step.lat,
      step.lon,
    );

    // Предварительное предупреждение (40 м до поворота)
    if (dist < _preAnnounceM &&
        !_preAnnounced &&
        _currentStepIndex + 1 < _steps.length) {
      _preAnnounced = true;
      final next = _steps[_currentStepIndex + 1];
      _enqueue(
        'Через ${dist.round()} метров: ${next.instruction}',
        priority: 1,
      ).catchError((_) {});
    }

    // Переход к следующему шагу
    if (dist < _stepAdvanceThresholdM) {
      _currentStepIndex++;
      _preAnnounced = false;

      if (_currentStepIndex >= _steps.length) {
        _onArrived();
      } else {
        final next = _steps[_currentStepIndex];
        _enqueue(next.instruction, priority: 2).catchError((_) {});
      }
    }
  }

  void _onArrived() {
    _isNavigating = false;
    _guideTimer?.cancel();
    _positionSub?.cancel();
    _enqueue(
      'Вы прибыли к месту назначения: $_destinationName.',
      priority: 2,
    ).catchError((_) {});
    _steps = [];
    _currentStepIndex = 0;
  }

  void stopNavigation() {
    _isNavigating = false;
    _guideTimer?.cancel();
    _positionSub?.cancel();
    _steps = [];
    _currentStepIndex = 0;
    _enqueue('Навигация остановлена.', priority: 1).catchError((_) {});
  }

  // ─── Вспомогательные методы ───────────────────────────────────────────────

  String _buildInstruction(
    String type,
    String? modifier,
    String? street,
    double distM,
  ) {
    final on = street != null && street.isNotEmpty ? ' на $street' : '';
    switch (type) {
      case 'depart':
        return 'Начните движение$on. До следующего поворота ${_formatDistance(distM)}';
      case 'turn':
        final dir = _modifierRu(modifier);
        return 'Поверните $dir$on';
      case 'new name':
        return 'Продолжайте движение$on';
      case 'merge':
        return 'Слияние$on';
      case 'on ramp':
        return 'Въезд$on';
      case 'off ramp':
        return 'Съезд$on';
      case 'roundabout':
      case 'rotary':
        return 'Въезжайте в кольцо$on';
      case 'exit roundabout':
      case 'exit rotary':
        return 'Выезжайте из кольца$on';
      case 'arrive':
        return 'Вы прибыли к цели';
      default:
        return '';
    }
  }

  String _modifierRu(String? modifier) {
    switch (modifier) {
      case 'left':
        return 'налево';
      case 'right':
        return 'направо';
      case 'slight left':
        return 'слегка налево';
      case 'slight right':
        return 'слегка направо';
      case 'sharp left':
        return 'резко налево';
      case 'sharp right':
        return 'резко направо';
      case 'straight':
        return 'прямо';
      case 'uturn':
        return 'разворот';
      default:
        return 'прямо';
    }
  }

  String _formatDistance(double meters) {
    if (meters < 1000) return '${meters.round()} метров';
    return '${(meters / 1000).toStringAsFixed(1)} км';
  }

  String? _resolvePoiTags(String query) {
    final q = query.toLowerCase();

    if (q.contains('пятёрочка') || q.contains('пятерочка')) {
      return '["brand"="Пятёрочка"]';
    }
    if (q.contains('магнит')) return '["brand"="Магнит"]';
    if (q.contains('перекрёсток') || q.contains('перекресток')) {
      return '["brand"="Перекрёсток"]';
    }
    if (q.contains('вкусвилл') || q.contains('вкус вилл')) {
      return '["brand"="ВкусВилл"]';
    }
    if (q.contains('лента')) return '["brand"="Лента"]';
    if (q.contains('ашан') || q.contains('auchan')) return '["brand"="Auchan"]';
    if (q.contains('дикси')) return '["brand"="Дикси"]';
    if (q.contains('окей') || q.contains('о\'кей')) return '["brand"="О\'КЕЙ"]';

    if (q.contains('аптека') || q.contains('фармация')) {
      return '["amenity"="pharmacy"]';
    }
    if (q.contains('больниц') ||
        q.contains('поликлиник') ||
        q.contains('клиник')) {
      return '["amenity"~"hospital|clinic"]';
    }
    if (q.contains('супермаркет') ||
        q.contains('магазин') ||
        q.contains('продукт')) {
      return '["shop"~"supermarket|convenience|grocery"]';
    }
    if (q.contains('банк')) return '["amenity"="bank"]';
    if (q.contains('банкомат') || q.contains('atm')) return '["amenity"="atm"]';
    if (q.contains('кафе') || q.contains('кофейня'))
      return '["amenity"="cafe"]';
    if (q.contains('ресторан')) return '["amenity"="restaurant"]';
    if (q.contains('автобусная остановка') || q.contains('остановка')) {
      return '["highway"="bus_stop"]';
    }
    if (q.contains('метро') || q.contains('станция метро')) {
      return '["station"="subway"]';
    }
    if (q.contains('парк')) return '["leisure"="park"]';
    if (q.contains('заправка') || q.contains('азс'))
      return '["amenity"="fuel"]';
    if (q.contains('туалет') || q.contains('wc'))
      return '["amenity"="toilets"]';
    if (q.contains('почта')) return '["amenity"="post_office"]';
    if (q.contains('школа')) return '["amenity"="school"]';
    if (q.contains('детский сад') || q.contains('детсад'))
      return '["amenity"="kindergarten"]';
    if (q.contains('рынок')) return '["amenity"="marketplace"]';

    return null;
  }

  Future<Position?> _getCurrentPosition() async {
    try {
      return await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      ).timeout(const Duration(seconds: 8));
    } catch (e) {
      debugPrint('NavigationService GPS error: $e');
      return null;
    }
  }

  double _haversineM(double lat1, double lon1, double lat2, double lon2) {
    const R = 6371000.0;
    final dLat = _rad(lat2 - lat1);
    final dLon = _rad(lon2 - lon1);
    final sinLat = sin(dLat / 2);
    final sinLon = sin(dLon / 2);
    final h =
        sinLat * sinLat + cos(_rad(lat1)) * cos(_rad(lat2)) * sinLon * sinLon;
    return 2 * R * asin(sqrt(h));
  }

  double _rad(double deg) => deg * pi / 180;

  void dispose() {
    _guideTimer?.cancel();
    _positionSub?.cancel();
    _isNavigating = false;
  }
}
