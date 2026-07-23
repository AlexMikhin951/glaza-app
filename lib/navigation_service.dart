// lib/navigation_service.dart
//
// Основной роутинг — Yandex MapKit (тот же ключ, что в initMapkit):
//   PedestrianRouter + MasstransitRouter.
// Fallback — OSRM foot + оценка ОТ по остановкам OSM.
// Пользователю озвучиваются до 3 самых быстрых вариантов; выбор 1/2/3
// прерывает озвучку остальных.
//
import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:yandex_maps_mapkit/mapkit.dart'
    show Point, Geometry, RequestPoint, RequestPointType;
import 'package:yandex_maps_mapkit/search.dart';
import 'package:yandex_maps_mapkit/transport.dart';

/// Шаг маршрута (поворот/прямо)
class RouteStep {
  final String instruction;
  final double distanceM;
  final double lat, lon;

  const RouteStep({
    required this.instruction,
    required this.distanceM,
    required this.lat,
    required this.lon,
  });
}

enum RouteKind { walk, transit }

/// Вариант маршрута для голосового выбора.
class RouteOption {
  final int index; // 1-based
  final RouteKind kind;
  final String title;
  final String summarySpeak;
  final double durationMin;
  final double distanceM;
  final List<RouteStep> steps;
  final List<LatLng> points;
  final double destLat;
  final double destLon;
  final String destName;
  /// Номера маршрутов ОТ, если известны.
  final List<String> transitLines;

  const RouteOption({
    required this.index,
    required this.kind,
    required this.title,
    required this.summarySpeak,
    required this.durationMin,
    required this.distanceM,
    required this.steps,
    required this.points,
    required this.destLat,
    required this.destLon,
    required this.destName,
    this.transitLines = const [],
  });
}

/// Сервис навигации с голосовым вводом пункта назначения.
class NavigationService {
  final FlutterTts _tts;
  final Future<void> Function(String text, {int? priority}) _enqueue;
  final Future<void> Function()? _interruptTts;
  final Future<void> Function(String text, {int? priority})? _speakAndWait;
  final void Function(bool focus)? _onNavFocus;

  List<RouteStep> _steps = [];
  List<LatLng> _routePoints = [];
  int _currentStepIndex = 0;
  Position? _lastPosition;
  Timer? _guideTimer;
  StreamSubscription<Position>? _positionSub;
  bool _isNavigating = false;
  String _destinationName = '';
  double _destLat = 0;
  double _destLon = 0;
  int _lastRerouteMs = 0;
  bool _rerouting = false;
  static const double _offRouteM = 40.0;
  static const int _rerouteCooldownMs = 20000;

  Map<String, String> _savedPlaces = {};
  void Function(List<LatLng>, LatLng)? onRouteReady;
  void Function(String message)? onDebugLog;
  /// Вызывается, когда ждём ответ «один/два/три».
  void Function(bool awaiting)? onAwaitingRouteChoice;
  /// После озвучки вариантов — можно включать микрофон.
  void Function()? onReadyForRouteChoiceListen;

  SearchManager? _yandexSearch;
  SearchSession? _yandexSession;

  PedestrianRouter? _pedestrianRouter;
  MasstransitRouter? _masstransitRouter;
  MasstransitSession? _pedSession;
  MasstransitSession? _mtSession;

  List<RouteOption> _pendingOptions = [];
  bool _awaitingRouteChoice = false;
  bool _announceCancelled = false;
  /// Инкремент при отмене — обрывает незавершённый поиск маршрута.
  int _searchGen = 0;

  void _log(String message) {
    debugPrint('[NAV] $message');
    onDebugLog?.call(message);
  }

  static const double _stepAdvanceThresholdM = 20.0;
  static const double _preAnnounceM = 40.0;
  bool _preAnnounced = false;
  String _lastGuideSpoken = '';
  int _lastGuideSpokenMs = 0;

  NavigationService(
    this._tts, {
    required Future<void> Function(String text, {int? priority})
    enqueueCallback,
    Future<void> Function()? interruptTts,
    Future<void> Function(String text, {int? priority})? speakAndWait,
    Map<String, String> savedPlaces = const {},
    void Function(bool focus)? onNavFocus,
  }) : _enqueue = enqueueCallback,
       _interruptTts = interruptTts,
       _speakAndWait = speakAndWait,
       _savedPlaces = savedPlaces,
       _onNavFocus = onNavFocus;

  Future<void> init() async {
    try {
      _yandexSearch = SearchFactory.instance.createSearchManager(
        SearchManagerType.Online,
      );
      debugPrint('✅ NavigationService: Yandex Search ready');
    } catch (e) {
      debugPrint('⚠️ NavigationService: Yandex Search unavailable: $e');
    }
    try {
      _pedestrianRouter = TransportFactory.instance.createPedestrianRouter();
      _masstransitRouter = TransportFactory.instance.createMasstransitRouter();
      debugPrint('✅ NavigationService: Pedestrian + Masstransit routers ready');
    } catch (e) {
      debugPrint(
        '⚠️ NavigationService: MapKit routers unavailable (нужен full MapKit ключ): $e',
      );
    }
  }

  bool get isNavigating => _isNavigating;
  bool get awaitingRouteChoice => _awaitingRouteChoice;
  String get destinationName => _destinationName;
  List<RouteStep> get steps => List.unmodifiable(_steps);
  List<RouteOption> get pendingOptions => List.unmodifiable(_pendingOptions);
  int get currentStepIndex => _currentStepIndex;

