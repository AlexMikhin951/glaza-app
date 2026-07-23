import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import 'distance_estimator.dart';

enum VisualHazardType { stairs, hole, curb, obstacle }

class VisualHazard {
  final VisualHazardType type;
  final String labelRu;
  final double confidence;
  final double distanceM;
  final List<double> bbox;

  const VisualHazard({
    required this.type,
    required this.labelRu,
    required this.confidence,
    required this.distanceM,
    required this.bbox,
  });
}

img.Image? _decodeJpg(Uint8List bytes) => img.decodeJpg(bytes);

/// Строгие эвристики: меньше ложных «ям» (тени, лужи, асфальт, vignette OV5640).
class HazardAnalyzer {
  static Future<List<VisualHazard>> analyzeJpeg(Uint8List jpeg) async {
    try {
      final decoded = await compute(_decodeJpg, jpeg);
      if (decoded == null) return const [];
      return analyzeImage(decoded);
    } catch (e) {
      debugPrint('HazardAnalyzer error: $e');
      return const [];
    }
  }

  static List<VisualHazard> analyzeImage(img.Image image) {
    final w = min(160, image.width);
    final h = (image.height * w / image.width).round().clamp(48, 128);
    final small = img.copyResize(image, width: w, height: h);

    final hazards = <VisualHazard>[];
    final stairs = _detectStairs(small);
    if (stairs != null) hazards.add(stairs);
    final hole = _detectHole(small);
    if (hole != null) hazards.add(hole);
    return hazards;
  }

  static VisualHazard? _detectStairs(img.Image image) {
    final w = image.width;
    final h = image.height;
    // Только нижняя половина — иначе перила/окна/жалюзи дают ложные пики.
    final y0 = (h * 0.48).round();
    final rowEnergy = List<double>.filled(h, 0);

    for (int y = y0; y < h - 1; y++) {
      double e = 0;
      // Игнорируем крайние 15% (сильная дисторсия OV5640).
      final x0 = (w * 0.15).round();
      final x1 = (w * 0.85).round();
      for (int x = x0; x < x1; x++) {
        final a = image.getPixel(x, y);
        final b = image.getPixel(x, y + 1);
        final la = 0.299 * a.r + 0.587 * a.g + 0.114 * a.b;
        final lb = 0.299 * b.r + 0.587 * b.g + 0.114 * b.b;
        e += (la - lb).abs();
      }
      rowEnergy[y] = e / max(1, x1 - x0);
    }

    // Адаптивный порог относительно медианы энергии.
    final energies = <double>[];
    for (int y = y0; y < h; y++) {
      energies.add(rowEnergy[y]);
    }
    energies.sort();
    final medianE = energies[energies.length ~/ 2];
    final peakThresh = max(28.0, medianE * 2.4);

    final peaks = <int>[];
    for (int y = y0 + 3; y < h - 3; y++) {
      final v = rowEnergy[y];
      if (v > peakThresh &&
          v >= rowEnergy[y - 1] &&
          v >= rowEnergy[y + 1] &&
          v > rowEnergy[y - 2] &&
          v > rowEnergy[y + 2]) {
        // Не ставить пики слишком близко.
        if (peaks.isEmpty || y - peaks.last >= 3) peaks.add(y);
      }
    }
    if (peaks.length < 4) return null;

    final gaps = <double>[];
    for (int i = 1; i < peaks.length; i++) {
      gaps.add((peaks[i] - peaks[i - 1]).toDouble());
    }
    gaps.sort();
    final medianGap = gaps[gaps.length ~/ 2];
    if (medianGap < 4 || medianGap > h * 0.16) return null;

    int regular = 0;
    for (final g in gaps) {
      if ((g - medianGap).abs() <= medianGap * 0.32) regular++;
    }
    if (regular < 3) return null;

    final span = peaks.last - peaks.first;
    if (span < h * 0.12) return null;

    final top = peaks.first / h;
    final bottom = peaks.last / h;
    final conf = ((regular / gaps.length) * 0.85).clamp(0.55, 0.95);
    final dist = DistanceEstimator.groundPlaneMeters(
      normalizedBottomY: bottom,
      normalizedCenterX: 0.5,
    );

    return VisualHazard(
      type: VisualHazardType.stairs,
      labelRu: 'лестница',
      confidence: conf,
      distanceM: dist,
      bbox: [top, 0.2, bottom, 0.8],
    );
  }

