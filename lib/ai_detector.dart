import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'perf_logger.dart';

class DetectedObject {
  final String label;
  final double score;
  final List<double> rect; // [top, left, bottom, right] нормализованные [0..1]
  DetectedObject(this.label, this.score, this.rect);
}

/// Список классов COCO — замените на свои, если модель обучена на другом датасете.
const List<String> _cocoLabels = [
  'person',
  'bicycle',
  'car',
  'motorcycle',
  'airplane',
  'bus',
  'train',
  'truck',
  'boat',
  'traffic light',
  'fire hydrant',
  'stop sign',
  'parking meter',
  'bench',
  'bird',
  'cat',
  'dog',
  'horse',
  'sheep',
  'cow',
  'elephant',
  'bear',
  'zebra',
  'giraffe',
  'backpack',
  'umbrella',
  'handbag',
  'tie',
  'suitcase',
  'frisbee',
  'skis',
  'snowboard',
  'sports ball',
  'kite',
  'baseball bat',
  'baseball glove',
  'skateboard',
  'surfboard',
  'tennis racket',
  'bottle',
  'wine glass',
  'cup',
  'fork',
  'knife',
  'spoon',
  'bowl',
  'banana',
  'apple',
  'sandwich',
  'orange',
  'broccoli',
  'carrot',
  'hot dog',
  'pizza',
  'donut',
  'cake',
  'chair',
  'couch',
  'potted plant',
  'bed',
  'dining table',
  'toilet',
  'tv',
  'laptop',
  'mouse',
  'remote',
  'keyboard',
  'cell phone',
  'microwave',
  'oven',
  'toaster',
  'sink',
  'refrigerator',
  'book',
  'clock',
  'vase',
  'scissors',
  'teddy bear',
  'hair drier',
  'toothbrush',
];

class AiDetector {
  Interpreter? _interpreter;
  IsolateInterpreter? _isolateInterpreter;
  bool _isLoaded = false;
  bool _isLoading = false;

  // ВАЖНО: входной/выходной тензоры хранятся как ПЛОСКИЕ типизированные буферы
  // (Uint8List/сырые байты + typed-view поверх), а не как вложенные
  // List<List<List<...>>>.
  //
  // КРИТИЧЕСКИЙ ФИКС ПРОИЗВОДИТЕЛЬНОСТИ: tflite_flutter при передаче/приёме
  // вложенных Dart-списков через IsolateInterpreter вынужден:
  //  1) сериализовать входной список поэлементно при отправке в изолят
  //     (SendPort.send копирует граф объектов синхронно в ВЫЗЫВАЮЩЕМ изоляте,
  //     т.е. в UI/main isolate) — для 640×640×3 = 1 228 800 элементов это
  //     сотни миллисекунд/секунды;
  //  2) на приёме — Tensor.copyTo() для не-typed dst вызывает
  //     _convertBytesToObject(), который заново строит ВЛОЖЕННЫЙ список из
  //     700 000+ элементов (например YOLO [1,84,8400]) — тоже на UI isolate.
  // Именно это блокировало UI/main isolate на каждый кадр AI и роняло не
  // только AI FPS, но и NET FPS (счётчик кадров UDP считается в том же
  // isolate и не может обновляться, пока он занят этой конвертацией).
  //
  // Uint8List/ByteBuffer у tflite_flutter имеют быстрый путь без такой
  // конвертации — поэтому используем только их.
  Uint8List? _inputBytes;
  Float32List? _inputFloatView;
  Int8List? _inputInt8View;

  Map<int, Uint8List>? _outputBuffers;
  Map<int, Object>? _outputViews; // Float32List | Int8List | Uint8List

  /// Берётся из shape модели при загрузке (не хардкодим 416/640).
  int _inputSize = 640;
  /// 0.25 давал кучу ложных person на шуме/фоне.
  static const double _confThreshold = 0.45;
  static const double _nmsThreshold = 0.45;
  static const int _maxCandidatesForNms = 100;
  /// Отсекаем крошечные боксы (шум модели).
  static const double _minBoxArea = 0.008;

  /// Только классы, нужные для безопасности/навигации — остальное не
  /// парсим и не гоняем через NMS (экономия CPU на постпроцессе).
  static const Set<int> _safetyClassIdx = {
    0, // person
    1, // bicycle
    2, // car
    3, // motorcycle
    5, // bus
    7, // truck
    9, // traffic light
    11, // stop sign
    16, // dog
    13, // bench (часто у края тротуара)
  };