  void updateSavedPlaces(Map<String, String> places) {
    _savedPlaces = places;
  }

  Future<void> _say(String text, {int priority = 1}) async {
    final wait = _speakAndWait;
    if (wait != null) {
      await wait(text, priority: priority);
    } else {
      await _enqueue(text, priority: priority);
    }
  }

  Future<void> _interrupt() async {
    if (_interruptTts != null) {
      await _interruptTts!();
    }
  }

  /// Основная точка входа: принимает голосовой запрос пользователя.
  Future<void> handleVoiceDestination(String query) async {
    _log('Услышано: "$query"');
    _clearPendingChoice(silent: true);
    final gen = ++_searchGen;

    String cleanQuery = query
        .toLowerCase()
        .replaceFirst(
          RegExp(
            r'^(иду в |иду на |иду |маршрут до |маршрут |построй маршрут до |построй маршрут |проложи маршрут до |проложи маршрут |поведи в |поведи на |поведи )',
          ),
          '',
        )
        .trim();

    if (_savedPlaces.containsKey(cleanQuery)) {
      final saved = _savedPlaces[cleanQuery]!;
      _log('Сохранённое место "$cleanQuery" → "$saved"');
      cleanQuery = saved;
    } else {
      _log('Запрос после очистки: "$cleanQuery"');
    }

    await _enqueue('Ищу: $cleanQuery', priority: 1);
    if (gen != _searchGen) return;

    final pos = await _getCurrentPosition();
    if (gen != _searchGen) return;
    if (pos == null) {
      _log('GPS: не удалось получить координаты');
      await _enqueue('Не удалось определить местоположение.', priority: 1);
      return;
    }
    _log(
      'GPS: ${pos.latitude.toStringAsFixed(6)}, '
      '${pos.longitude.toStringAsFixed(6)}',
    );

    final yandexTarget = await _searchYandex(cleanQuery, pos);
    if (gen != _searchGen) return;
    if (yandexTarget != null) {
      _log('Yandex: "${yandexTarget.$3}"');
      await _enqueue('Найдено: ${yandexTarget.$3}. Ищу варианты маршрута.', priority: 1);
      if (gen != _searchGen) return;
      await _offerRouteOptions(pos, yandexTarget.$1, yandexTarget.$2, yandexTarget.$3, gen: gen);
      return;
    }
    _log('Yandex Search: ничего не найдено, пробую OSM fallback');

    final poiTarget = await _searchPoi(cleanQuery, pos);
    if (gen != _searchGen) return;
    if (poiTarget != null) {
      await _enqueue('Найдено: ${poiTarget.$3}. Ищу варианты маршрута.', priority: 1);
      if (gen != _searchGen) return;
      await _offerRouteOptions(pos, poiTarget.$1, poiTarget.$2, poiTarget.$3, gen: gen);
      return;
    }

    final geoTarget = await _geocodeAddress(cleanQuery, pos);
    if (gen != _searchGen) return;
    if (geoTarget != null) {
      await _enqueue('Распознан адрес: ${geoTarget.$3}.', priority: 1);
      if (gen != _searchGen) return;
      await _offerRouteOptions(pos, geoTarget.$1, geoTarget.$2, geoTarget.$3, gen: gen);
      return;
    }

    await _enqueue('Место не найдено. Уточните запрос.', priority: 1);
  }

  /// Строит пеший + ОТ варианты (Yandex MapKit) и озвучивает выбор.
  Future<void> _offerRouteOptions(
    Position origin,
    double destLat,
    double destLon,
    String destName, {
    int? gen,
  }) async {
    final myGen = gen ?? _searchGen;
    final options = <RouteOption>[];

    // 1) Yandex Pedestrian + Masstransit (тот же API-ключ MapKit).
    final yandexOpts = await _fetchYandexRouteOptions(
      origin,
      destLat,
      destLon,
      destName,
    );
    if (myGen != _searchGen) return;
    options.addAll(yandexOpts);

    // 2) Fallback: OSRM + оценка ОТ, если Яндекс ничего не дал.
    if (options.isEmpty) {
      _log('Yandex routes пусто — fallback OSRM');
      final walk = await _fetchOsrmFoot(origin, destLat, destLon, destName);
      if (myGen != _searchGen) return;
      if (walk != null) options.add(walk);

      final transit = await _estimateTransitOption(
        origin,
        destLat,
        destLon,
        destName,
        walkDurationMin: walk?.durationMin,
      );
      if (myGen != _searchGen) return;
      if (transit != null) options.add(transit);

      final altWalk = await _fetchOsrmFoot(
        origin,
        destLat,
        destLon,
        destName,
        alternatives: true,
      );
      if (myGen != _searchGen) return;
      if (altWalk != null && walk != null) {
        final diff = (altWalk.durationMin - walk.durationMin).abs();
        if (diff >= 3 &&
            (altWalk.distanceM - walk.distanceM).abs() > 120) {
          options.add(
            RouteOption(
              index: 0,
              kind: RouteKind.walk,
              title: 'Пешком, другой путь',
              summarySpeak: altWalk.summarySpeak.replaceFirst(
                'пешком',
                'пешком, другой путь',
              ),
              durationMin: altWalk.durationMin,
              distanceM: altWalk.distanceM,
              steps: altWalk.steps,
              points: altWalk.points,
              destLat: destLat,
              destLon: destLon,
              destName: destName,
            ),
          );
        }
      }
    }

    if (myGen != _searchGen) return;
    if (options.isEmpty) {
      await _enqueue('Маршрут не найден.', priority: 1);
      return;
    }

    options.sort((a, b) => a.durationMin.compareTo(b.durationMin));
    final top = options.take(3).toList();
    for (int i = 0; i < top.length; i++) {
      final o = top[i];
      top[i] = RouteOption(
        index: i + 1,
        kind: o.kind,
        title: o.title,
        summarySpeak: o.summarySpeak,
        durationMin: o.durationMin,
        distanceM: o.distanceM,
        steps: o.steps,
        points: o.points,
        destLat: o.destLat,
        destLon: o.destLon,
        destName: o.destName,
        transitLines: o.transitLines,
      );
    }

    _pendingOptions = top;
    _awaitingRouteChoice = true;
    _announceCancelled = false;
    _onNavFocus?.call(true);
    onAwaitingRouteChoice?.call(true);

    if (top.length == 1) {
      await _applyRouteOption(top.first);
      return;
    }

    // Одно сообщение — чтобы варианты не резались и не накладывались.
    final buf = StringBuffer('Нашла ${top.length} варианта. ');
    for (final opt in top) {
      buf.write('Вариант ${_numberRu(opt.index)}: ${opt.summarySpeak}. ');
    }
    buf.write('Скажите один или два.');
    await _say(buf.toString(), priority: 2);

    if (_awaitingRouteChoice && !_announceCancelled && myGen == _searchGen) {
      // Микрофон включаем уже после описания вариантов.
      onReadyForRouteChoiceListen?.call();
    }
  }

