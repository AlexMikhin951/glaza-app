// lib/offline_map_storage.dart
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Метаданные скачанного региона карты.
class OfflineMapRegion {
  final String id;
  final String name;
  final double centerLat;
  final double centerLon;
  final double radius;
  final List<int> zoomLevels;
  final DateTime downloadedAt;
  final int tileCount;

  const OfflineMapRegion({
    required this.id,
    required this.name,
    required this.centerLat,
    required this.centerLon,
    required this.radius,
    required this.zoomLevels,
    required this.downloadedAt,
    required this.tileCount,
  });

  factory OfflineMapRegion.fromJson(Map<String, dynamic> json, String id) {
    return OfflineMapRegion(
      id: id,
      name: json['name'] as String? ?? id,
      centerLat: (json['centerLat'] as num).toDouble(),
      centerLon: (json['centerLon'] as num).toDouble(),
      radius: (json['radius'] as num?)?.toDouble() ?? 0.025,
      zoomLevels: (json['zoomLevels'] as List<dynamic>?)
              ?.map((e) => (e as num).toInt())
              .toList() ??
          [12, 13, 14, 15, 16],
      downloadedAt: DateTime.tryParse(json['downloadedAt'] as String? ?? '') ??
          DateTime.now(),
      tileCount: (json['tileCount'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'centerLat': centerLat,
        'centerLon': centerLon,
        'radius': radius,
        'zoomLevels': zoomLevels,
        'downloadedAt': downloadedAt.toIso8601String(),
        'tileCount': tileCount,
      };

  /// Путь к папке с тайлами региона.
  String tilesPath(String regionsRoot) => '$regionsRoot/$id/tiles';

  String get formattedSize => _formatBytes(estimateSizeBytes());

  int estimateSizeBytes() => tileCount * 18000; // ~18 KB на тайл OSM

  static String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
}

/// Корневая папка всех офлайн-регионов.
Future<String> getOfflineRegionsRoot() async {
  final appDir = await getApplicationSupportDirectory();
  return '${appDir.path}/offline_map/regions';
}

/// Легаси-путь (единый кэш до рефакторинга).
Future<String> getLegacyOfflineMapPath() async {
  final appDir = await getApplicationSupportDirectory();
  return '${appDir.path}/offline_map';
}

String _slugify(String name) {
  final lower = name.toLowerCase().trim();
  final slug = lower
      .replaceAll(RegExp(r'[^a-z0-9\u0400-\u04FF]+'), '_')
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^_|_$'), '');
  final safe = slug.isEmpty ? 'region' : slug;
  return '${safe}_${DateTime.now().millisecondsSinceEpoch}';
}

int _lonToX(double lon, int zoom) =>
    ((lon + 180.0) / 360.0 * pow(2, zoom)).floor();

int _latToY(double lat, int zoom) =>
    ((1.0 -
                log(tan(lat * pi / 180.0) + 1.0 / cos(lat * pi / 180.0)) / pi) /
            2.0 *
            pow(2, zoom))
        .floor();

/// Список всех скачанных регионов.
Future<List<OfflineMapRegion>> listOfflineRegions() async {
  final root = await getOfflineRegionsRoot();
  final dir = Directory(root);
  if (!await dir.exists()) return [];

  final regions = <OfflineMapRegion>[];
  await for (final entity in dir.list()) {
    if (entity is! Directory) continue;
    final metaFile = File('${entity.path}/meta.json');
    if (!await metaFile.exists()) continue;
    try {
      final json =
          jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
      final id = entity.path.split(Platform.pathSeparator).last;
      regions.add(OfflineMapRegion.fromJson(json, id));
    } catch (e) {
      debugPrint('listOfflineRegions: skip ${entity.path}: $e');
    }
  }
  regions.sort((a, b) => b.downloadedAt.compareTo(a.downloadedAt));
  return regions;
}

/// Подсчёт реального размера региона на диске.
Future<int> getRegionSizeBytes(String regionId) async {
  final root = await getOfflineRegionsRoot();
  final tilesDir = Directory('$root/$regionId/tiles');
  if (!await tilesDir.exists()) return 0;

  int total = 0;
  await for (final entity in tilesDir.list(recursive: true)) {
    if (entity is File) {
      total += await entity.length();
    }
  }
  return total;
}

/// Удаляет регион и все его тайлы.
Future<bool> deleteOfflineRegion(String regionId) async {
  final root = await getOfflineRegionsRoot();
  final regionDir = Directory('$root/$regionId');
  if (!await regionDir.exists()) return false;
  await regionDir.delete(recursive: true);
  return true;
}

/// Строит индекс «z/x/y» → путь к файлу для всех регионов + легаси-кэша.
Future<Map<String, String>> buildOfflineTileIndex() async {
  final index = <String, String>{};

  // Легаси-плоский кэш (z/x/y.png прямо в offline_map/)
  final legacyPath = await getLegacyOfflineMapPath();
  await _scanTilesIntoIndex(Directory(legacyPath), index);

  // Регионы
  final regionsRoot = await getOfflineRegionsRoot();
  final regionsDir = Directory(regionsRoot);
  if (await regionsDir.exists()) {
    await for (final entity in regionsDir.list()) {
      if (entity is! Directory) continue;
      final tilesDir = Directory('${entity.path}/tiles');
      if (await tilesDir.exists()) {
        await _scanTilesIntoIndex(tilesDir, index);
      }
    }
  }
  return index;
}

Future<void> _scanTilesIntoIndex(
  Directory dir,
  Map<String, String> index,
) async {
  if (!await dir.exists()) return;

  await for (final zEntity in dir.list()) {
    if (zEntity is! Directory) continue;
    final zName = zEntity.path.split(Platform.pathSeparator).last;
    final z = int.tryParse(zName);
    if (z == null) continue;

    await for (final xEntity in zEntity.list()) {
      if (xEntity is! Directory) continue;
      final xName = xEntity.path.split(Platform.pathSeparator).last;
      final x = int.tryParse(xName);
      if (x == null) continue;

      await for (final yEntity in xEntity.list()) {
        if (yEntity is! File) continue;
        if (!yEntity.path.endsWith('.png')) continue;
        final yName = yEntity.path
            .split(Platform.pathSeparator)
            .last
            .replaceAll('.png', '');
        final y = int.tryParse(yName);
        if (y == null) continue;
        index['$z/$x/$y'] = yEntity.path;
      }
    }
  }
}

/// Скачивает область карты в отдельную папку региона.
Future<OfflineMapRegion> downloadMapRegionNamed(
  double centerLat,
  double centerLon,
  String regionName,
  void Function(double progress, String status) onProgress,
) async {
  final regionsRoot = await getOfflineRegionsRoot();
  final regionId = _slugify(regionName);
  final tilesPath = '$regionsRoot/$regionId/tiles';

  const zooms = [12, 13, 14, 15, 16];
  const radius = 0.025;

  final minLat = centerLat - radius;
  final maxLat = centerLat + radius;
  final minLon = centerLon - radius;
  final maxLon = centerLon + radius;

  final urls = <String>[];
  final files = <File>[];

  for (final zoom in zooms) {
    final minX = _lonToX(minLon, zoom);
    final maxX = _lonToX(maxLon, zoom);
    final minY = _latToY(maxLat, zoom);
    final maxY = _latToY(minLat, zoom);

    for (int x = minX; x <= maxX; x++) {
      for (int y = minY; y <= maxY; y++) {
        urls.add('https://tile.openstreetmap.org/$zoom/$x/$y.png');
        files.add(File('$tilesPath/$zoom/$x/$y.png'));
      }
    }
  }

  final total = urls.length;
  if (total == 0) {
    onProgress(1.0, 'В выбранной области нет плиток карты.');
    throw Exception('Нет плиток для скачивания');
  }

  int downloaded = 0;
  int lastReport = 0;

  for (int i = 0; i < total; i++) {
    final file = files[i];
    if (!await file.exists()) {
      try {
        final response = await http
            .get(
              Uri.parse(urls[i]),
              headers: {
                'User-Agent': 'SmartGlassesApp/1.0 (contact@project.local)',
              },
            )
            .timeout(const Duration(seconds: 5));

        if (response.statusCode == 200) {
          await file.parent.create(recursive: true);
          await file.writeAsBytes(response.bodyBytes);
        }
      } catch (_) {}
    }

    downloaded++;
    if (downloaded - lastReport >= 15 || downloaded == total) {
      lastReport = downloaded;
      onProgress(
        downloaded / total,
        'Скачивание: $downloaded / $total плиток',
      );
    }
  }

  final region = OfflineMapRegion(
    id: regionId,
    name: regionName,
    centerLat: centerLat,
    centerLon: centerLon,
    radius: radius,
    zoomLevels: zooms,
    downloadedAt: DateTime.now(),
    tileCount: total,
  );

  final metaFile = File('$regionsRoot/$regionId/meta.json');
  await metaFile.parent.create(recursive: true);
  await metaFile.writeAsString(jsonEncode(region.toJson()));

  onProgress(1.0, 'Карта «$regionName» сохранена офлайн!');
  return region;
}

/// Геокодирование названия города через Nominatim.
Future<(double lat, double lon, String displayName)> geocodeRegion(
  String query,
) async {
  final uri = Uri.parse('https://nominatim.openstreetmap.org/search').replace(
    queryParameters: {'q': query, 'format': 'json', 'limit': '1'},
  );
  final response = await http.get(
    uri,
    headers: {'User-Agent': 'SmartGlassesApp/1.0'},
  );
  if (response.statusCode != 200) {
    throw Exception('Ошибка связи с сервером поиска');
  }
  final list = jsonDecode(response.body) as List;
  if (list.isEmpty) {
    throw Exception('Город/регион не найден. Уточните название.');
  }
  final place = list.first as Map<String, dynamic>;
  return (
    double.parse(place['lat'] as String),
    double.parse(place['lon'] as String),
    (place['display_name'] as String?) ?? query,
  );
}
