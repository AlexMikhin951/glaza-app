import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Локальные «известные лица» — без облака и без зарубежных API.
/// Эмбеддинг: даунскейл 32×32 grayscale + L2-норма; матч по косинусу.
class FaceService {
  final Future<void> Function(String text, {int? priority}) _enqueue;
  final FaceDetector _detector = FaceDetector(
    options: FaceDetectorOptions(
      performanceMode: FaceDetectorMode.fast,
      enableLandmarks: false,
      enableContours: false,
    ),
  );

  final List<_KnownFace> _known = [];
  bool _enabled = true;
  int _lastAnnounceMs = 0;
  String _lastName = '';
  static const _cooldownMs = 12000;
  static const _matchThreshold = 0.82;

  FaceService({
    required Future<void> Function(String text, {int? priority}) enqueueCallback,
  }) : _enqueue = enqueueCallback;

  List<String> get knownNames => _known.map((f) => f.name).toList();

  Future<void> init() async {
    await _load();
    debugPrint('✅ FaceService ready, known=${_known.length}');
  }

  void enable() => _enabled = true;
  void disable() => _enabled = false;

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('known_faces_v1');
      if (raw == null) return;
      final list = jsonDecode(raw) as List;
      _known.clear();
      for (final e in list) {
        final m = e as Map<String, dynamic>;
        final name = m['name'] as String? ?? '';
        final emb = (m['emb'] as List).map((v) => (v as num).toDouble()).toList();
        if (name.isNotEmpty && emb.length == 32 * 32) {
          _known.add(_KnownFace(name, Float32List.fromList(emb)));
        }
      }
    } catch (e) {
      debugPrint('FaceService load: $e');
    }
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    final list = _known
        .map((f) => {'name': f.name, 'emb': f.embedding.toList()})
        .toList();
    await prefs.setString('known_faces_v1', jsonEncode(list));
  }

  /// «Запомни лицо Мама» / «это Иван».
  Future<bool> handleCommand(String command, Uint8List? jpeg) async {
    final cmd = command.toLowerCase().trim();
    if (cmd.contains('забыть лицо') || cmd.contains('удали лицо')) {
      for (final f in List.of(_known)) {
        if (cmd.contains(f.name.toLowerCase())) {
          _known.removeWhere((k) => k.name == f.name);
          await _save();
          await _enqueue('Лицо ${f.name} удалено.', priority: 1);
          return true;
        }
      }
      await _enqueue('Скажите: забудь лицо и имя.', priority: 0);
      return true;
    }

    if (cmd.contains('мои лица') || cmd.contains('список лиц')) {
      if (_known.isEmpty) {
        await _enqueue('Известных лиц нет. Скажите: запомни лицо и имя.', priority: 0);
      } else {
        await _enqueue(
          'Известные: ${_known.map((f) => f.name).join(', ')}.',
          priority: 0,
        );
      }
      return true;
    }

    final enroll = RegExp(
      r'(запомни лицо|запомнить лицо|это|лицо)\s+([а-яёa-z0-9\- ]{2,40})',
      caseSensitive: false,
    ).firstMatch(cmd);
    if (enroll == null &&
        !(cmd.startsWith('запомни') && cmd.contains('лицо'))) {
      return false;
    }

    String? name;
    if (enroll != null) {
      name = enroll.group(2)?.trim();
    }
    if (name == null || name.isEmpty) {
      await _enqueue('Скажите: запомни лицо Мама.', priority: 0);
      return true;
    }
    // убрать хвосты
    name = name
        .replaceAll(RegExp(r'\bлицо\b'), '')
        .replaceAll(RegExp(r'\bпожалуйста\b'), '')
        .trim();
    if (name.isEmpty) {
      await _enqueue('Не понял имя. Скажите: запомни лицо и имя.', priority: 0);
      return true;
    }

    if (jpeg == null) {
      await _enqueue('Нет кадра. Наведите камеру на лицо.', priority: 0);
      return true;
    }

    await _enqueue('Запоминаю лицо $name...', priority: 1);
    final emb = await _embeddingFromJpeg(jpeg);
    if (emb == null) {
      await _enqueue(
        'Лицо не найдено. Попросите человека смотреть в камеру ближе.',
        priority: 1,
      );
      return true;
    }

    _known.removeWhere((k) => k.name.toLowerCase() == name!.toLowerCase());
    _known.add(_KnownFace(_cap(name), emb));
    await _save();
    await _enqueue('Запомнила: ${_cap(name)}.', priority: 1);
    return true;
  }

  String _cap(String s) {
    if (s.isEmpty) return s;
    return s[0].toUpperCase() + s.substring(1);
  }

  /// Фоновый матч в режиме улица/поиск (не чаще кулдауна).
  Future<void> onFrame(Uint8List jpeg) async {
    if (!_enabled || _known.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastAnnounceMs < _cooldownMs) return;

    final emb = await _embeddingFromJpeg(jpeg);
    if (emb == null) return;

    _KnownFace? best;
    var bestScore = 0.0;
    for (final k in _known) {
      final s = _cosine(emb, k.embedding);
      if (s > bestScore) {
        bestScore = s;
        best = k;
      }
    }
    if (best == null || bestScore < _matchThreshold) return;
    if (best.name == _lastName && now - _lastAnnounceMs < _cooldownMs * 2) {
      return;
    }
    _lastName = best.name;
    _lastAnnounceMs = now;
    await _enqueue('${best.name} рядом.', priority: 1);
  }

  Future<Float32List?> _embeddingFromJpeg(Uint8List jpeg) async {
    try {
      final dir = await getTemporaryDirectory();
      final file = File(
        '${dir.path}/face_${DateTime.now().millisecondsSinceEpoch}.jpg',
      );
      await file.writeAsBytes(jpeg, flush: true);
      final faces = await _detector.processImage(
        InputImage.fromFilePath(file.path),
      );
      try {
        await file.delete();
      } catch (_) {}
      if (faces.isEmpty) return null;

      // Берём самое крупное лицо
      faces.sort(
        (a, b) => (b.boundingBox.width * b.boundingBox.height)
            .compareTo(a.boundingBox.width * a.boundingBox.height),
      );
      final box = faces.first.boundingBox;
      final decoded = img.decodeJpg(jpeg);
      if (decoded == null) return null;

      final x = box.left.round().clamp(0, decoded.width - 1);
      final y = box.top.round().clamp(0, decoded.height - 1);
      final w = box.width.round().clamp(1, decoded.width - x);
      final h = box.height.round().clamp(1, decoded.height - y);
      final crop = img.copyCrop(decoded, x: x, y: y, width: w, height: h);
      final small = img.copyResize(crop, width: 32, height: 32);
      final emb = Float32List(32 * 32);
      var sum = 0.0;
      for (var i = 0; i < 32; i++) {
        for (var j = 0; j < 32; j++) {
          final p = small.getPixel(j, i);
          final v = (0.299 * p.r + 0.587 * p.g + 0.114 * p.b) / 255.0;
          emb[i * 32 + j] = v;
          sum += v * v;
        }
      }
      final norm = sqrt(sum);
      if (norm < 1e-6) return null;
      for (var i = 0; i < emb.length; i++) {
        emb[i] /= norm;
      }
      return emb;
    } catch (e) {
      debugPrint('FaceService emb: $e');
      return null;
    }
  }

  double _cosine(Float32List a, Float32List b) {
    var s = 0.0;
    for (var i = 0; i < a.length; i++) {
      s += a[i] * b[i];
    }
    return s;
  }

  void dispose() {
    _detector.close();
  }
}

class _KnownFace {
  final String name;
  final Float32List embedding;
  _KnownFace(this.name, this.embedding);
}