  /// Параллельно: пешком + ОТ через MapKit (один ключ).
  Future<List<RouteOption>> _fetchYandexRouteOptions(
    Position origin,
    double destLat,
    double destLon,
    String destName,
  ) async {
    if (_pedestrianRouter == null && _masstransitRouter == null) {
      return const [];
    }

    final points = [
      RequestPoint(
        Point(latitude: origin.latitude, longitude: origin.longitude),
        RequestPointType.Waypoint,
        null,
        null,
        null,
      ),
      RequestPoint(
        Point(latitude: destLat, longitude: destLon),
        RequestPointType.Waypoint,
        null,
        null,
        null,
      ),
    ];

    const timeOptions = TimeOptions();
    const routeOptions = RouteOptions(FitnessOptions(avoidSteep: false));
    const transitOptions = TransitOptions(timeOptions);

    final results = await Future.wait([
      if (_pedestrianRouter != null)
        _requestMasstransitRoutes(
          kind: RouteKind.walk,
          request: (listener) {
            _pedSession?.cancel();
            _pedSession = _pedestrianRouter!.requestRoutes(
              timeOptions,
              routeOptions,
              listener,
              points: points,
            );
          },
        )
      else
        Future.value(<MasstransitRoute>[]),
      if (_masstransitRouter != null)
        _requestMasstransitRoutes(
          kind: RouteKind.transit,
          request: (listener) {
            _mtSession?.cancel();
            _mtSession = _masstransitRouter!.requestRoutes(
              transitOptions,
              routeOptions,
              listener,
              points: points,
            );
          },
        )
      else
        Future.value(<MasstransitRoute>[]),
    ]);

    final walkRoutes = results[0];
    final transitRoutes = results[1];
    final out = <RouteOption>[];

    // Берём до 2 пеших (если есть альтернативы) и до 2 ОТ — потом обрежем до 3.
    for (final r in walkRoutes.take(2)) {
      final opt = _masstransitRouteToOption(
        r,
        kind: RouteKind.walk,
        destLat: destLat,
        destLon: destLon,
        destName: destName,
      );
      if (opt != null) out.add(opt);
    }
    for (final r in transitRoutes.take(2)) {
      final opt = _masstransitRouteToOption(
        r,
        kind: RouteKind.transit,
        destLat: destLat,
        destLon: destLon,
        destName: destName,
      );
      if (opt != null) out.add(opt);
    }

    _log(
      'Yandex: ${walkRoutes.length} пеших, ${transitRoutes.length} ОТ → '
      '${out.length} вариантов',
    );
    return out;
  }

  Future<List<MasstransitRoute>> _requestMasstransitRoutes({
    required RouteKind kind,
    required void Function(RouteHandler listener) request,
  }) async {
    final completer = Completer<List<MasstransitRoute>>();
    try {
      request(
        RouteHandler(
          onMasstransitRoutes: (routes) {
            if (!completer.isCompleted) completer.complete(routes);
          },
          onMasstransitRoutesError: (error) {
            _log('Yandex ${kind.name} error: $error');
            if (!completer.isCompleted) completer.complete(const []);
          },
        ),
      );
      return await completer.future.timeout(
        const Duration(seconds: 12),
        onTimeout: () {
          _log('Yandex ${kind.name} timeout');
          return const [];
        },
      );
    } catch (e) {
      _log('Yandex ${kind.name} failed: $e');
      return const [];
    }
  }

