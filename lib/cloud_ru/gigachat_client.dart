import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/ru_cloud_config.dart';

/// GigaChat (Sber) — опциональный fallback LLM, если YandexGPT недоступен.
class GigaChatClient {
  final RuCloudConfig config;

  GigaChatClient(this.config);

  String? _accessToken;
  int _tokenExpireMs = 0;

  bool get configured =>
      !config.offlineOnly && config.gigachatAuthKey.isNotEmpty;

  Future<String?> complete(String system, String user) async {
    if (!configured) return null;
    try {
      final token = await _token();
      if (token == null) return null;

      final response = await http
          .post(
            Uri.parse('https://gigachat.devices.sberbank.ru/api/v1/chat/completions'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode({
              'model': 'GigaChat',
              'messages': [
                {'role': 'system', 'content': system},
                {'role': 'user', 'content': user},
              ],
              'temperature': 0.2,
              'max_tokens': 150,
            }),
          )
          .timeout(const Duration(seconds: 8));

      if (response.statusCode != 200) {
        debugPrint('GigaChat HTTP ${response.statusCode}');
        return null;
      }
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final choices = json['choices'] as List?;
      if (choices == null || choices.isEmpty) return null;
      return (choices.first['message']?['content'] as String?)?.trim();
    } catch (e) {
      debugPrint('GigaChat error: $e');
      return null;
    }
  }

  Future<String?> _token() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_accessToken != null && now < _tokenExpireMs - 60000) {
      return _accessToken;
    }
    try {
      final response = await http
          .post(
            Uri.parse(
              'https://ngw.devices.sberbank.ru:9443/api/v2/oauth',
            ),
            headers: {
              'Content-Type': 'application/x-www-form-urlencoded',
              'Accept': 'application/json',
              'RqUID': DateTime.now().millisecondsSinceEpoch.toString(),
              'Authorization': 'Basic ${config.gigachatAuthKey}',
            },
            body: 'scope=GIGACHAT_API_PERS',
          )
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return null;
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      _accessToken = json['access_token'] as String?;
      final expires = json['expires_at'];
      if (expires is int) {
        _tokenExpireMs = expires;
      } else {
        _tokenExpireMs = now + 25 * 60 * 1000;
      }
      return _accessToken;
    } catch (e) {
      debugPrint('GigaChat token: $e');
      return null;
    }
  }
}
