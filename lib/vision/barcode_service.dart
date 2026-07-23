import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';
import 'package:path_provider/path_provider.dart';

/// Сканер QR / штрихкодов (офлайн ML Kit).
class BarcodeService {
  final Future<void> Function(String text, {int? priority}) _enqueue;
  final BarcodeScanner _scanner = BarcodeScanner();

  BarcodeService({
    required Future<void> Function(String text, {int? priority}) enqueueCallback,
  }) : _enqueue = enqueueCallback;

  Future<void> scan(Uint8List jpeg) async {
    await _enqueue('Ищу штрихкод...', priority: 0);
    try {
      final dir = await getTemporaryDirectory();
      final file = File(
        '${dir.path}/barcode_${DateTime.now().millisecondsSinceEpoch}.jpg',
      );
      await file.writeAsBytes(jpeg, flush: true);
      final input = InputImage.fromFilePath(file.path);
      final codes = await _scanner.processImage(input);
      try {
        await file.delete();
      } catch (_) {}

      if (codes.isEmpty) {
        await _enqueue(
          'Штрихкод не найден. Наведите камеру ближе и держите ровно.',
          priority: 0,
        );
        return;
      }

      final b = codes.first;
      final value = b.displayValue ?? b.rawValue ?? '';
      final type = _typeRu(b.format);
      if (value.isEmpty) {
        await _enqueue('Код найден, но значение пустое.', priority: 0);
        return;
      }
      // Не ходим в Google Product — только значение кода.
      final short = value.length > 80 ? '${value.substring(0, 80)}...' : value;
      await _enqueue('$type: $short', priority: 0);
    } catch (e) {
      debugPrint('BarcodeService error: $e');
      await _enqueue(
        'Сканер штрихкода недоступен на этом устройстве.',
        priority: 0,
      );
    }
  }

  String _typeRu(BarcodeFormat format) {
    final name = format.name.toLowerCase();
    if (name.contains('qr')) return 'QR-код';
    if (name.contains('ean') || name.contains('upc')) return 'Штрихкод товара';
    if (name.contains('url')) return 'Ссылка';
    if (name.contains('phone') || name.contains('tel')) return 'Телефон';
    if (name.contains('wifi')) return 'Wi-Fi';
    if (name.contains('contact')) return 'Контакт';
    return 'Код';
  }

  void dispose() {
    _scanner.close();
  }
}