  RouteOption? _masstransitRouteToOption(
    MasstransitRoute route, {
    required RouteKind kind,
    required double destLat,
    required double destLon,
    required String destName,
  }) {
    try {
      final weight = route.metadata.weight;
      final durationSec = weight.time.value;
      final durationMin = durationSec / 60.0;
      final walkM = weight.walkingDistance.value;

      final points = route.geometry.points
          .map((p) => LatLng(p.latitude, p.longitude))
          .toList();

      final lines = <String>[];
      final legs = <String>[];
      final steps = <RouteStep>[];

      for (final section in route.sections) {
        final data = section.metadata.data;
        final secWeight = section.metadata.weight;
        final secMin = (secWeight.time.value / 60).round().clamp(0, 999);
        final stops = section.stops;
        final firstStop = stops.isNotEmpty ? stops.first.metadata.stop.name : null;
        final lastStop = stops.length > 1 ? stops.last.metadata.stop.name : null;

        // Точка для GPS-ведения — середина геометрии секции или остановка.
        double stepLat = destLat;
        double stepLon = destLon;
        if (stops.isNotEmpty) {
          final pos = stops.first.position;
          stepLat = pos.latitude;
          stepLon = pos.longitude;
        } else if (points.isNotEmpty) {
          stepLat = points.first.latitude;
          stepLon = points.first.longitude;
        }

        final transports = data.asVectorMasstransitTransport();
        if (transports != null && transports.isNotEmpty) {
          final t = transports.first;
          final line = t.line;
          final lineName = (line.shortName?.isNotEmpty == true)
              ? line.shortName!
              : line.name;
          final vType = _vehicleTypeRu(
            line.vehicleTypes.isNotEmpty ? line.vehicleTypes.first : 'bus',
          );
          lines.add(lineName);
          legs.add('$vType $lineName');
          final from = firstStop != null ? ' с «$firstStop»' : '';
          final to = lastStop != null ? ' до «$lastStop»' : '';
          steps.add(
            RouteStep(
              instruction: 'Садитесь на $vType $lineName$from$to.',
              distanceM: secWeight.walkingDistance.value,
              lat: stepLat,
              lon: stepLon,
            ),
          );
          continue;
        }

        if (data.asWait() != null) {
          steps.add(
            RouteStep(
              instruction: 'Ожидайте транспорт'
                  '${firstStop != null ? ' на «$firstStop»' : ''}.',
              distanceM: 0,
              lat: stepLat,
              lon: stepLon,
            ),
          );
          continue;
        }

        if (data.asTransfer() != null) {
          steps.add(
            RouteStep(
              instruction: 'Пересадка'
                  '${firstStop != null ? ' на «$firstStop»' : ''}.',
              distanceM: secWeight.walkingDistance.value,
              lat: stepLat,
              lon: stepLon,
            ),
          );
          continue;
        }

        if (data.asFitness() != null || kind == RouteKind.walk) {
          final walkDist = secWeight.walkingDistance.value;
          if (walkDist > 40 || secMin > 0) {
            if (legs.isEmpty || legs.last != 'пешком') {
              legs.add('пешком');
            }
          }
          final distSpeak = walkDist > 0
              ? ' ${_formatDistance(walkDist)}'
              : (secMin > 0 ? ' около $secMin мин' : '');
          steps.add(
            RouteStep(
              instruction: 'Идите пешком$distSpeak.',
              distanceM: walkDist,
              lat: stepLat,
              lon: stepLon,
            ),
          );
        }
      }

      if (steps.isEmpty) {
        steps.add(
          RouteStep(
            instruction: 'Начните движение к $destName',
            distanceM: walkM,
            lat: destLat,
            lon: destLon,
          ),
        );
      }
      steps.add(
        RouteStep(
          instruction: 'Вы прибыли к цели',
          distanceM: 0,
          lat: destLat,
          lon: destLon,
        ),
      );

      final minRound = max(1, durationMin.round());
      final String summary;
      if (kind == RouteKind.walk) {
        summary =
            'пешком, около $minRound ${_minutesWord(minRound)}, '
            '${_formatDistance(walkM > 0 ? walkM : _polylineLengthM(points))}';
      } else {
        // Коротко: время + цепочка «пешком — автобус 567 — пешком».
        final chain = legs.isEmpty
            ? (lines.isEmpty
                ? 'общественный транспорт'
                : lines.map(_lineSpeak).take(3).join(', '))
            : legs.take(6).join(', потом ');
        summary =
            'около $minRound ${_minutesWord(minRound)}: $chain';
      }

      return RouteOption(
        index: 0,
        kind: kind,
        title: kind == RouteKind.walk ? 'Пешком' : 'С транспортом',
        summarySpeak: summary,
        durationMin: durationMin,
        distanceM: walkM > 0 ? walkM : _polylineLengthM(points),
        steps: steps,
        points: points,
        destLat: destLat,
        destLon: destLon,
        destName: destName,
        transitLines: lines,
      );
    } catch (e) {
      _log('Parse MasstransitRoute error: $e');
      return null;
    }
  }

  String _vehicleTypeRu(String raw) {
    final t = raw.toLowerCase();
    if (t.contains('minibus') || t.contains('marsh')) return 'маршрутка';
    if (t.contains('bus') || t.contains('autobus')) return 'автобус';
    if (t.contains('tram')) return 'трамвай';
    if (t.contains('trolley')) return 'троллейбус';
    if (t.contains('underground') || t.contains('metro')) return 'метро';
    if (t.contains('suburban') || t.contains('train')) return 'электричка';
    if (t.contains('water') || t.contains('ferry')) return 'паром';
    return 'транспорт';
  }

  String _lineSpeak(String name) {
    // «15» → «автобус или маршрутка 15»; «Сокольническая» оставляем как есть.
    if (RegExp(r'^\d+[а-яa-z]?$', caseSensitive: false).hasMatch(name.trim())) {
      return 'маршрут $name';
    }
    return name;
  }

  double _polylineLengthM(List<LatLng> pts) {
    double sum = 0;
    for (int i = 1; i < pts.length; i++) {
      sum += _haversineM(
        pts[i - 1].latitude,
        pts[i - 1].longitude,
        pts[i].latitude,
        pts[i].longitude,
      );
    }
    return sum;
  }

