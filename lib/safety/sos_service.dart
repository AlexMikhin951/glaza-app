import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/ru_cloud_config.dart';
import '../vibration_service.dart';

/// SOS: вибро + TTS + SMS/звонок с координатами (без зарубежных мессенджеров).
class SosService {
  final RuCloudConfig config;
  final VibrationService vibration;
  final Future<void> Function(String text, {int? priority}) _enqueue;

  SosService({
    required this.config,
    required this.vibration,
    required Future<void> Function(String text, {int? priority}) enqueueCallback,
  }) : _enqueue = enqueueCallback;

  Future<void> trigger() async {
    vibration.sos();
    await _enqueue(
      'Сигнал помощи.',
      priority: 4,
    );

    Position? pos;
    try {
      pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      ).timeout(const Duration(seconds: 5));
    } catch (_) {}

    final mapsLink = pos != null
        ? 'https://yandex.ru/maps/?pt=${pos.longitude},${pos.latitude}&z=17&l=map'
        : null;
    final locText = pos != null
        ? 'Мои координаты: ${pos.latitude.toStringAsFixed(5)}, '
            '${pos.longitude.toStringAsFixed(5)}. Карта: $mapsLink'
        : 'Координаты недоступны.';

    final phone = config.sosPhone.replaceAll(RegExp(r'[^\d+]'), '');
    if (phone.isEmpty) {
      await _enqueue(
        'Контакт помощи не задан. Укажите номер в настройках. '
        'Позовите рядом стоящих или наберите экстренный номер.',
        priority: 4,
      );
      return;
    }

    final name = config.sosContactName.isEmpty
        ? 'контакт'
        : config.sosContactName;
    final smsBody =
        'SOS из приложения Glaza. Нужна помощь. $locText';

    await _enqueue('Отправляю сообщение контакту $name.', priority: 4);

    try {
      final smsUri = Uri(
        scheme: 'sms',
        path: phone,
        queryParameters: {'body': smsBody},
      );
      if (await canLaunchUrl(smsUri)) {
        await launchUrl(smsUri);
      } else {
        // Android иногда хочет sms:?body=
        final alt = Uri.parse(
          'sms:$phone?body=${Uri.encodeComponent(smsBody)}',
        );
        await launchUrl(alt);
      }
    } catch (e) {
      debugPrint('SOS SMS error: $e');
      await _enqueue(
        'Не удалось открыть SMS. Набираю номер.',
        priority: 4,
      );
      try {
        await launchUrl(Uri.parse('tel:$phone'));
      } catch (_) {}
    }
  }

  /// Поделиться локацией через системный share (без API мессенджеров).
  Future<void> shareLocation() async {
    try {
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      ).timeout(const Duration(seconds: 5));
      final link =
          'https://yandex.ru/maps/?pt=${pos.longitude},${pos.latitude}&z=17&l=map';
      final text =
          'Я здесь: ${pos.latitude.toStringAsFixed(5)}, '
          '${pos.longitude.toStringAsFixed(5)}. $link';
      final uri = Uri(
        scheme: 'sms',
        path: config.sosPhone.isEmpty ? '' : config.sosPhone,
        queryParameters: {'body': text},
      );
      if (config.sosPhone.isNotEmpty && await canLaunchUrl(uri)) {
        await launchUrl(uri);
        await _enqueue('Локация готова к отправке.', priority: 2);
      } else {
        await _enqueue(
          'Координаты: ${pos.latitude.toStringAsFixed(5)}, '
          '${pos.longitude.toStringAsFixed(5)}.',
          priority: 2,
        );
      }
    } catch (e) {
      await _enqueue('Не удалось получить локацию.', priority: 2);
    }
  }
}