  /// Яма: очень тёмное компактное пятно в зоне ног + контраст с окружением.
  static VisualHazard? _detectHole(img.Image image) {
    final w = image.width;
    final h = image.height;
    // Только ближняя земля (ноги / трость). Верх кадра — vignette/небо.
    final y0 = (h * 0.68).round();
    final x0 = (w * 0.22).round();
    final x1 = (w * 0.78).round();

    double sum = 0;
    double sum2 = 0;
    int n = 0;
    for (int y = y0; y < h; y += 2) {
      for (int x = x0; x < x1; x += 2) {
        final p = image.getPixel(x, y);
        final lum = 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
        sum += lum;
        sum2 += lum * lum;
        n++;
      }
    }
    if (n < 30) return null;
    final mean = sum / n;
    final variance = (sum2 / n) - mean * mean;
    // Слишком тёмный весь низ (ночь / тень) или почти ровный — не ищем яму.
    if (mean < 45) return null;
    if (variance < 180) return null;

    // Яма должна быть заметно темнее фона, не просто «чуть серее».
    final darkThresh = min(mean * 0.38, mean - 35);
    if (darkThresh < 12) return null;

    final cell = 3;
    final gw = ((x1 - x0) / cell).ceil();
    final gh = ((h - y0) / cell).ceil();
    if (gw < 4 || gh < 3) return null;

    final dark = List.generate(gh, (_) => List<bool>.filled(gw, false));
    final lumGrid = List.generate(gh, (_) => List<double>.filled(gw, mean));

    for (int gy = 0; gy < gh; gy++) {
      for (int gx = 0; gx < gw; gx++) {
        final x = (x0 + gx * cell + cell ~/ 2).clamp(0, w - 1);
        final y = (y0 + gy * cell + cell ~/ 2).clamp(0, h - 1);
        final p = image.getPixel(x, y);
        final lum = 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
        lumGrid[gy][gx] = lum;
        dark[gy][gx] = lum < darkThresh;
      }
    }

    int bestCount = 0;
    int bestMinX = 0, bestMaxX = 0, bestMinY = 0, bestMaxY = 0;
    double bestMeanLum = 255;
    final visited = List.generate(gh, (_) => List<bool>.filled(gw, false));

    for (int gy = 0; gy < gh; gy++) {
      for (int gx = 0; gx < gw; gx++) {
        if (!dark[gy][gx] || visited[gy][gx]) continue;
        int count = 0;
        double lumSum = 0;
        int minX = gx, maxX = gx, minY = gy, maxY = gy;
        final stack = <(int, int)>[(gx, gy)];
        visited[gy][gx] = true;
        while (stack.isNotEmpty) {
          final (cx, cy) = stack.removeLast();
          count++;
          lumSum += lumGrid[cy][cx];
          minX = min(minX, cx);
          maxX = max(maxX, cx);
          minY = min(minY, cy);
          maxY = max(maxY, cy);
          for (final d in const [(1, 0), (-1, 0), (0, 1), (0, -1)]) {
            final nx = cx + d.$1;
            final ny = cy + d.$2;
            if (nx < 0 || ny < 0 || nx >= gw || ny >= gh) continue;
            if (visited[ny][nx] || !dark[ny][nx]) continue;
            visited[ny][nx] = true;
            stack.add((nx, ny));
          }
        }
        if (count > bestCount) {
          bestCount = count;
          bestMinX = minX;
          bestMaxX = maxX;
          bestMinY = minY;
          bestMaxY = maxY;
          bestMeanLum = lumSum / count;
        }
      }
    }

    final areaFrac = bestCount / (gw * gh);
    // Компактная яма: не огромная тень и не одна клетка.
    if (areaFrac < 0.035 || areaFrac > 0.18) return null;

    final bw = bestMaxX - bestMinX + 1;
    final bh = bestMaxY - bestMinY + 1;
    if (bw < 2 || bh < 2) return null;
    final aspect = bw / bh;
    if (aspect < 0.45 || aspect > 2.4) return null;

    // Не у самого края сетки (часто vignette / бордюр кадра).
    if (bestMinX <= 0 || bestMaxX >= gw - 1) return null;
    if (bestMinY <= 0) return null;

    final cxNorm = (x0 + ((bestMinX + bestMaxX) / 2) * cell) / w;
    if (cxNorm < 0.32 || cxNorm > 0.68) return null;

    // Контраст с кольцом вокруг пятна.
    double ringSum = 0;
    int ringN = 0;
    for (int gy = max(0, bestMinY - 1); gy <= min(gh - 1, bestMaxY + 1); gy++) {
      for (int gx = max(0, bestMinX - 1); gx <= min(gw - 1, bestMaxX + 1); gx++) {
        final inside = gx >= bestMinX &&
            gx <= bestMaxX &&
            gy >= bestMinY &&
            gy <= bestMaxY;
        if (inside) continue;
        ringSum += lumGrid[gy][gx];
        ringN++;
      }
    }
    if (ringN < 4) return null;
    final ringMean = ringSum / ringN;
    final contrast = ringMean - bestMeanLum;
    // Нужен сильный провал яркости относительно окружения.
    if (contrast < 28) return null;
    if (bestMeanLum > mean * 0.55) return null;

    final top = (y0 + bestMinY * cell) / h;
    final left = (x0 + bestMinX * cell) / w;
    final bottom = ((y0 + (bestMaxY + 1) * cell).clamp(0, h)) / h;
    final right = ((x0 + (bestMaxX + 1) * cell).clamp(0, w)) / w;

    // Яма должна «сидеть» в нижней зоне.
    if (bottom < 0.78) return null;

    final dist = DistanceEstimator.groundPlaneMeters(
      normalizedBottomY: bottom,
      normalizedCenterX: cxNorm,
    );
    // Дальше ~5 м по эвристике почти всегда ложняк на wide-линзе.
    if (dist > 5.5) return null;

    final conf = ((contrast / 55) * (areaFrac / 0.08)).clamp(0.55, 0.92);

    return VisualHazard(
      type: VisualHazardType.hole,
      labelRu: 'неровность или яма',
      confidence: conf,
      distanceM: dist,
      bbox: [top, left, bottom, right],
    );
  }
}