  /// Голосовой выбор варианта (1/2/3) или отмена выбора.
  /// Возвращает true, если команда относится к выбору маршрута.
  Future<bool> handleRouteChoiceCommand(String command) async {
    if (!_awaitingRouteChoice) return false;
    final cmd = command.toLowerCase().trim();

    if (cmd.contains('отмен') || cmd == 'стоп' || cmd == 'не надо') {
      _searchGen++;
      _clearPendingChoice(silent: false);
      await _interrupt();
      await _enqueue('Выбор маршрута отменён.', priority: 2);
      return true;
    }

    final n = _parseChoiceNumber(cmd);
    if (n == null) return false;
    if (n < 1 || n > _pendingOptions.length) {
      await _enqueue(
        'Нет варианта $n. Скажите число от одного до ${_pendingOptions.length}.',
        priority: 2,
      );
      return true;
    }

    _announceCancelled = true;
    await _interrupt();
    final opt = _pendingOptions[n - 1];
    _awaitingRouteChoice = false;
    onAwaitingRouteChoice?.call(false);
    await _enqueue('Выбран вариант ${_numberRu(n)}.', priority: 2);
    await _applyRouteOption(opt);
    return true;
  }

  int? _parseChoiceNumber(String cmd) {
    if (RegExp(r'\b(1|один|перв)\b').hasMatch(cmd)) return 1;
    if (RegExp(r'\b(2|два|втор)\b').hasMatch(cmd)) return 2;
    if (RegExp(r'\b(3|три|трет)\b').hasMatch(cmd)) return 3;
    final m = RegExp(r'\b([123])\b').firstMatch(cmd);
    if (m != null) return int.parse(m.group(1)!);
    return null;
  }

  String _numberRu(int n) {
    switch (n) {
      case 1:
        return 'один';
      case 2:
        return 'два';
      case 3:
        return 'три';
      default:
        return '$n';
    }
  }

  Future<void> _applyRouteOption(RouteOption opt) async {
    _pendingOptions = [];
    _awaitingRouteChoice = false;
    onAwaitingRouteChoice?.call(false);
    // Держим navFocus ещё на объявление старта, карту уже рисуем.
    _onNavFocus?.call(true);

    if (opt.steps.isEmpty) {
      _onNavFocus?.call(false);
      await _enqueue('Не удалось запустить маршрут.', priority: 1);
      return;
    }

    _steps = List.of(opt.steps);
    _routePoints = List.of(opt.points);
    _currentStepIndex = 0;
    _destinationName = opt.destName;
    _destLat = opt.destLat;
    _destLon = opt.destLon;
    _isNavigating = true;
    _preAnnounced = false;
    _rerouting = false;
    _lastGuideSpoken = '';
    _lastGuideSpokenMs = 0;

    // Сначала линия на карте — чтобы окружающие видели маршрут.
    onRouteReady?.call(opt.points, LatLng(opt.destLat, opt.destLon));

    await _enqueue(
      '${opt.summarySpeak}. ${opt.steps.first.instruction}.',
      priority: 2,
    );
    _onNavFocus?.call(false);
    _startGuiding();
  }

  void _clearPendingChoice({required bool silent}) {
    _announceCancelled = true;
    _awaitingRouteChoice = false;
    _pendingOptions = [];
    onAwaitingRouteChoice?.call(false);
    _onNavFocus?.call(false);
  }

  Future<RouteOption?> _fetchOsrmFoot(
    Position origin,
    double destLat,
    double destLon,
    String destName, {
    bool alternatives = false,
  }) async {
    try {
      final url =
          'https://routing.openstreetmap.de/routed-foot/route/v1/foot/'
          '${origin.longitude},${origin.latitude};'
          '$destLon,$destLat'
          '?steps=true&overview=full&geometries=geojson'
          '${alternatives ? '&alternatives=true' : ''}';

      final response = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 12));
      if (response.statusCode != 200) return null;

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      if ((json['code'] as String? ?? '') != 'Ok') return null;
      final routes = json['routes'] as List? ?? [];
      if (routes.isEmpty) return null;

      // При alternatives берём второй маршрут, если есть.
      final route = (alternatives && routes.length > 1)
          ? routes[1] as Map<String, dynamic>
          : routes.first as Map<String, dynamic>;

