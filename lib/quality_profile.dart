// lib/quality_profile.dart

/// Профили качества AI-детекции для адаптации под возможности устройства.
enum QualityProfile {
  /// Минимальная нагрузка: реже инференс, выше throttle.
  eco(
    label: 'Эко',
    aiMinIntervalMs: 300,
    confThreshold: 0.30,
    description: 'Экономия батареи, ~3 AI FPS',
  ),

  /// Баланс скорости и точности (по умолчанию).
  balanced(
    label: 'Баланс',
    aiMinIntervalMs: 150,
    confThreshold: 0.25,
    description: 'Оптимально для большинства телефонов, ~5-7 AI FPS',
  ),

  /// Максимальная точность, больше нагрузка.
  max(
    label: 'Макс',
    aiMinIntervalMs: 80,
    confThreshold: 0.20,
    description: 'Для мощных устройств, ~8-10 AI FPS',
  );

  const QualityProfile({
    required this.label,
    required this.aiMinIntervalMs,
    required this.confThreshold,
    required this.description,
  });

  final String label;
  final int aiMinIntervalMs;
  final double confThreshold;
  final String description;
}
