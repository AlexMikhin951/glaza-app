// lib/caching_tile_provider.dart
import 'dart:io';
import 'dart:ui' as ui;
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'offline_map_storage.dart';

/// Провайдер тайлов с in-memory индексом — без sync I/O на UI-потоке.
class IndexedCachingTileProvider extends TileProvider {
  Map<String, String> _tileIndex = {};
  bool _indexReady = false;

  IndexedCachingTileProvider() {
    _loadIndex();
  }

  Future<void> _loadIndex() async {
    try {
      final index = await buildOfflineTileIndex();
      _tileIndex = index;
      _indexReady = true;
    } catch (e) {
      debugPrint('IndexedCachingTileProvider index error: $e');
    }
  }

  /// Перестроить индекс после скачивания/удаления региона.
  Future<void> refreshIndex() async {
    await _loadIndex();
  }

  bool get isIndexReady => _indexReady;

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    final key = '${coordinates.z}/${coordinates.x}/${coordinates.y}';
    final localPath = _tileIndex[key];

    if (localPath != null) {
      return FileImage(File(localPath));
    }

    return NetworkTileImageProvider(
      url: 'https://tile.openstreetmap.org/$key.png',
      cacheFile: null,
      onCached: (path) {
        _tileIndex[key] = path;
      },
    );
  }
}

/// Провайдер для просмотра одного офлайн-региона.
class RegionTileProvider extends TileProvider {
  final String tilesRoot;
  final Map<String, String> _index = {};

  RegionTileProvider(this.tilesRoot) {
    _buildIndex();
  }

  Future<void> _buildIndex() async {
    _index.clear();
    await _scanTilesIntoIndex(Directory(tilesRoot), _index);
  }

  Future<void> ensureReady() => _buildIndex();

  Future<void> _scanTilesIntoIndex(
    Directory dir,
    Map<String, String> index,
  ) async {
    if (!await dir.exists()) return;
    await for (final zEntity in dir.list()) {
      if (zEntity is! Directory) continue;
      final z = int.tryParse(zEntity.path.split(Platform.pathSeparator).last);
      if (z == null) continue;
      await for (final xEntity in zEntity.list()) {
        if (xEntity is! Directory) continue;
        final x = int.tryParse(xEntity.path.split(Platform.pathSeparator).last);
        if (x == null) continue;
        await for (final yEntity in xEntity.list()) {
          if (yEntity is! File || !yEntity.path.endsWith('.png')) continue;
          final y = int.tryParse(
            yEntity.path.split(Platform.pathSeparator).last.replaceAll('.png', ''),
          );
          if (y == null) continue;
          index['$z/$x/$y'] = yEntity.path;
        }
      }
    }
  }

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    final key = '${coordinates.z}/${coordinates.x}/${coordinates.y}';
    final path = _index[key];
    if (path != null) return FileImage(File(path));
    return const _EmptyTileProvider();
  }
}

class _EmptyTileProvider extends ImageProvider<_EmptyTileProvider> {
  const _EmptyTileProvider();

  @override
  Future<_EmptyTileProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  ImageStreamCompleter loadImage(
    _EmptyTileProvider key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _transparentCodec(decode),
      scale: 1.0,
    );
  }

  static Future<ui.Codec> _transparentCodec(ImageDecoderCallback decode) async {
    return decode(await ui.ImmutableBuffer.fromUint8List(_transparentPng));
  }

  static final Uint8List _transparentPng = Uint8List.fromList([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
    0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
    0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
    0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
  ]);
}

/// Легаси-обёртка для обратной совместимости.
class CachingTileProvider extends IndexedCachingTileProvider {
  CachingTileProvider(String cacheDir) : super();
}

class NetworkTileImageProvider extends ImageProvider<NetworkTileImageProvider> {
  final String url;
  final File? cacheFile;
  final void Function(String path)? onCached;

  NetworkTileImageProvider({
    required this.url,
    this.cacheFile,
    this.onCached,
  });

  @override
  Future<NetworkTileImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<NetworkTileImageProvider>(this);
  }

  @override
  ImageStreamCompleter loadImage(
    NetworkTileImageProvider key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _loadAsync(decode),
      scale: 1.0,
      debugLabel: url,
    );
  }

  Future<ui.Codec> _loadAsync(ImageDecoderCallback decode) async {
    try {
      final response = await http
          .get(
            Uri.parse(url),
            headers: {
              'User-Agent': 'SmartGlassesApp/1.0 (contact@project.local)',
            },
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final bytes = response.bodyBytes;
        if (cacheFile != null) {
          try {
            await cacheFile!.parent.create(recursive: true);
            await cacheFile!.writeAsBytes(bytes);
            onCached?.call(cacheFile!.path);
          } catch (e) {
            debugPrint('Ошибка записи тайла в кэш: $e');
          }
        }
        return await decode(await ui.ImmutableBuffer.fromUint8List(bytes));
      }
    } catch (e) {
      debugPrint('Ошибка загрузки тайла из сети: $e');
    }

    return _EmptyTileProvider._transparentCodec(decode);
  }

  @override
  bool operator ==(Object other) {
    if (other is! NetworkTileImageProvider) return false;
    return other.url == url;
  }

  @override
  int get hashCode => url.hashCode;
}

/// @deprecated Используйте downloadMapRegionNamed из offline_map_storage.dart
Future<void> downloadMapRegion(
  double centerLat,
  double centerLon,
  String regionName,
  void Function(double progress, String status) onProgress,
) =>
    downloadMapRegionNamed(centerLat, centerLon, regionName, onProgress);
