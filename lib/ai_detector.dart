import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

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

  List<List<List<List<int>>>>? _quantizedInput;
  List<List<List<List<double>>>>? _floatInput;
  Map<int, Object>? _outputBuffers;

  static const int _inputSize = 640;
  static const double _confThreshold = 0.25;
  static const double _nmsThreshold = 0.45;
  // Ограничение числа кандидатов, попадающих в NMS. Без этого ограничения
  // при нескольких объектах в кадре десятки соседних якорей на каждый объект
  // дают n² рост сравнений в NMS и роняют FPS. 300 кандидатов более чем
  // достаточно даже для очень загруженной сцены.
  static const int _maxCandidatesForNms = 300;

  Future<void> initModel() async {
    if (_isLoading || _isLoaded) return;
    _isLoading = true;
    try {
      debugPrint("🔧 Loading TFLite model directly...");

      final options = InterpreterOptions()..threads = 2;

      _interpreter = await Interpreter.fromAsset(
        'assets/models/best.tflite',
        options: options,
      );

      // КРИТИЧЕСКИЙ ФИКС: оборачиваем интерпретатор в IsolateInterpreter.
      // Теперь runForMultipleInputs выполняется в отдельном изоляте и не блокирует
      // основной (UI/UDP) изолят на время инференса.
      _isolateInterpreter = await IsolateInterpreter.create(
        address: _interpreter!.address,
      );

      // --- ДИАГНОСТИЧЕСКИЙ ВЫВОД СТРУКТУРЫ МОДЕЛИ ---
      final intNum = _interpreter!.getInputTensors().length;
      debugPrint("ℹ️ Input tensors count: $intNum");
      for (int i = 0; i < intNum; i++) {
        final t = _interpreter!.getInputTensor(i);
        debugPrint(
          "  Input #$i: name=${t.name}, shape=${t.shape}, type=${t.type}, qParams=(scale: ${t.params.scale}, zeroPoint: ${t.params.zeroPoint})",
        );
      }

      final outNum = _interpreter!.getOutputTensors().length;
      debugPrint("ℹ️ Output tensors count: $outNum");
      for (int i = 0; i < outNum; i++) {
        final t = _interpreter!.getOutputTensor(i);
        debugPrint(
          "  Output #$i: name=${t.name}, shape=${t.shape}, type=${t.type}, qParams=(scale: ${t.params.scale}, zeroPoint: ${t.params.zeroPoint})",
        );
      }
      // ----------------------------------------------

      _prepareInputBuffers(_interpreter!.getInputTensor(0).type, _inputSize);
      _prepareOutputBuffers();
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

  void _prepareInputBuffers(TensorType type, int size) {
    if (type == TensorType.float32) {
      _floatInput = List.generate(
        1,
        (_) => List.generate(
          size,
          (y) => List.generate(size, (x) => List.filled(3, 0.0)),
        ),
      );
      _quantizedInput = null;
    } else {
      _quantizedInput = List.generate(
        1,
        (_) => List.generate(
          size,
          (y) => List.generate(size, (x) => List.filled(3, 0)),
        ),
      );
      _floatInput = null;
    }
  }

  void _prepareOutputBuffers() {
    final numOutputs = _interpreter!.getOutputTensors().length;
    _outputBuffers = {};
    for (int i = 0; i < numOutputs; i++) {
      final t = _interpreter!.getOutputTensor(i);
      _outputBuffers![i] = _createOutputBuffer(t.shape, t.type);
    }
  }

  Future<List<DetectedObject>> processFrame(Uint8List jpegBytes) async {
    if (!_isLoaded ||
        _isLoading ||
        _interpreter == null ||
        _isolateInterpreter == null) {
      return [];
    }

    try {
      final inputTensor = _interpreter!.getInputTensor(0);

      // КРИТИЧЕСКИЙ ФИКС: Используем нативный C++ декодер движка Flutter (Skia/Impeller).
      // Декодирование и ресайз происходят аппаратно за ~2-5 мс вместо 150 мс!
      final List<List<List<List<num>>>> input = await _imageToInput(
        jpegBytes,
        _inputSize,
        inputTensor.type,
        inputTensor.params.scale,
        inputTensor.params.zeroPoint,
      );

      if (input.isEmpty) return [];

      final outputsMap = _outputBuffers;
      if (outputsMap == null) return [];

      await _isolateInterpreter!.runForMultipleInputs([input], outputsMap);

      final numOutputs = _interpreter!.getOutputTensors().length;
      if (numOutputs == 1) {
        final t0 = _interpreter!.getOutputTensor(0);
        final scale = t0.params.scale;
        final zeroPoint = t0.params.zeroPoint;
        return _parseSingleOutput(
          outputsMap[0] as List,
          t0.shape,
          t0.type,
          scale,
          zeroPoint,
        );
      } else {
        return _parseMultipleOutputs(outputsMap);
      }
    } catch (e, stack) {
      debugPrint("❌ Inference error: $e");
      debugPrint("❌ Stack: $stack");
      return [];
    }
  }

  /// Нативное аппаратное декодирование JPEG и прямое преобразование в входной тензор
  Future<List<List<List<List<num>>>>> _imageToInput(
    Uint8List jpegBytes,
    int size,
    TensorType type,
    double scale,
    int zeroPoint,
  ) async {
    try {
      // Нативно декодируем и ресайзим JPEG силами графического движка Flutter
      final ui.Codec codec = await ui.instantiateImageCodec(
        jpegBytes,
        targetWidth: size,
        targetHeight: size,
      );
      final ui.FrameInfo frameInfo = await codec.getNextFrame();
      final ui.Image uiImage = frameInfo.image;

      // Получаем сырой RGBA-буфер байтов (4 байта на пиксель)
      final ByteData? byteData = await uiImage.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      uiImage.dispose(); // Немедленно освобождаем GPU-память кадра

      if (byteData == null) return [];

      final isQuantizedIn = type == TensorType.uint8 || type == TensorType.int8;
      final double s = (scale == 0.0) ? 1.0 / 255.0 : scale;
      final Uint8List bytes = byteData.buffer.asUint8List(
        byteData.offsetInBytes,
        byteData.lengthInBytes,
      );

      if (isQuantizedIn) {
        final imgList = _quantizedInput;
        if (imgList == null) return [];
        final isUint8 = type == TensorType.uint8;
        for (int y = 0; y < size; y++) {
          final int rowOffset = y * size * 4;
          final row = imgList[0][y];
          for (int x = 0; x < size; x++) {
            final int offset = rowOffset + x * 4;
            final double rVal = bytes[offset] / 255.0;
            final double gVal = bytes[offset + 1] / 255.0;
            final double bVal = bytes[offset + 2] / 255.0;
            final pixel = row[x];
            if (isUint8) {
              pixel[0] = ((rVal / s) + zeroPoint).round().clamp(0, 255);
              pixel[1] = ((gVal / s) + zeroPoint).round().clamp(0, 255);
              pixel[2] = ((bVal / s) + zeroPoint).round().clamp(0, 255);
            } else {
              pixel[0] = ((rVal / s) + zeroPoint).round().clamp(-128, 127);
              pixel[1] = ((gVal / s) + zeroPoint).round().clamp(-128, 127);
              pixel[2] = ((bVal / s) + zeroPoint).round().clamp(-128, 127);
            }
          }
        }
        return imgList;
      }

      final imgList = _floatInput;
      if (imgList == null) return [];
      for (int y = 0; y < size; y++) {
        final int rowOffset = y * size * 4;
        final row = imgList[0][y];
        for (int x = 0; x < size; x++) {
          final int offset = rowOffset + x * 4;
          final pixel = row[x];
          pixel[0] = bytes[offset] / 255.0;
          pixel[1] = bytes[offset + 1] / 255.0;
          pixel[2] = bytes[offset + 2] / 255.0;
        }
      }
      return imgList;
    } catch (e) {
      debugPrint("❌ Аппаратное декодирование не удалось: $e");
      return [];
    }
  }

  /// Создание динамического многомерного буфера заданной формы
  Object _createOutputBuffer(List<int> shape, TensorType type) {
    final bool isFloat = type == TensorType.float32;
    final num zeroValue = isFloat ? 0.0 : 0;

    Object build(int index) {
      if (index == shape.length - 1) {
        return List<num>.filled(shape[index], zeroValue);
      }
      return List<dynamic>.generate(shape[index], (_) => build(index + 1));
    }

    return build(0);
  }

  /// Метод деквантования нативного значения
  double _dequantize(num value, TensorType type, double scale, int zeroPoint) {
    if (type == TensorType.uint8 || type == TensorType.int8) {
      if (scale == 0.0) return value.toDouble();
      return (value.toInt() - zeroPoint) * scale;
    }
    return value.toDouble();
  }

  /// Разбор единого выхода YOLO [1, rows, cols]
  List<DetectedObject> _parseSingleOutput(
    List out,
    List<int> shape,
    TensorType type,
    double scale,
    int zeroPoint,
  ) {
    final int dim1 = shape[1];
    final int dim2 = shape[2];
    final List<DetectedObject> candidates = [];

    if (dim2 == 8400) {
      final int numClasses = dim1 - 4;
      for (int col = 0; col < 8400; col++) {
        double maxConf = 0.0;
        int maxClass = 0;
        for (int c = 0; c < numClasses; c++) {
          final num rawConf = out[0][4 + c][col];
          final conf = _dequantize(rawConf, type, scale, zeroPoint);
          if (conf > maxConf) {
            maxConf = conf;
            maxClass = c;
          }
        }

        if (maxConf < _confThreshold) continue;

        final double cx = _dequantize(out[0][0][col], type, scale, zeroPoint);
        final double cy = _dequantize(out[0][1][col], type, scale, zeroPoint);
        final double bw = _dequantize(out[0][2][col], type, scale, zeroPoint);
        final double bh = _dequantize(out[0][3][col], type, scale, zeroPoint);

        _addCandidate(candidates, cx, cy, bw, bh, maxConf, maxClass);
      }
    } else if (dim1 == 8400) {
      final int numClasses = dim2 - 4;
      for (int row = 0; row < 8400; row++) {
        double maxConf = 0.0;
        int maxClass = 0;
        for (int c = 0; c < numClasses; c++) {
          final num rawConf = out[0][row][4 + c];
          final conf = _dequantize(rawConf, type, scale, zeroPoint);
          if (conf > maxConf) {
            maxConf = conf;
            maxClass = c;
          }
        }

        if (maxConf < _confThreshold) continue;

        final double cx = _dequantize(out[0][row][0], type, scale, zeroPoint);
        final double cy = _dequantize(out[0][row][1], type, scale, zeroPoint);
        final double bw = _dequantize(out[0][row][2], type, scale, zeroPoint);
        final double bh = _dequantize(out[0][row][3], type, scale, zeroPoint);

        _addCandidate(candidates, cx, cy, bw, bh, maxConf, maxClass);
      }
    }

    return _nms(candidates);
  }

  /// Разбор множественных выходов YOLO
  List<DetectedObject> _parseMultipleOutputs(Map<int, Object> outputsMap) {
    final List<DetectedObject> candidates = [];

    final boxesTensor = _interpreter!.getOutputTensor(0);
    final scoresTensor = _interpreter!.getOutputTensor(1);

    final boxesList = outputsMap[0] as List;

    final bScale = boxesTensor.params.scale;
    final bZero = boxesTensor.params.zeroPoint;
    final bType = boxesTensor.type;

    final sScale = scoresTensor.params.scale;
    final sZero = scoresTensor.params.zeroPoint;
    final sType = scoresTensor.type;

    final scoresShape = scoresTensor.shape;

    if (scoresShape.length == 3) {
      final int numClasses = scoresShape[2];
      final scoresList = outputsMap[1] as List;

      for (int i = 0; i < 8400; i++) {
        double maxConf = 0.0;
        int maxClass = 0;
        for (int c = 0; c < numClasses; c++) {
          final num rawConf = scoresList[0][i][c];
          final conf = _dequantize(rawConf, sType, sScale, sZero);
          if (conf > maxConf) {
            maxConf = conf;
            maxClass = c;
          }
        }

        if (maxConf < _confThreshold) continue;

        final double cx = _dequantize(boxesList[0][i][0], bType, bScale, bZero);
        final double cy = _dequantize(boxesList[0][i][1], bType, bScale, bZero);
        final double bw = _dequantize(boxesList[0][i][2], bType, bScale, bZero);
        final double bh = _dequantize(boxesList[0][i][3], bType, bScale, bZero);

        _addCandidate(candidates, cx, cy, bw, bh, maxConf, maxClass);
      }
    } else if (scoresShape.length == 2) {
      final scoresList = outputsMap[1] as List;

      List? classIdxList;
      double cScale = 1.0;
      int cZero = 0;
      TensorType cType = TensorType.float32;

      if (_interpreter!.getOutputTensors().length > 2) {
        final classIdxTensor = _interpreter!.getOutputTensor(2);
        classIdxList = outputsMap[2] as List;
        cScale = classIdxTensor.params.scale;
        cZero = classIdxTensor.params.zeroPoint;
        cType = classIdxTensor.type;
      }

      for (int i = 0; i < 8400; i++) {
        final num rawConf = scoresList[0][i];
        final conf = _dequantize(rawConf, sType, sScale, sZero);

        if (conf < _confThreshold) continue;

        int maxClass = 0;
        if (classIdxList != null) {
          final num rawClass = classIdxList[0][i];
          maxClass = _dequantize(rawClass, cType, cScale, cZero).round();
        }

        final double cx = _dequantize(boxesList[0][i][0], bType, bScale, bZero);
        final double cy = _dequantize(boxesList[0][i][1], bType, bScale, bZero);
        final double bw = _dequantize(boxesList[0][i][2], bType, bScale, bZero);
        final double bh = _dequantize(boxesList[0][i][3], bType, bScale, bZero);

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