  int get inputSize => _inputSize;
  bool get isReady => _isLoaded;

  Future<void> initModel() async {
    if (_isLoading || _isLoaded) return;
    _isLoading = true;
    try {
      debugPrint("🔧 Loading TFLite model directly...");

      _interpreter = await _loadInterpreterWithBestAccel();

      _isolateInterpreter = await IsolateInterpreter.create(
        address: _interpreter!.address,
      );

      final intNum = _interpreter!.getInputTensors().length;
      debugPrint("ℹ️ Input tensors count: $intNum");
      for (int i = 0; i < intNum; i++) {
        final t = _interpreter!.getInputTensor(i);
        debugPrint(
          "  Input #$i: name=${t.name}, shape=${t.shape}, type=${t.type}, qParams=(scale: ${t.params.scale}, zeroPoint: ${t.params.zeroPoint})",
        );
      }

      // NHWC: [1, H, W, 3] или NCHW: [1, 3, H, W]
      final inShape = _interpreter!.getInputTensor(0).shape;
      if (inShape.length >= 4) {
        if (inShape[1] == 3) {
          _inputSize = inShape[2];
        } else {
          _inputSize = inShape[1];
        }
      }
      debugPrint("ℹ️ Using model input size: $_inputSize");

      final outNum = _interpreter!.getOutputTensors().length;
      debugPrint("ℹ️ Output tensors count: $outNum");
      for (int i = 0; i < outNum; i++) {
        final t = _interpreter!.getOutputTensor(i);
        debugPrint(
          "  Output #$i: name=${t.name}, shape=${t.shape}, type=${t.type}, qParams=(scale: ${t.params.scale}, zeroPoint: ${t.params.zeroPoint})",
        );
      }

      _prepareInputBuffers(_interpreter!.getInputTensor(0).type, _inputSize);
      _prepareOutputBuffers();

      final inType = _interpreter!.getInputTensor(0).type;
      if (inType == TensorType.int8 || inType == TensorType.uint8) {
        debugPrint(
          '⚠️ Quantized TFLite model detected ($inType). '
          'INT8 YOLO exports often break on CONCATENATION — prefer float16/float32.',
        );
      }

      _isLoaded = true;
    } catch (e, stack) {
      debugPrint("❌ Error loading model: $e");
      debugPrint("❌ Stack: $stack");
      _isLoaded = false;
      _interpreter = null;
      _isolateInterpreter = null;
    } finally {
      _isLoading = false;
    }
  }

  /// CPU only (multi-threaded).
  ///
  /// XNNPACK специально НЕ используем: на части устройств (TECNO/MediaTek и др.)
  /// `TfLiteXNNPackDelegateCreateWithThreadpool` даёт SIGSEGV — нативный краш,
  /// который Dart try/catch поймать не может, поэтому «fallback» бесполезен.
  ///
  /// GPU-делегат тоже НЕ используем вместе с IsolateInterpreter:
  /// OpenCL/GL-контекст привязан к потоку, и invoke из другого изолята
  /// часто падает или зависает — AI тогда «живёт» на 0–1 FPS.
  Future<Interpreter> _loadInterpreterWithBestAccel() async {
    final opts = InterpreterOptions()..threads = 4;
    final interp = await Interpreter.fromAsset(
      'assets/models/best.tflite',
      options: opts,
    );
    debugPrint('✅ TFLite accelerator: CPU ×4');
    return interp;
  }

  void _prepareInputBuffers(TensorType type, int size) {
    final int elemSize = type == TensorType.float32 ? 4 : 1;
    final bytes = Uint8List(size * size * 3 * elemSize);
    _inputBytes = bytes;
    if (type == TensorType.float32) {
      _inputFloatView = Float32List.view(bytes.buffer);
      _inputInt8View = null;
    } else if (type == TensorType.int8) {
      _inputFloatView = null;
      _inputInt8View = Int8List.view(bytes.buffer);
    } else {
      _inputFloatView = null;
      _inputInt8View = null;
    }
  }

  void _prepareOutputBuffers() {
    final numOutputs = _interpreter!.getOutputTensors().length;
    _outputBuffers = {};
    _outputViews = {};
    for (int i = 0; i < numOutputs; i++) {
      final t = _interpreter!.getOutputTensor(i);
      final bytes = Uint8List(t.numBytes());
      _outputBuffers![i] = bytes;
      _outputViews![i] = _typedViewFor(bytes, t.type);
    }
  }

