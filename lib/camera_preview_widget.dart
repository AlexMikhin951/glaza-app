import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'ai_detector.dart';

/// Превью снимка в режиме чтения — с подписью и масштабированием.
class ReadingPhotoPreview extends StatelessWidget {
  final Uint8List jpegBytes;

  const ReadingPhotoPreview({super.key, required this.jpegBytes});

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final cacheW = (mq.size.width * mq.devicePixelRatio).round();
    final cacheH = (mq.size.height * mq.devicePixelRatio).round();

    return Container(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          InteractiveViewer(
            minScale: 0.5,
            maxScale: 4,
            child: Center(
              child: Image.memory(
                jpegBytes,
                fit: BoxFit.contain,
                gaplessPlayback: true,
                filterQuality: FilterQuality.high,
                cacheWidth: cacheW,
                cacheHeight: cacheH,
              ),
            ),
          ),
          Positioned(
            top: 12,
            left: 12,
            right: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Row(
                children: [
                  Icon(Icons.photo_camera_rounded, color: Colors.white, size: 18),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Снимок для чтения — можно увеличить двумя пальцами',
                      style: TextStyle(color: Colors.white, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Слой видео — только JPEG, без боксов. Отдельный RepaintBoundary в родителе.
class CameraVideoLayer extends StatelessWidget {
  final Uint8List jpegBytes;

  const CameraVideoLayer({super.key, required this.jpegBytes});

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final cacheW = (mq.size.width * mq.devicePixelRatio).round();
    final cacheH = (mq.size.height * mq.devicePixelRatio).round();

    return Image.memory(
      jpegBytes,
      fit: BoxFit.contain,
      gaplessPlayback: true,
      filterQuality: FilterQuality.low,
      // Декодируем JPEG сразу в размер экрана, а не полный VGA — UI быстрее,
      // на нейросеть это не влияет (там свой decode до 640×640).
      cacheWidth: cacheW,
      cacheHeight: cacheH,
    );
  }
}

/// Слой боксов детекции — перерисовывается отдельно от видео.
class DetectionOverlay extends StatelessWidget {
  final List<DetectedObject> detections;

  const DetectionOverlay({super.key, this.detections = const []});

  @override
  Widget build(BuildContext context) {
    if (detections.isEmpty) return const SizedBox.shrink();
    return CustomPaint(
      painter: _DetectionBoxesPainter(detections),
      child: const SizedBox.expand(),
    );
  }
}

/// Совместимость: видео + боксы в одном виджете.
class CameraPreviewWidget extends StatelessWidget {
  final Uint8List? jpegBytes;
  final List<DetectedObject> detections;

  const CameraPreviewWidget({
    super.key,
    required this.jpegBytes,
    this.detections = const [],
  });

  @override
  Widget build(BuildContext context) {
    if (jpegBytes == null) {
      return const Center(child: Text('Ожидание кадра...'));
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        CameraVideoLayer(jpegBytes: jpegBytes!),
        DetectionOverlay(detections: detections),
      ],
    );
  }
}

class _DetectionBoxesPainter extends CustomPainter {
  final List<DetectedObject> detections;

  _DetectionBoxesPainter(this.detections);

  @override
  void paint(Canvas canvas, Size size) {
    final boxPaint = Paint()
      ..color = Colors.green
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;

    for (final obj in detections) {
      final double top = obj.rect[0] * size.height;
      final double left = obj.rect[1] * size.width;
      final double bottom = obj.rect[2] * size.height;
      final double right = obj.rect[3] * size.width;
      canvas.drawRect(Rect.fromLTRB(left, top, right, bottom), boxPaint);
    }
  }

  @override
  bool shouldRepaint(_DetectionBoxesPainter old) =>
      old.detections != detections;
}
