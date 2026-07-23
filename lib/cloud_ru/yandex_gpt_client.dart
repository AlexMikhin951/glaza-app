import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../ai_detector.dart';
import '../core/ru_cloud_config.dart';
import '../distance_estimator.dart';

/// Описание сцены: офлайн по YOLO, облако — YandexGPT по структурированному контексту.
class YandexGptClient {
  final RuCloudConfig config;
  Future<String?> Function(String system, String user)? gigaFallback;

  YandexGptClient(this.config);

  static const _uri =
      'https://llm.api.cloud.yandex.net/foundationModels/v1/completion';

  /// Короткое офлайн-описание по детекциям (всегда доступно).
  String describeOffline(List<DetectedObject> objects) {
    if (objects.isEmpty) {
      return 'Явных объектов не вижу. Поверните голову или подойдите ближе.';
    }
    final parts = <String>[];
    final sorted = [...objects]..sort((a, b) {
      final aa =
          (a.rect[2] - a.rect[0]).abs() * (a.rect[3] - a.rect[1]).abs();
      final bb =
          (b.rect[2] - b.rect[0]).abs() * (b.rect[3] - b.rect[1]).abs();
      return bb.compareTo(aa);
    });

    for (final o in sorted.take(5)) {
      final name = DistanceEstimator.labelRu[o.label] ??
          DistanceEstimator.labelRu[_key(o.label)] ??
          o.label;
      final cx = (o.rect[1] + o.rect[3]) / 2;
      final side = cx < 0.35
          ? 'слева'
          : (cx > 0.65 ? 'справа' : 'впереди');
      final m = DistanceEstimator.estimateMeters(o);
      final dist = m != null ? ', примерно ${m.round()} метров' : '';
      parts.add('$name $side$dist');
    }
    return '${parts.join('. ')}.';
  }

  Future<String> describeScene({
    required Uint8List jpeg,
    required List<DetectedObject> objects,
  }) async {
    final offline = describeOffline(objects);

    if (config.offlineOnly) {
      return offline;
    }

    final system =
        'Ты помощник для слепых пешеходов в России. '
        'Ответь 1–2 короткими предложениями по-русски. '
        'Сначала опасности (машины, ямы), потом что слева/справа/впереди. Без воды.';
    final user =
        'Детектор на очках увидел:\n$offline\n'
        'Сформулируй естественное короткое описание «что передо мной».';

    if (config.hasYandexCloud) {
      try {
        final response = await http
            .post(
              Uri.parse(_uri),
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Api-Key ${config.apiKey}',
                'x-folder-id': config.folderId,
              },
              body: jsonEncode({
                'modelUri': 'gpt://${config.folderId}/yandexgpt-lite',
                'completionOptions': {
                  'stream': false,
                  'temperature': 0.15,
                  'maxTokens': 120,
                },
                'messages': [
                  {'role': 'system', 'text': system},
                  {'role': 'user', 'text': user},
                ],
              }),
            )
            .timeout(const Duration(seconds: 8));

        if (response.statusCode == 200) {
          final json = jsonDecode(response.body) as Map<String, dynamic>;
          final alts = json['result']?['alternatives'] as List?;
          if (alts != null && alts.isNotEmpty) {
            final text = (alts.first['message']?['text'] as String?)?.trim();
            if (text != null && text.isNotEmpty) return text;
          }
        } else {
          debugPrint('YandexGpt HTTP ${response.statusCode}: ${response.body}');
        }
      } catch (e) {
        debugPrint('YandexGpt error: $e');
      }
    }

    // Fallback GigaChat
    if (gigaFallback != null) {
      final g = await gigaFallback!(system, user);
      if (g != null && g.isNotEmpty) return g;
    }

    if (!config.hasYandexCloud) {
      return '$offline Для умной сцены добавьте ключ Яндекс Облака в настройках.';
    }
    return offline;
  }

  Future<String?> askAboutText(String ocrText, String question) async {
    if (config.offlineOnly || !config.hasYandexCloud) return null;
    try {
      final clipped =
          ocrText.length > 2500 ? ocrText.substring(0, 2500) : ocrText;
      final response = await http
          .post(
            Uri.parse(_uri),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Api-Key ${config.apiKey}',
              'x-folder-id': config.folderId,
            },
            body: jsonEncode({
              'modelUri': 'gpt://${config.folderId}/yandexgpt-lite',
              'completionOptions': {
                'stream': false,
                'temperature': 0.1,
                'maxTokens': 120,
              },
              'messages': [
                {
                  'role': 'system',
                  'text':
                      'Отвечай кратко по-русски только по тексту. Если нет данных — «не указано».',
                },
                {
                  'role': 'user',
                  'text': 'Текст:\n$clipped\n\nВопрос: $question',
                },
              ],
            }),
          )
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return null;
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final alts = json['result']?['alternatives'] as List?;
      if (alts == null || alts.isEmpty) return null;
      return (alts.first['message']?['text'] as String?)?.trim();
    } catch (e) {
      debugPrint('YandexGpt askAboutText: $e');
      return null;
    }
  }

  String? _key(String label) {
    final l = label.toLowerCase();
    for (final k in DistanceEstimator.labelRu.keys) {
      if (l.contains(k)) return k;
    }
    return null;
  }
}