  /// Плоский typed-view поверх сырых байт тензора — без поэлементного бокса.
  Object _typedViewFor(Uint8List bytes, TensorType type) {
    switch (type) {
      case TensorType.float32:
        return Float32List.view(bytes.buffer, 0, bytes.length ~/ 4);
      case TensorType.int8:
        return Int8List.view(bytes.buffer, 0, bytes.length);
      case TensorType.int32:
        return Int32List.view(bytes.buffer, 0, bytes.length ~/ 4);
      case TensorType.int16:
        return Int16List.view(bytes.buffer, 0, bytes.length ~/ 2);
      default:
        return bytes; // uint8 и прочие 1-байтовые типы — сырые байты как есть
    }
  }

  Future<List<DetectedObject>> processFrame(Uint8List jpegBytes) async {
    if (!_isLoaded ||
        _isLoading ||
        _interpreter == null ||
        _isolateInterpreter == null) {
      return [];
    }

    final perf = PerfLogger.instance;
    final totalStart = DateTime.now().millisecondsSinceEpoch;

    try {
      final inputTensor = _interpreter!.getInputTensor(0);

      // Декодирование и ресайз через нативный C++ движок Flutter (Skia/Impeller).
      final decodeStart = DateTime.now().millisecondsSinceEpoch;
      final bool filled = await _fillInputBuffer(
        jpegBytes,
        _inputSize,
        inputTensor.type,
        inputTensor.params.scale,
        inputTensor.params.zeroPoint,
      );
      perf.log('decode', DateTime.now().millisecondsSinceEpoch - decodeStart,
          extra: 'jpeg=${jpegBytes.length}');

      if (!filled || _inputBytes == null) return [];

      final outputsMap = _outputBuffers;
      final outputViews = _outputViews;
      if (outputsMap == null || outputViews == null) return [];

      final inferStart = DateTime.now().millisecondsSinceEpoch;
      // Передаём ПЛОСКИЙ Uint8List — у tflite_flutter для него есть быстрый
      // путь (без поэлементной сериализации), а output-буферы тоже плоские
      // Uint8List, поэтому copyTo() не перестраивает вложенные списки.
      await _isolateInterpreter!.runForMultipleInputs(
        [_inputBytes!],
        outputsMap,
      );
      perf.log('inference', DateTime.now().millisecondsSinceEpoch - inferStart);

      final postStart = DateTime.now().millisecondsSinceEpoch;
      List<DetectedObject> results;
      final numOutputs = _interpreter!.getOutputTensors().length;
      if (numOutputs == 1) {
        final t0 = _interpreter!.getOutputTensor(0);
        final scale = t0.params.scale;
        final zeroPoint = t0.params.zeroPoint;
        results = _parseSingleOutput(
          outputViews[0]!,
          t0.shape,
          t0.type,
          scale,
          zeroPoint,
        );
      } else {
        results = _parseMultipleOutputs(outputViews);
      }
      perf.log('postprocess', DateTime.now().millisecondsSinceEpoch - postStart,
          extra: 'objects=${results.length}');

      perf.log('total_frame', DateTime.now().millisecondsSinceEpoch - totalStart);
      return results;
    } catch (e, stack) {
      debugPrint("❌ Inference error: $e");
      debugPrint("❌ Stack: $stack");
      return [];
    }
  }

