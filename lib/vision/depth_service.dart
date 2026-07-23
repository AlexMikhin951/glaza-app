import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

import '../ai_detector.dart';
import '../distance_estimator.dart';

/// Depth: TFLite Depth Anything (если есть asset) + относительная карта + калибровка.
///
/// Положите модель в `assets/models/depth_anything.tflite` (Small/Tiny).
/// Без файла работает эвристика + bbox + калибровка 1/3/5 м.
class DepthService {
  static const _assetPath = 'assets/models/depth_anything.tflite';
  static const _prefA = 'depth_calib_a';
  static const _prefB = 'depth_calib_b';
  static const _prefSamples = 'depth_calib_samples';

  Interpreter? _interpreter;
  bool _ready = false;
  bool modelLoaded = false;
  int mapSize = 64;

  /// meters ≈ a / depthRel + b, где depthRel ∈ (0..1], выше = дальше.
  double calibA = 2.8;
  double calibB = 0.4;

  /// Точки калибровки: известные метры → median relative depth.
  final List<({double meters, double depthRel})> _samples = [];

  Float32List? _lastMap;
  int _lastMapMs = 0;
  static const _cacheMs = 200;

  Future<void> init() async {
    await _loadCalib();
    await _tryLoadModel();
    _ready = true;
    debugPrint(
      '✅ DepthService ready model=$modelLoaded a=${calibA.toStringAsFixed(2)} '
      'b=${calibB.toStringAsFixed(2)} samples=${_samples.length}',
    );
  }

  bool get isReady => _ready;
  int get sampleCount => _samples.length;

