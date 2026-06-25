import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// OCR и анализ текста: ценники, состав, аллергены.
class ReadingService {
  final Future<void> Function(String text, {int priority}) _enqueue;

  /// Latin-модель ML Kit распознаёт и кириллицу (русские этикетки).
  final TextRecognizer _recognizer = TextRecognizer(
    script: TextRecognitionScript.latin,
  );
  List<String> _userAllergens = [];
  bool _isScanning = false;

  static const Map<String, List<String>> _synonyms = {
    'глютен': [
      'пшеница', 'ячмень', 'рожь', 'овёс', 'мука', 'крахмал пшеничный',
      'gluten', 'wheat', 'barley', 'rye', 'oat',
    ],
    'лактоза': [
      'молоко', 'сливки', 'сыворотка', 'лактоза', 'казеин', 'масло сливочное',
      'lactose', 'milk', 'dairy', 'cream', 'whey', 'casein',
    ],
    'арахис': ['арахис', 'арахисовое масло', 'groundnut', 'peanut', 'arachis'],
    'соя': ['соя', 'соевый', 'soy', 'soya', 'соевый лецитин'],
    'яйца': ['яйцо', 'яйца', 'яичный', 'egg', 'eggs', 'albumin', 'albumen'],
    'орехи': [
      'миндаль', 'фундук', 'кешью', 'грецкий орех',
      'almond', 'hazelnut', 'cashew', 'walnut', 'nut',
    ],
    'рыба': ['рыба', 'треска', 'тунец', 'лосось', 'fish', 'cod', 'tuna'],
    'морепродукты': [
      'креветки', 'краб', 'кальмар', 'shrimp', 'crab', 'shellfish',
    ],
    'сельдерей': ['сельдерей', 'celery'],
    'горчица': ['горчица', 'mustard'],
    'кунжут': ['кунжут', 'sesame', 'tahini'],
    'сульфиты': ['сульфит', 'sulfite', 'sulphite', 'диоксид серы', 'e220'],
    'люпин': ['люпин', 'lupin'],
    'моллюски': ['моллюск', 'устрица', 'oyster', 'mollusc'],
  };

  static final RegExp _pricePattern = RegExp(
    r'(\d[\d\s]{0,7}[.,]\d{2})\s*(₽|руб\.?|р\.?|rub)?|(\d[\d\s]{0,7})\s*(₽|руб\.?|р\.?)',
    caseSensitive: false,
  );

  ReadingService({
    required Future<void> Function(String text, {int priority}) enqueueCallback,
  }) : _enqueue = enqueueCallback;
  Future<void> init() async {
    await _loadProfile();
    debugPrint('✅ ReadingService initialized, allergens: $_userAllergens');
  }

  Future<void> _loadProfile() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getStringList('user_allergens');
      _userAllergens = saved ?? [];
    } catch (e) {
      debugPrint('ReadingService: load profile error: $e');
    }
  }

  Future<void> saveProfile(List<String> allergens) async {
    _userAllergens = allergens
        .map((a) => a.trim().toLowerCase())
        .where((a) => a.isNotEmpty)
        .toSet()
        .toList();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('user_allergens', _userAllergens);
    } catch (e) {
      debugPrint('ReadingService: save profile error: $e');
    }
  }

  List<String> get userAllergens => List.unmodifiable(_userAllergens);
  List<String> get availableAllergens => _synonyms.keys.toList();
  bool get isScanning => _isScanning;

  /// Распознаёт и озвучивает текст с фото (ценник, состав, аллергены).
  Future<void> analyzePhoto(Uint8List jpegBytes) async {
    if (_isScanning) return;
    _isScanning = true;

    try {
      await _enqueue('Сканирую текст...', priority: 0);

      final text = await _recognizeText(jpegBytes);
      if (text.trim().isEmpty) {
        await _enqueue(
          'Текст не найден. Наведите камеру на ценник или этикетку.',
          priority: 0,
        );
        return;
      }

      final lower = text.toLowerCase();
      final messages = <String>[];
      var priority = 0;

      final prices = _extractPrices(text);
      if (prices.isNotEmpty) {
        messages.add('Цена: ${prices.first}');
        if (prices.length > 1) {
          messages.add('Ещё цены: ${prices.skip(1).take(2).join(", ")}');
        }
      }

      final composition = _extractComposition(text, lower);
      if (composition != null) {
        final short = composition.length > 220
            ? '${composition.substring(0, 220)}...'
            : composition;
        messages.add('Состав: $short');
      }

      final foundAllergens = _findAllergens(lower);
      if (_userAllergens.isNotEmpty) {
        if (foundAllergens.isNotEmpty) {
          messages.add(
            'ВНИМАНИЕ! Найдены аллергены: ${foundAllergens.join(", ")}',
          );
          priority = 3;
        } else if (composition != null || lower.contains('состав')) {
          messages.add('Аллергены из вашего списка не обнаружены.');
        }
      }

      if (messages.isEmpty) {
        messages.add(_summarizeText(text));
      }

      await _enqueue(messages.join('. '), priority: priority);
    } catch (e) {
      debugPrint('ReadingService: analyze error: $e');
      await _enqueue('Ошибка чтения текста.', priority: 0);
    } finally {
      _isScanning = false;
    }
  }

  Future<String> _recognizeText(Uint8List jpegBytes) async {
    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/reading_scan.jpg');
    await file.writeAsBytes(jpegBytes, flush: true);

    final input = InputImage.fromFilePath(file.path);
    final result = await _recognizer.processImage(input);
    return result.text.trim();  }

  List<String> _extractPrices(String text) {
    final prices = <String>[];
    for (final match in _pricePattern.allMatches(text)) {
      final value = (match.group(1) ?? match.group(3))?.replaceAll(' ', '');
      if (value == null || value.isEmpty) continue;
      final unit = match.group(2) ?? match.group(4) ?? '₽';
      final normalized = '${value.replaceAll(',', '.')} $unit'.trim();
      if (!prices.contains(normalized)) prices.add(normalized);
    }
    return prices;
  }

  String? _extractComposition(String text, String lower) {
    const markers = [
      'состав:',
      'состав ',
      'ингредиенты:',
      'ингредиенты ',
      'ingredients:',
      'ingredients ',
    ];
    for (final marker in markers) {
      final idx = lower.indexOf(marker);
      if (idx < 0) continue;
      final chunk = text.substring(idx).split(RegExp(r'\n{2,}')).first;
      return chunk.replaceAll(RegExp(r'\s+'), ' ').trim();
    }
    return null;
  }

  List<String> _findAllergens(String lowerText) {
    final found = <String>[];
    for (final allergen in _userAllergens) {
      final synonyms = _synonyms[allergen] ?? [allergen];
      if (synonyms.any((s) => lowerText.contains(s.toLowerCase()))) {
        found.add(allergen);
      } else if (lowerText.contains(allergen.toLowerCase())) {
        found.add(allergen);
      }
    }
    return found;
  }

  String _summarizeText(String text) {
    final lines = text
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.length >= 3)
        .toList();
    if (lines.isEmpty) return 'Текст распознан, но не удалось выделить смысл.';
    final summary = lines.take(4).join('. ');
    return summary.length > 260 ? '${summary.substring(0, 260)}...' : summary;
  }

  void dispose() {
    _recognizer.close();
  }}