  /// Нативное декодирование JPEG + быстрая упаковка в тензор.
  /// Пишет пиксели напрямую в плоский [_inputBytes] — без вложенных списков.
  Future<bool> _fillInputBuffer(
    Uint8List jpegBytes,
    int size,
    TensorType type,
    double scale,
    int zeroPoint,
  ) async {
    try {
      final ui.Codec codec = await ui.instantiateImageCodec(
        jpegBytes,
        targetWidth: size,
        targetHeight: size,
      );
      final ui.FrameInfo frameInfo = await codec.getNextFrame();
      final ui.Image uiImage = frameInfo.image;

      final ByteData? byteData = await uiImage.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      uiImage.dispose();

      if (byteData == null) return false;

      final Uint8List bytes = byteData.buffer.asUint8List(
        byteData.offsetInBytes,
        byteData.lengthInBytes,
      );

      final isQuantizedIn = type == TensorType.uint8 || type == TensorType.int8;

      if (isQuantizedIn) {
        final isUint8 = type == TensorType.uint8;
        final directCopy = isUint8 &&
            zeroPoint == 0 &&
            (scale == 0.0 || (scale - 1.0 / 255.0).abs() < 1e-5);

        if (isUint8 && directCopy) {
          // Быстрый путь: RGBA → RGB без вложенных циклов по y/x.
          final dst = _inputBytes!;
          final int n = size * size;
          int si = 0;
          int di = 0;
          for (int i = 0; i < n; i++) {
            dst[di] = bytes[si];
            dst[di + 1] = bytes[si + 1];
            dst[di + 2] = bytes[si + 2];
            si += 4;
            di += 3;
          }
        } else if (isUint8) {
          final double s = (scale == 0.0) ? 1.0 / 255.0 : scale;
          final dst = _inputBytes!;
          final int n = size * size;
          int si = 0;
          int di = 0;
          for (int i = 0; i < n; i++) {
            dst[di] =
                ((bytes[si] / 255.0) / s + zeroPoint).round().clamp(0, 255);
            dst[di + 1] =
                ((bytes[si + 1] / 255.0) / s + zeroPoint).round().clamp(0, 255);
            dst[di + 2] =
                ((bytes[si + 2] / 255.0) / s + zeroPoint).round().clamp(0, 255);
            si += 4;
            di += 3;
          }
        } else {
          final double s = (scale == 0.0) ? 1.0 / 255.0 : scale;
          final dst = _inputInt8View!;
          final int n = size * size;
          int si = 0;
          int di = 0;
          for (int i = 0; i < n; i++) {
            dst[di] =
                ((bytes[si] / 255.0) / s + zeroPoint).round().clamp(-128, 127);
            dst[di + 1] = ((bytes[si + 1] / 255.0) / s + zeroPoint)
                .round()
                .clamp(-128, 127);
            dst[di + 2] = ((bytes[si + 2] / 255.0) / s + zeroPoint)
                .round()
                .clamp(-128, 127);
            si += 4;
            di += 3;
          }
        }
        return true;
      }

      final dst = _inputFloatView!;
      final int n = size * size;
      int si = 0;
      int di = 0;
      for (int i = 0; i < n; i++) {
        dst[di] = bytes[si] / 255.0;
        dst[di + 1] = bytes[si + 1] / 255.0;
        dst[di + 2] = bytes[si + 2] / 255.0;
        si += 4;
        di += 3;
      }
      return true;
    } catch (e) {
      debugPrint("❌ Аппаратное декодирование не удалось: $e");
      return false;
    }
  }

  /// Метод деквантования нативного значения
  double _dequantize(num value, TensorType type, double scale, int zeroPoint) {
    if (type == TensorType.uint8 || type == TensorType.int8) {
      if (scale == 0.0) return value.toDouble();
      return (value.toInt() - zeroPoint) * scale;
    }
    return value.toDouble();
  }

  /// Разбор единого выхода YOLO [1, rows, cols] — без хардкода 8400.
  /// [out] — плоский typed-view (Float32List/Int8List/Uint8List), а НЕ
  /// вложенный список. Индексация вручную по формуле row*cols+col — это
  /// на порядки быстрее вложенных динамических списков.
  List<DetectedObject> _parseSingleOutput(
    Object out,
    List<int> shape,
    TensorType type,
    double scale,
    int zeroPoint,
  ) {
    final List<num> flat = out as List<num>;
    final int dim1 = shape[1];
    final int dim2 = shape[2];
    final List<DetectedObject> candidates = [];

    // YOLOv8/v11: либо [1, 4+C, N], либо [1, N, 4+C]
    final bool channelsFirst = dim1 < dim2 && dim1 <= 128;
    final int numPreds = channelsFirst ? dim2 : dim1;
    final int numClasses = (channelsFirst ? dim1 : dim2) - 4;

    if (numClasses <= 0 || numPreds <= 0) return [];

    if (channelsFirst) {
      // flat[ch*dim2 + col] соответствует out[0][ch][col]
      for (int col = 0; col < numPreds; col++) {
        double maxConf = 0.0;
        int maxClass = -1;
        // Глобальный argmax по всем классам — иначе остаточный score person
        // побеждает среди «безопасности», хотя модель уверена в другом классе.
        for (int c = 0; c < numClasses; c++) {
          final conf = _dequantize(
            flat[(4 + c) * dim2 + col],
            type,
            scale,
            zeroPoint,
          );
          if (conf > maxConf) {
            maxConf = conf;
            maxClass = c;
          }
        }
        if (maxClass < 0 ||
            maxConf < _confThreshold ||
            !_safetyClassIdx.contains(maxClass)) {
          continue;
        }
        _addCandidate(
          candidates,
          _dequantize(flat[0 * dim2 + col], type, scale, zeroPoint),
          _dequantize(flat[1 * dim2 + col], type, scale, zeroPoint),
          _dequantize(flat[2 * dim2 + col], type, scale, zeroPoint),
          _dequantize(flat[3 * dim2 + col], type, scale, zeroPoint),
          maxConf,
          maxClass,
        );
      }
    } else {
      // flat[row*dim2 + k] соответствует out[0][row][k]
      for (int row = 0; row < numPreds; row++) {
        final int base = row * dim2;
        double maxConf = 0.0;
        int maxClass = -1;
        for (int c = 0; c < numClasses; c++) {
          final conf = _dequantize(flat[base + 4 + c], type, scale, zeroPoint);
          if (conf > maxConf) {
            maxConf = conf;
            maxClass = c;
          }
        }
        if (maxClass < 0 ||
            maxConf < _confThreshold ||
            !_safetyClassIdx.contains(maxClass)) {
          continue;
        }
        _addCandidate(
          candidates,
          _dequantize(flat[base + 0], type, scale, zeroPoint),
          _dequantize(flat[base + 1], type, scale, zeroPoint),
          _dequantize(flat[base + 2], type, scale, zeroPoint),
          _dequantize(flat[base + 3], type, scale, zeroPoint),
          maxConf,
          maxClass,
        );
      }
    }

    return _nms(candidates);
  }

