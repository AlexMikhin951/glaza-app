import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'dart:io';

/// Распознавание российских купюр: OCR номинала + эвристики цвета.
/// Полный TFLite-классификатор можно подключить позже (assets/models/currency.tflite).
class CurrencyService {
  final Future<void> Function(String text, {int? priority}) _enqueue;
  final TextRecognizer _ocr = TextRecognizer(
    script: TextRecognitionScript.latin,
  );

  static const _denoms = [10, 50, 100, 200, 500, 1000, 2000, 5000];

  CurrencyService({
    required Future<void> Function(String text, {int? priority}) enqueueCallback,
  }) : _enqueue = enqueueCallback;

  Future<void> recognize(Uint8List jpeg) async {
    await _enqueue('Смотрю купюру...', priority: 0);

    final fromOcr = await _fromOcr(jpeg);
    if (fromOcr != null) {
      await _enqueue('Купюра: $fromOcr рублей.', priority: 0);
      return;
    }

    final fromColor = await compute(_fromColorHeuristics, jpeg);
    if (fromColor != null) {
      await _enqueue(
        'Похоже на купюру $fromColor рублей. Для точности наведите ближе на номинал.',
        priority: 0,
      );
      return;
    }

    await _enqueue(
      'Купюру не распознал. Разверните банкноту и наведите на цифру номинала.',
      priority: 0,
    );
  }

  Future<int?> _fromOcr(Uint8List jpeg) async {
    try {
      final dir = await getTemporaryDirectory();
      final file = File(
        '${dir.path}/currency_${DateTime.now().millisecondsSinceEpoch}.jpg',
      );
      await file.writeAsBytes(jpeg, flush: true);
      final input = InputImage.fromFilePath(file.path);
      final result = await _ocr.processImage(input);
      try {
        await file.delete();
      } catch (_) {}

      final text = result.text.replaceAll(RegExp(r'\s+'), ' ');
      final lower = text.toLowerCase();

      // Явные номиналы
      for (final d in _denoms.reversed) {
        if (RegExp('\\b$d\\b').hasMatch(text) ||
            lower.contains('$d руб') ||
            lower.contains('банк россии') && text.contains('$d')) {
          // Предпочитаем более крупные номиналы при нескольких совпадениях —
          // идём от больших к малым.
          return d;
        }
      }

      // Прописью
      const words = {
        'десять': 10,
        'пятьдесят': 50,
        'сто': 100,
        'двести': 200,
        'пятьсот': 500,
        'тысяча': 1000,
        'две тысячи': 2000,
        'пять тысяч': 5000,
      };
      for (final e in words.entries) {
        if (lower.contains(e.key)) return e.value;
      }
    } catch (e) {
      debugPrint('CurrencyService OCR error: $e');
    }
    return null;
  }

  /// Грубая цветовая эвристика РФ (ориентир, не сертификация).
  static int? _fromColorHeuristics(Uint8List jpeg) {
    final decoded = img.decodeJpg(jpeg);
    if (decoded == null) return null;
    final w = decoded.width;
    final h = decoded.height;
    double r = 0, g = 0, b = 0;
    var n = 0;
    for (var y = (h * 0.2).round(); y < (h * 0.8); y += 3) {
      for (var x = (w * 0.15).round(); x < (w * 0.85); x += 3) {
        final p = decoded.getPixel(x, y);
        r += p.r;
        g += p.g;
        b += p.b;
        n++;
      }
    }
    if (n == 0) return null;
    r /= n;
    g /= n;
    b /= n;

    // Очень грубо по палитре Банка России
    if (r > 140 && g < 110 && b < 110) return 5000; // красная
    if (r > 130 && g > 100 && b < 90) return 5000;
    if (b > 130 && r < 120) return 2000; // синяя
    if (g > 120 && r < 110 && b < 110) return 200; // зелёная
    if (r > 150 && g > 120 && b < 100) return 500; // красно-коричневая
    if (b > 110 && g > 100 && r < 100) return 1000; // сине-зелёная
    if (r > 160 && g > 140 && b < 120) return 100; // жёлто-коричневая
    if (b > 100 && r > 100 && g < 100) return 50; // сине-розовая
    return null;
  }

  void dispose() {
    _ocr.close();
  }
}