      final parsed = _parseOsrmRoute(route, destLat, destLon, destName);
      return parsed;
    } catch (e) {
      _log('OSRM error: $e');
      return null;
    }
  }

  RouteOption? _parseOsrmRoute(
    Map<String, dynamic> route,
    double destLat,
    double destLon,
    String destName,
  ) {
    final geometry = route['geometry'] as Map<String, dynamic>?;
    final routePoints = <LatLng>[];
    if (geometry != null && geometry['type'] == 'LineString') {
      final coords = geometry['coordinates'] as List? ?? [];
      for (final coord in coords) {
        if (coord is List && coord.length >= 2) {
          routePoints.add(
            LatLng((coord[1] as num).toDouble(), (coord[0] as num).toDouble()),
          );
        }
      }
    }

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
        final instruction = _buildInstruction(
          type,
          modifier,
          step['name'] as String?,
          distanceM,
        );
        if (instruction.isEmpty) continue;
        steps.add(
          RouteStep(
            instruction: instruction,
            distanceM: distanceM,
            lat: (location[1] as num).toDouble(),
            lon: (location[0] as num).toDouble(),
          ),
        );
      }
    }
    if (steps.isEmpty) return null;

    final totalM = (route['distance'] as num?)?.toDouble() ?? 0.0;
    final totalMin = ((route['duration'] as num?)?.toDouble() ?? 0.0) / 60;
    final minRound = max(1, totalMin.round());

    return RouteOption(
      index: 0,
      kind: RouteKind.walk,
      title: 'Пешком',
      summarySpeak:
          'пешком, около $minRound ${_minutesWord(minRound)}, '
          '${_formatDistance(totalM)}',
      durationMin: totalMin,
      distanceM: totalM,
      steps: steps,
      points: routePoints,
      destLat: destLat,
      destLon: destLon,
      destName: destName,
    );
  }

  /// Оценка маршрута с ОТ по ближайшим остановкам OSM.
  Future<RouteOption?> _estimateTransitOption(
    Position origin,
    double destLat,
    double destLon,
    String destName, {
    double? walkDurationMin,
  }) async {
    try {
      final nearOrigin = await _nearestStops(
        origin.latitude,
        origin.longitude,
        radiusM: 700,
      );
      final nearDest = await _nearestStops(destLat, destLon, radiusM: 700);
      if (nearOrigin.isEmpty || nearDest.isEmpty) return null;

      final fromStop = nearOrigin.first;
      final toStop = nearDest.first;

      final walkToStopM = _haversineM(
        origin.latitude,
        origin.longitude,
        fromStop.lat,
        fromStop.lon,
      );
      final walkFromStopM = _haversineM(
        toStop.lat,
        toStop.lon,
        destLat,
        destLon,
      );
      final rideM = _haversineM(
        fromStop.lat,
        fromStop.lon,
        toStop.lat,
        toStop.lon,
      );

      // Слишком близко — ОТ бессмысленен.
      if (rideM < 400) return null;

      // Пешком ~4.5 км/ч, автобус/маршрутка по городу ~18 км/ч + ожидание 4 мин.
      final walkToMin = walkToStopM / 75.0;
      final walkFromMin = walkFromStopM / 75.0;
      final rideMin = rideM / 300.0;
      const waitMin = 4.0;
      final totalMin = walkToMin + waitMin + rideMin + walkFromMin;

      // Если пешком почти так же быстро — не предлагаем.
      if (walkDurationMin != null && totalMin > walkDurationMin * 0.95) {
        return null;
      }

      final lines = <String>{
        ...fromStop.lines,
        ...toStop.lines,
      }.take(3).toList();
      final linesSpeak = lines.isEmpty
          ? 'автобус или маршрутка'
          : lines.length == 1
              ? 'маршрут ${lines.first}'
              : 'маршруты ${lines.join(', ')}';

      final minRound = max(1, totalMin.round());
      final walkToRound = max(1, walkToMin.round());
      final walkFromRound = max(1, walkFromMin.round());

      final summary =
          'с транспортом, около $minRound ${_minutesWord(minRound)}. '
          'Пешком до остановки «${fromStop.name}» около $walkToRound мин, '
          'затем $linesSpeak, '
          'и ещё $walkFromRound мин пешком';

      // Для ведения используем пеший OSRM до остановки как первые шаги,
      // дальше — упрощённая инструкция «садитесь на транспорт».
      final toStopRoute = await _fetchOsrmFoot(
        origin,
        fromStop.lat,
        fromStop.lon,
        fromStop.name,
      );

      final steps = <RouteStep>[
        ...?toStopRoute?.steps,
        RouteStep(
          instruction:
              'Остановка «${fromStop.name}». Посадка: $linesSpeak. '
              'Едьте до остановки «${toStop.name}».',
          distanceM: rideM,
          lat: fromStop.lat,
          lon: fromStop.lon,
        ),
        RouteStep(
          instruction:
              'Выйдите на «${toStop.name}» и идите к $destName, '
              'примерно $walkFromRound минут.',
          distanceM: walkFromStopM,
          lat: toStop.lat,
          lon: toStop.lon,
        ),
        RouteStep(
          instruction: 'Вы прибыли к цели',
          distanceM: 0,
          lat: destLat,
          lon: destLon,
        ),
      ];

      final points = <LatLng>[
        ...?toStopRoute?.points,
        LatLng(fromStop.lat, fromStop.lon),
        LatLng(toStop.lat, toStop.lon),
        LatLng(destLat, destLon),
      ];

      return RouteOption(
        index: 0,
        kind: RouteKind.transit,
        title: 'С транспортом',
        summarySpeak: summary,
        durationMin: totalMin,
        distanceM: walkToStopM + rideM + walkFromStopM,
        steps: steps,
        points: points,
        destLat: destLat,
        destLon: destLon,
        destName: destName,
        transitLines: lines,
      );
    } catch (e) {
      _log('Transit estimate error: $e');
      return null;
    }
  }

  Future<List<_BusStop>> _nearestStops(
    double lat,
    double lon, {
    required double radiusM,
  }) async {
    final q =
        '[out:json][timeout:10];\n'
        '(\n'
        '  node["highway"="bus_stop"](around:$radiusM,$lat,$lon);\n'
        '  node["public_transport"="platform"](around:$radiusM,$lat,$lon);\n'
        '  node["railway"="tram_stop"](around:$radiusM,$lat,$lon);\n'
        ');\n'
        'out body 15;\n';
    final response = await http
        .post(
          Uri.parse('https://overpass-api.de/api/interpreter'),
          body: {'data': q},
        )
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) return [];
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final elements = json['elements'] as List? ?? [];
    final stops = <_BusStop>[];
    for (final el in elements) {
      final e = el as Map<String, dynamic>;
      if (e['type'] != 'node') continue;
      final tags = (e['tags'] as Map?)?.cast<String, String>() ?? {};
      final name = tags['name'] ?? tags['ref'] ?? 'остановка';
      final lines = <String>[];
      for (final key in ['route_ref', 'ref', 'bus']) {
        final v = tags[key];
        if (v != null && v.isNotEmpty) {
          lines.addAll(
            v.split(RegExp(r'[,;/]')).map((s) => s.trim()).where((s) => s.isNotEmpty),
          );
        }
      }
      stops.add(
        _BusStop(
          lat: (e['lat'] as num).toDouble(),
          lon: (e['lon'] as num).toDouble(),
          name: name,
          lines: lines,
        ),
      );
    }
    stops.sort(
      (a, b) => _haversineM(lat, lon, a.lat, a.lon)
          .compareTo(_haversineM(lat, lon, b.lat, b.lon)),
    );
    return stops;
  }

  Future<(double lat, double lon, String name)?> _searchYandex(
    String query,
    Position origin,
  ) async {
    if (_yandexSearch == null) return null;

    final completer = Completer<(double, double, String)?>();
    try {
      final point = Point(latitude: origin.latitude, longitude: origin.longitude);
      _yandexSession?.cancel();
      _yandexSession = _yandexSearch!.submit(
        Geometry.fromPoint(point),
        SearchOptions(
          searchTypes: SearchType.Geo | SearchType.Biz,
          resultPageSize: 8,
          userPosition: point,
          geometry: true,
        ),
        SearchSessionSearchListener(
          onSearchResponse: (response) {
            try {
              final hits = <(double, double, String, double)>[];
              _collectYandexHits(response.collection, hits, origin);
              if (hits.isEmpty) {
                if (!completer.isCompleted) completer.complete(null);
                return;
              }
              hits.sort((a, b) => a.$4.compareTo(b.$4));
              final best = hits.first;
              if (!completer.isCompleted) {
                completer.complete((best.$1, best.$2, best.$3));
              }
            } catch (e) {
              _log('Yandex parse error: $e');
              if (!completer.isCompleted) completer.complete(null);
            }
          },
          onSearchError: (error) {
            _log('Yandex Search error: $error');
            if (!completer.isCompleted) completer.complete(null);
          },
        ),
        text: query,
      );

      return await completer.future.timeout(
        const Duration(seconds: 8),
        onTimeout: () {
          _log('Yandex Search timeout');
          return null;
        },
      );
    } catch (e) {
      _log('Yandex Search failed: $e');
      return null;
    }
  }

  void _collectYandexHits(
    dynamic collection,
    List<(double, double, String, double)> out,
    Position origin, {
    int depth = 0,
  }) {
    if (depth > 4) return;
    final children = collection.children as List;
    for (final child in children) {
      final obj = child.asGeoObject();
      if (obj != null) {
        final name = (obj.name ?? '').trim();
        if (name.isEmpty) continue;

        double? lat;
        double? lon;
        for (final g in obj.geometry) {
          final p = g.asPoint();
          if (p != null) {
            lat = p.latitude;
            lon = p.longitude;
            break;
          }
        }
        if (lat == null && obj.boundingBox != null) {
          final bb = obj.boundingBox!;
          lat = (bb.southWest.latitude + bb.northEast.latitude) / 2;
          lon = (bb.southWest.longitude + bb.northEast.longitude) / 2;
        }
        if (lat == null || lon == null) continue;

        final dist = _haversineM(
          origin.latitude,
          origin.longitude,
          lat,
          lon,
        );
        out.add((lat, lon, name, dist));
      }
      final nested = child.asGeoObjectCollection();
      if (nested != null) {
        _collectYandexHits(nested, out, origin, depth: depth + 1);
      }
    }
  }

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
            headers: {
              'Content-Type': 'application/x-www-form-urlencoded',
              'Accept': 'application/json',
            },
            body: {'data': overpassQuery},
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) return null;

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final elements = json['elements'] as List? ?? [];
      if (elements.isEmpty) return null;

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
      return best;
    } catch (e) {
      _log('Ошибка POI: $e');
      return null;
    }
  }

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

      final response = await http
          .get(uri, headers: {'User-Agent': 'SmartGlassesApp/1.0'})
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) return null;

      final list = jsonDecode(response.body) as List;
      if (list.isEmpty) return null;

      final place = list.first as Map<String, dynamic>;
      final lat = double.parse(place['lat'] as String);
      final lon = double.parse(place['lon'] as String);
      final name = place['display_name'] as String? ?? query;
      final shortName = name.split(',').first.trim();
      return (lat, lon, shortName);
    } catch (e) {
      _log('Ошибка геокодирования: $e');
      return null;
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

    _checkOffRoute(userPos);

    final isWait = step.instruction.toLowerCase().contains('ожида');
    final isBoard = step.instruction.toLowerCase().contains('садитесь');

    // Ожидание транспорта / посадка: не крутить одну фразу и не «прощёлкивать»
    // шаг каждые 3 с, пока человек стоит на остановке.
    if (isWait || isBoard) {
      _speakGuideOnce(step.instruction, minIntervalMs: 180000);
      // Сошли с остановки (≥35 м) — считаем, что уехали/ушли дальше.
      if (dist >= 35) {
        _currentStepIndex++;
        _preAnnounced = false;
        _lastGuideSpoken = '';
        if (_currentStepIndex >= _steps.length) {
          _onArrived();
        } else {
          _speakGuideOnce(_steps[_currentStepIndex].instruction, force: true);
        }
      }
      return;
    }

    if (dist < _preAnnounceM &&
        !_preAnnounced &&
        _currentStepIndex + 1 < _steps.length) {
      _preAnnounced = true;
      final next = _steps[_currentStepIndex + 1];
      _speakGuideOnce(
        'Через ${dist.round()} метров: ${next.instruction}',
        minIntervalMs: 25000,
      );
    }

    if (dist < _stepAdvanceThresholdM) {
      _currentStepIndex++;
      _preAnnounced = false;

      if (_currentStepIndex >= _steps.length) {
        _onArrived();
      } else {
        final next = _steps[_currentStepIndex];
        _speakGuideOnce(next.instruction, force: true);
      }
    }
  }

  void _speakGuideOnce(
    String text, {
    int minIntervalMs = 45000,
    bool force = false,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!force &&
        text == _lastGuideSpoken &&
        now - _lastGuideSpokenMs < minIntervalMs) {
      return;
    }
    _lastGuideSpoken = text;
    _lastGuideSpokenMs = now;
    _enqueue(text, priority: 2).catchError((_) {});
  }

  void _checkOffRoute(Position userPos) {
    if (_rerouting || _routePoints.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastRerouteMs < _rerouteCooldownMs) return;

    var minDist = double.infinity;
    for (final p in _routePoints) {
      final d = _haversineM(
        userPos.latitude,
        userPos.longitude,
        p.latitude,
        p.longitude,
      );
      if (d < minDist) minDist = d;
    }
    if (minDist <= _offRouteM) return;

    _lastRerouteMs = now;
    _rerouting = true;
    _enqueue(
      'Вы ушли с маршрута, перестраиваю.',
      priority: 2,
    ).catchError((_) {});

    final name = _destinationName.isEmpty ? 'пункт назначения' : _destinationName;
    final lat = _destLat;
    final lon = _destLon;
    Future(() async {
      try {
        if (lat != 0 && lon != 0) {
          await _rebuildToCoords(lat, lon, name);
        }
      } catch (e) {
        _log('Reroute error: $e');
      } finally {
        _rerouting = false;
      }
    });
  }

  Future<void> _rebuildToCoords(
    double destLat,
    double destLon,
    String destName,
  ) async {
    try {
      final origin = await _getCurrentPosition();
      if (origin == null) return;
      final foot = await _fetchOsrmFoot(origin, destLat, destLon, destName);
      if (foot != null && foot.steps.isNotEmpty) {
        await _applyRouteOption(foot);
      }
    } catch (e) {
      _log('rebuild: $e');
    }
  }

  void _onArrived() {
    _isNavigating = false;
    _guideTimer?.cancel();
    _positionSub?.cancel();
    final name = _destinationName;
    _destinationName = '';
    _routePoints = [];
    _enqueue(
      'Вы прибыли к месту назначения: $name.',
      priority: 2,
    ).catchError((_) {});
    _steps = [];
    _currentStepIndex = 0;
  }

  /// Полная остановка навигации и выбора маршрута.
  void stopNavigation({bool announce = true}) {
    _searchGen++;
    _clearPendingChoice(silent: true);
    _isNavigating = false;
    _guideTimer?.cancel();
    _positionSub?.cancel();
    _steps = [];
    _routePoints = [];
    _currentStepIndex = 0;
    _destinationName = '';
    _pedSession?.cancel();
    _mtSession?.cancel();
    _yandexSession?.cancel();
    onRouteReady?.call(const [], const LatLng(0, 0));
    _interrupt().catchError((_) {});
    if (announce) {
      _enqueue('Маршрут отменён.', priority: 2).catchError((_) {});
    }
  }

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

  String _minutesWord(int m) {
    final mod10 = m % 10;
    final mod100 = m % 100;
    if (mod10 == 1 && mod100 != 11) return 'минута';
    if (mod10 >= 2 && mod10 <= 4 && (mod100 < 12 || mod100 > 14)) {
      return 'минуты';
    }
    return 'минут';
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
    if (q.contains('кафе') || q.contains('кофейня')) {
      return '["amenity"="cafe"]';
    }
    if (q.contains('ресторан')) return '["amenity"="restaurant"]';
    if (q.contains('автобусная остановка') || q.contains('остановка')) {
      return '["highway"="bus_stop"]';
    }
    if (q.contains('метро') || q.contains('станция метро')) {
      return '["station"="subway"]';
    }
    if (q.contains('парк')) return '["leisure"="park"]';
    if (q.contains('заправка') || q.contains('азс')) {
      return '["amenity"="fuel"]';
    }
    if (q.contains('туалет') || q.contains('wc')) {
      return '["amenity"="toilets"]';
    }
    if (q.contains('почта')) return '["amenity"="post_office"]';
    if (q.contains('школа')) return '["amenity"="school"]';
    if (q.contains('детский сад') || q.contains('детсад')) {
      return '["amenity"="kindergarten"]';
    }
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
    _yandexSession?.cancel();
    _yandexSession = null;
    _pedSession?.cancel();
    _mtSession?.cancel();
    _pedSession = null;
    _mtSession = null;
    _isNavigating = false;
    _clearPendingChoice(silent: true);
  }
}

class _BusStop {
  final double lat;
  final double lon;
  final String name;
  final List<String> lines;

  _BusStop({
    required this.lat,
    required this.lon,
    required this.name,
    required this.lines,
  });
}