  /// Разбор множественных выходов YOLO. [outputsMap] — плоские typed-view'ы.
  List<DetectedObject> _parseMultipleOutputs(Map<int, Object> outputsMap) {
    final List<DetectedObject> candidates = [];

    final boxesTensor = _interpreter!.getOutputTensor(0);
    final scoresTensor = _interpreter!.getOutputTensor(1);

    final List<num> boxesList = outputsMap[0] as List<num>;

    final bScale = boxesTensor.params.scale;
    final bZero = boxesTensor.params.zeroPoint;
    final bType = boxesTensor.type;

    final sScale = scoresTensor.params.scale;
    final sZero = scoresTensor.params.zeroPoint;
    final sType = scoresTensor.type;

    final scoresShape = scoresTensor.shape;

    if (scoresShape.length == 3) {
      final int numPreds = scoresShape[1];
      final int numClasses = scoresShape[2];
      final List<num> scoresList = outputsMap[1] as List<num>;

      for (int i = 0; i < numPreds; i++) {
        final int scoreBase = i * numClasses;
        double maxConf = 0.0;
        int maxClass = -1;
        for (int c = 0; c < numClasses; c++) {
          final num rawConf = scoresList[scoreBase + c];
          final conf = _dequantize(rawConf, sType, sScale, sZero);
          if (conf > maxConf) {
            maxConf = conf;
            maxClass = c;
          }
        }

        if (maxClass < 0 ||
            maxConf < _confThreshold ||
            !_safetyClassIdx.contains(maxClass)) {
          continue;
        }

        final int boxBase = i * 4;
        final double cx = _dequantize(boxesList[boxBase], bType, bScale, bZero);
        final double cy =
            _dequantize(boxesList[boxBase + 1], bType, bScale, bZero);
        final double bw =
            _dequantize(boxesList[boxBase + 2], bType, bScale, bZero);
        final double bh =
            _dequantize(boxesList[boxBase + 3], bType, bScale, bZero);

        _addCandidate(candidates, cx, cy, bw, bh, maxConf, maxClass);
      }
    } else if (scoresShape.length == 2) {
      final List<num> scoresList = outputsMap[1] as List<num>;
      final int numPreds = scoresShape[1];

      List<num>? classIdxList;
      double cScale = 1.0;
      int cZero = 0;
      TensorType cType = TensorType.float32;

      if (_interpreter!.getOutputTensors().length > 2) {
        final classIdxTensor = _interpreter!.getOutputTensor(2);
        classIdxList = outputsMap[2] as List<num>;
        cScale = classIdxTensor.params.scale;
        cZero = classIdxTensor.params.zeroPoint;
        cType = classIdxTensor.type;
      }

      // Без тензора классов нельзя угадывать person (раньше maxClass=0 по умолчанию).
      if (classIdxList == null) {
        debugPrint('⚠️ Multi-output 2D scores без classIdx — пропускаем');
        return _nms(candidates);
      }

      for (int i = 0; i < numPreds; i++) {
        final num rawConf = scoresList[i];
        final conf = _dequantize(rawConf, sType, sScale, sZero);

        if (conf < _confThreshold) continue;

        final num rawClass = classIdxList[i];
        final int maxClass =
            _dequantize(rawClass, cType, cScale, cZero).round();
        if (!_safetyClassIdx.contains(maxClass)) continue;

        final int boxBase = i * 4;
        final double cx = _dequantize(boxesList[boxBase], bType, bScale, bZero);
        final double cy =
            _dequantize(boxesList[boxBase + 1], bType, bScale, bZero);
        final double bw =
            _dequantize(boxesList[boxBase + 2], bType, bScale, bZero);
        final double bh =
            _dequantize(boxesList[boxBase + 3], bType, bScale, bZero);

        _addCandidate(candidates, cx, cy, bw, bh, conf, maxClass);
      }
    }

    return _nms(candidates);
  }