  Future<void> _loadCalib() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      calibA = prefs.getDouble(_prefA) ?? calibA;
      calibB = prefs.getDouble(_prefB) ?? calibB;
      final raw = prefs.getStringList(_prefSamples) ?? [];
      _samples.clear();
      for (final s in raw) {
        final p = s.split(':');
        if (p.length != 2) continue;
        final m = double.tryParse(p[0]);
        final d = double.tryParse(p[1]);
        if (m != null && d != null) _samples.add((meters: m, depthRel: d));
      }
      if (_samples.length >= 2) _refitFromSamples();
    } catch (e) {
      debugPrint('DepthService calib load: $e');
    }
  }

  Future<void> _saveCalib() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_prefA, calibA);
    await prefs.setDouble(_prefB, calibB);
    await prefs.setStringList(
      _prefSamples,
      _samples.map((s) => '${s.meters}:${s.depthRel}').toList(),
    );
  }

  Future<void> _tryLoadModel() async {
    try {
      await rootBundle.load(_assetPath);
    } catch (_) {
      modelLoaded = false;
      return;
    }
    try {
      final options = InterpreterOptions()..threads = 2;
      _interpreter = await Interpreter.fromAsset(_assetPath, options: options);
      final inShape = _interpreter!.getInputTensor(0).shape;
      // Ожидаем NHWC [1,H,W,3] или [1,3,H,W]
      if (inShape.length >= 3) {
        mapSize = inShape.length == 4 && inShape[3] == 3
            ? inShape[1]
            : (inShape.length == 4 ? inShape[2] : 64);
        mapSize = mapSize.clamp(32, 256);
      }
      modelLoaded = true;
      debugPrint('✅ Depth TFLite loaded input=$inShape');
    } catch (e) {
      modelLoaded = false;
      _interpreter = null;
      debugPrint('⚠️ Depth TFLite load failed: $e — using relative fallback');
    }
  }

  /// Карта: выше значение ≈ дальше.
  Future<Float32List?> process(Uint8List jpeg) async {
    if (!_ready) return null;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_lastMap != null && now - _lastMapMs < _cacheMs) return _lastMap;

    Float32List? map;
    if (modelLoaded && _interpreter != null) {
      map = _runModel(jpeg);
    }
    map ??= await compute(_relativeDepthMap, _RelArgs(jpeg, mapSize));

    _lastMap = map;
    _lastMapMs = now;
    return map;
  }

  Float32List? _runModel(Uint8List jpeg) {
    final interp = _interpreter;
    if (interp == null) return null;
    try {
      final decoded = img.decodeJpg(jpeg);
      if (decoded == null) return null;
      final size = mapSize;
      final resized = img.copyResize(decoded, width: size, height: size);
      final inputShape = List<int>.from(interp.getInputTensor(0).shape);
      final outputShape = List<int>.from(interp.getOutputTensor(0).shape);
      final outLen = outputShape.fold(1, (a, b) => a * b);
      final output = List.filled(outLen, 0.0);
      final nhwc = inputShape.length == 4 && inputShape[3] == 3;

      final input = List.generate(1, (_) {
        if (nhwc) {
          return List.generate(
            size,
            (y) => List.generate(size, (x) {
              final p = resized.getPixel(x, y);
              return [p.r / 255.0, p.g / 255.0, p.b / 255.0];
            }),
          );
        }
        return [
          for (var c = 0; c < 3; c++)
            List.generate(
              size,
              (y) => List.generate(size, (x) {
                final p = resized.getPixel(x, y);
                return c == 0
                    ? p.r / 255.0
                    : (c == 1 ? p.g / 255.0 : p.b / 255.0);
              }),
            ),
        ];
      });

      interp.run(input, output);
      final flat = Float32List(size * size);
      final take = flat.length.clamp(0, output.length);
      for (var k = 0; k < take; k++) {
        flat[k] = output[k].toDouble();
      }
      return _normalizeMap(flat);
    } catch (e) {
      debugPrint('Depth model run error: $e');
      return null;
    }
  }

  static Float32List _normalizeMap(Float32List raw) {
    var minV = double.infinity;
    var maxV = -double.infinity;
    for (final v in raw) {
      if (v < minV) minV = v;
      if (v > maxV) maxV = v;
    }
    final span = (maxV - minV).abs() < 1e-6 ? 1.0 : (maxV - minV);
    final out = Float32List(raw.length);
    for (var i = 0; i < raw.length; i++) {
      out[i] = ((raw[i] - minV) / span).clamp(0.0, 1.0);
    }
    return out;
  }

  /// Метры: fusion bbox + depth ROI.
  Future<double?> metersForObject(
    DetectedObject obj,
    Uint8List jpeg, {
    Float32List? depthMap,
  }) async {
    final classic = DistanceEstimator.estimateMeters(obj);
    final map = depthMap ?? await process(jpeg);
    double? fromDepth;
    if (map != null) {
      final rel = medianInRoi(map, mapSize, mapSize, obj.rect);
      if (rel != null) fromDepth = relToMeters(rel);
    }
    if (classic != null && fromDepth != null) {
      // 60% classic (стабильнее на OV5640), 40% depth
      return classic * 0.6 + fromDepth * 0.4;
    }
    return fromDepth ?? classic;
  }

  double relToMeters(double depthRel) {
    final inv = depthRel.clamp(0.05, 0.98);
    return calibA / inv + calibB;
  }

  static double? medianInRoi(
    Float32List map,
    int mw,
    int mh,
    List<double> rect,
  ) {
    final top = rect[0].clamp(0.0, 1.0);
    final left = rect[1].clamp(0.0, 1.0);
    final bottom = rect[2].clamp(0.0, 1.0);
    final right = rect[3].clamp(0.0, 1.0);
    final y0 = (top * mh).floor();
    final y1 = (bottom * mh).ceil().clamp(y0 + 1, mh);
    final x0 = (left * mw).floor();
    final x1 = (right * mw).ceil().clamp(x0 + 1, mw);
    final vals = <double>[];
    for (var y = y0; y < y1; y++) {
      for (var x = x0; x < x1; x++) {
        vals.add(map[y * mw + x]);
      }
    }
    if (vals.isEmpty) return null;
    vals.sort();
    return vals[vals.length ~/ 2];
  }

  String zoneRu(double? meters) {
    if (meters == null) return 'на неизвестном расстоянии';
    if (meters < 2.5) return 'близко';
    if (meters < 6) return 'средне';
    return 'далеко';
  }

  /// Записать точку калибровки: «сейчас ровно [meters] метров до объекта в центре».
  Future<String> calibrateAt(double meters, Uint8List jpeg) async {
    final map = await process(jpeg);
    if (map == null) return 'Не удалось получить карту глубины.';
    // Центр кадра 20%
    final rel = medianInRoi(map, mapSize, mapSize, [0.4, 0.4, 0.6, 0.6]);
    if (rel == null) return 'Нет данных в центре кадра.';

    _samples.removeWhere((s) => (s.meters - meters).abs() < 0.2);
    _samples.add((meters: meters, depthRel: rel));
    _samples.sort((a, b) => a.meters.compareTo(b.meters));
    if (_samples.length > 6) _samples.removeAt(0);

    if (_samples.length >= 2) {
      _refitFromSamples();
      await _saveCalib();
      return 'Калибровка $meters м сохранена. Точек: ${_samples.length}.';
    }
    await _saveCalib();
    return 'Точка $meters м записана. Добавьте ещё хотя бы одну (3 или 5 м).';
  }

  void _refitFromSamples() {
    // Линейная регрессия meters = a / depth + b  ⇔  meters = a * inv + b
    if (_samples.length < 2) return;
    final xs = _samples.map((s) => 1.0 / s.depthRel.clamp(0.05, 0.98)).toList();
    final ys = _samples.map((s) => s.meters).toList();
    final n = xs.length.toDouble();
    final meanX = xs.reduce((a, b) => a + b) / n;
    final meanY = ys.reduce((a, b) => a + b) / n;
    var num = 0.0, den = 0.0;
    for (var i = 0; i < xs.length; i++) {
      num += (xs[i] - meanX) * (ys[i] - meanY);
      den += (xs[i] - meanX) * (xs[i] - meanX);
    }
    if (den.abs() < 1e-9) return;
    calibA = num / den;
    calibB = meanY - calibA * meanX;
    // Sanity
    if (calibA < 0.3 || calibA > 30) calibA = 2.8;
    if (calibB.abs() > 8) calibB = 0.4;
  }

  Future<bool> holeCandidate(Uint8List jpeg, {Float32List? depthMap}) async {
    final map = depthMap ?? await process(jpeg);
    if (map == null) return false;
    final size = mapSize;
    final y0 = (size * 0.66).floor();
    double sumCenter = 0, sumSides = 0;
    var nC = 0, nS = 0;
    for (var y = y0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        final v = map[y * size + x];
        if (x > size * 0.3 && x < size * 0.7) {
          sumCenter += v;
          nC++;
        } else {
          sumSides += v;
          nS++;
        }
      }
    }
    if (nC == 0 || nS == 0) return false;
    final c = sumCenter / nC;
    final s = sumSides / nS;
    // Центр ближе (меньше relative-far) чем бока
    return (s - c) > 0.10;
  }

  /// Ближайшая относительная глубина в нижней/центральной зоне для радара.
  Future<double?> nearestMeters(Uint8List jpeg, {Float32List? depthMap}) async {
    final map = depthMap ?? await process(jpeg);
    if (map == null) return null;
    final size = mapSize;
    var minRel = 1.0;
    final y0 = (size * 0.35).floor();
    for (var y = y0; y < size; y++) {
      for (var x = (size * 0.25).floor(); x < (size * 0.75).floor(); x++) {
        final v = map[y * size + x];
        if (v < minRel) minRel = v;
      }
    }
    return relToMeters(minRel);
  }

  void dispose() {
    _interpreter?.close();
    _interpreter = null;
  }
}

class _RelArgs {
  final Uint8List jpeg;
  final int size;
  _RelArgs(this.jpeg, this.size);
}

Float32List? _relativeDepthMap(_RelArgs args) {
  final decoded = img.decodeJpg(args.jpeg);
  if (decoded == null) return null;
  final size = args.size;
  final out = Float32List(size * size);
  final w = decoded.width;
  final h = decoded.height;
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final sx = (x / size * w).floor().clamp(0, w - 1);
      final sy = (y / size * h).floor().clamp(0, h - 1);
      final p = decoded.getPixel(sx, sy);
      final lum = (0.299 * p.r + 0.587 * p.g + 0.114 * p.b) / 255.0;
      final yBias = y / size;
      out[y * size + x] = (lum * 0.55 + (1 - yBias) * 0.45).clamp(0.0, 1.0);
    }
  }
  return out;
}
