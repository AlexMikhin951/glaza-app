import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/ru_cloud_config.dart';

/// Yandex Vision OCR — облачный fallback, когда ML Kit пуст / нет GMS.
class YandexVisionClient {
  final RuCloudConfig config;

  YandexVisionClient(this.config);

  static const _uri = 'https://vision.api.cloud.yandex.net/vision/v1/batchAnalyze';

  Future<String?> recognizeText(Uint8List jpeg) async {
    if (config.offlineOnly || !config.hasYandexCloud) return null;
    try {
      final b64 = base64Encode(jpeg);
      final response = await http
          .post(
            Uri.parse(_uri),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Api-Key ${config.apiKey}',
              'x-folder-id': config.folderId,
            },
            body: jsonEncode({
              'analyzeSpecs': [
                {
                  'content': b64,
                  'features': [
                    {
                      'type': 'TEXT_DETECTION',
                      'textDetectionConfig': {
                        'languageCodes': ['ru', 'en'],
                      },
                    },
                  ],
                },
              ],
            }),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        debugPrint('YandexVision HTTP ${response.statusCode}');
        return null;
      }
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final results = json['results'] as List?;
      if (results == null || results.isEmpty) return null;
      final pages = results.first['results'] as List?;
      if (pages == null) return null;
      final buf = StringBuffer();
      for (final page in pages) {
        final textDet = page['textDetection'];
        if (textDet == null) continue;
        final pages2 = textDet['pages'] as List? ?? [];
        for (final p in pages2) {
          final blocks = p['blocks'] as List? ?? [];
          for (final b in blocks) {
            final lines = b['lines'] as List? ?? [];
            for (final line in lines) {
              final words = line['words'] as List? ?? [];
              final lineText = words
                  .map((w) => w['text']?.toString() ?? '')
                  .where((t) => t.isNotEmpty)
                  .join(' ');
              if (lineText.isNotEmpty) buf.writeln(lineText);
            }
          }
        }
      }
      final text = buf.toString().trim();
      return text.isEmpty ? null : text;
    } catch (e) {
      debugPrint('YandexVision error: $e');
      return null;
    }
  }
}