  void _addCandidate(
    List<DetectedObject> candidates,
    double cx,
    double cy,
    double bw,
    double bh,
    double score,
    int classIdx,
  ) {
    double x = cx;
    double y = cy;
    double w = bw;
    double h = bh;

    if (x > 1.0 || y > 1.0 || w > 1.0 || h > 1.0) {
      x /= _inputSize;
      y /= _inputSize;
      w /= _inputSize;
      h /= _inputSize;
    }

    final double top = (y - h / 2).clamp(0.0, 1.0);
    final double left = (x - w / 2).clamp(0.0, 1.0);
    final double bottom = (y + h / 2).clamp(0.0, 1.0);
    final double right = (x + w / 2).clamp(0.0, 1.0);

    final area = (bottom - top) * (right - left);
    if (area < _minBoxArea) return;

    final String label = (classIdx < _cocoLabels.length)
        ? _cocoLabels[classIdx]
        : 'class_$classIdx';

    candidates.add(DetectedObject(label, score, [top, left, bottom, right]));
  }

  List<DetectedObject> _nms(List<DetectedObject> candidates) {
    if (candidates.isEmpty) return candidates;

    candidates.sort((a, b) => b.score.compareTo(a.score));

    // КРИТИЧЕСКИЙ ФИКС: ограничиваем число кандидатов перед NMS.
    // Без этого при насыщенной сцене (несколько машин/людей) число кандидатов
    // могло доходить до тысяч (десятки якорей на каждый реальный объект),
    // а наивный NMS ниже — O(n²), что и роняло FPS именно в такие моменты.
    final List<DetectedObject> trimmed =
        candidates.length > _maxCandidatesForNms
        ? candidates.sublist(0, _maxCandidatesForNms)
        : candidates;

    // КРИТИЧЕСКИЙ ФИКС: группируем кандидатов по классу и считаем IoU только
    // внутри одного класса (машину с машиной, человека с человеком), а не
    // "каждого с каждым" по всему кадру. Это снижает число сравнений в разы
    // на сценах с разными типами объектов, а возможные перекрытия разных
    // классов (человек на фоне машины) — это и не должно подавляться NMS.
    final Map<String, List<DetectedObject>> buckets = {};
    for (final c in trimmed) {
      buckets.putIfAbsent(c.label, () => []).add(c);
    }

    final List<DetectedObject> result = [];
    for (final bucket in buckets.values) {
      final List<bool> suppressed = List.filled(bucket.length, false);
      for (int i = 0; i < bucket.length; i++) {
        if (suppressed[i]) continue;
        result.add(bucket[i]);
        for (int j = i + 1; j < bucket.length; j++) {
          if (suppressed[j]) continue;
          if (_iou(bucket[i].rect, bucket[j].rect) > _nmsThreshold) {
            suppressed[j] = true;
          }
        }
      }
    }

    result.sort((a, b) => b.score.compareTo(a.score));
    return result;
  }

  double _iou(List<double> a, List<double> b) {
    final double interTop = max(a[0], b[0]);
    final double interLeft = max(a[1], b[1]);
    final double interBottom = min(a[2], b[2]);
    final double interRight = min(a[3], b[3]);
    if (interBottom <= interTop || interRight <= interLeft) return 0.0;
    final double interArea =
        (interBottom - interTop) * (interRight - interLeft);
    final double aArea = (a[2] - a[0]) * (a[3] - a[1]);
    final double bArea = (b[2] - b[0]) * (b[3] - b[1]);
    return interArea / (aArea + bArea - interArea + 1e-6);
  }

  Future<void> dispose() async {
    await _isolateInterpreter?.close();
    _isolateInterpreter = null;
    _interpreter?.close();
    _interpreter = null;
    _isLoaded = false;
    _isLoading = false;
  }
}
