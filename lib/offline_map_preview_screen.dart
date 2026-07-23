// lib/offline_map_preview_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'app_theme.dart';
import 'caching_tile_provider.dart';
import 'offline_map_storage.dart';

/// Экран просмотра скачанного офлайн-региона.
class OfflineMapPreviewScreen extends StatefulWidget {
  final OfflineMapRegion region;

  const OfflineMapPreviewScreen({super.key, required this.region});

  @override
  State<OfflineMapPreviewScreen> createState() =>
      _OfflineMapPreviewScreenState();
}

class _OfflineMapPreviewScreenState extends State<OfflineMapPreviewScreen> {
  final MapController _mapController = MapController();
  RegionTileProvider? _tileProvider;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _initProvider();
  }

  Future<void> _initProvider() async {
    final root = await getOfflineRegionsRoot();
    final tilesPath = widget.region.tilesPath(root);
    final provider = RegionTileProvider(tilesPath);
    await provider.ensureReady();
    if (mounted) {
      setState(() {
        _tileProvider = provider;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final center = LatLng(widget.region.centerLat, widget.region.centerLon);

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.region.name),
        backgroundColor: AppColors.surface,
      ),
      body: _loading || _tileProvider == null
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.accent),
            )
          : FlutterMap(
              mapController: _mapController,
              options: MapOptions(
                initialCenter: center,
                initialZoom: 14.0,
                interactionOptions: const InteractionOptions(
                  flags: InteractiveFlag.all,
                ),
              ),
              children: [
                TileLayer(
                  tileProvider: _tileProvider!,
                ),
                MarkerLayer(
                  markers: [
                    Marker(
                      point: center,
                      width: 36,
                      height: 36,
                      child: const Icon(
                        Icons.location_on_rounded,
                        color: AppColors.accent,
                        size: 36,
                      ),
                    ),
                  ],
                ),
              ],
            ),
    );
  }
}
