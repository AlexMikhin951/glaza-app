// lib/udp_video_pipeline.dart
// Приём UDP и сборка JPEG в отдельном изоляте — не блокируется AI/UI.
//
// Политика live-видео: только самый свежий кадр.
// Если main isolate занят (AI/UI), новые готовые кадры ПЕРЕЗАПИСЫВАЮТ
// mailbox, а не ставятся в очередь — иначе растёт задержка.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

class UdpFrameMessage {
  final Uint8List jpeg;
  final InternetAddress source;
  final int frameId;
  final bool isPhoto;
  final int bytes;

  const UdpFrameMessage({
    required this.jpeg,
    required this.source,
    required this.frameId,
    required this.isPhoto,
    required this.bytes,
  });
}

class UdpVideoPipeline {
  Isolate? _isolate;
  SendPort? _cmdPort;
  final _frames = StreamController<UdpFrameMessage>.broadcast();
  final _ready = Completer<void>();

  Stream<UdpFrameMessage> get frames => _frames.stream;
  Future<void> get ready => _ready.future;

  Future<void> start({
    required int port,
    int rcvBufBytes = 32 * 1024 * 1024,
  }) async {
    final receivePort = ReceivePort();
    _isolate = await Isolate.spawn(
      _udpIsolateMain,
      _UdpIsolateConfig(
        mainSendPort: receivePort.sendPort,
        port: port,
        rcvBufBytes: rcvBufBytes,
      ),
      debugName: 'udp_video',
    );

    receivePort.listen((message) {
      if (message is SendPort) {
        _cmdPort = message;
        if (!_ready.isCompleted) _ready.complete();
        return;
      }
      if (message is _UdpIsolateFrame) {
        if (!_frames.isClosed) {
          _frames.add(
            UdpFrameMessage(
              jpeg: message.jpeg,
              source: InternetAddress(message.sourceIp),
              frameId: message.frameId,
              isPhoto: message.isPhoto,
              bytes: message.bytes,
            ),
          );
        }
        // Сразу говорим изоляту: можно слать следующий (только latest).
        _cmdPort?.send('ack');
        return;
      }
      if (message is String && message.startsWith('ERR:')) {
        // ignore: avoid_print
        print(message);
      }
    });

    await ready.timeout(const Duration(seconds: 5));
  }

  Future<void> stop() async {
    _cmdPort?.send('stop');
    await Future.delayed(const Duration(milliseconds: 50));
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _cmdPort = null;
    await _frames.close();
  }
}

class _UdpIsolateConfig {
  final SendPort mainSendPort;
  final int port;
  final int rcvBufBytes;
  _UdpIsolateConfig({
    required this.mainSendPort,
    required this.port,
    required this.rcvBufBytes,
  });
}

class _UdpIsolateFrame {
  final Uint8List jpeg;
  final String sourceIp;
  final int frameId;
  final bool isPhoto;
  final int bytes;
  _UdpIsolateFrame({
    required this.jpeg,
    required this.sourceIp,
    required this.frameId,
    required this.isPhoto,
    required this.bytes,
  });
}

// Сколько незавершённых кадров держим при сборке чанков.
// Для live — мало: старые дырявые кадры выкидываем сразу.
const int _kMaxInFlightFrames = 4;
// Не принимаем чанки старше highest - N.
const int _kMaxLagFrames = 3;

Future<void> _udpIsolateMain(_UdpIsolateConfig config) async {
  final cmdPort = ReceivePort();
  config.mainSendPort.send(cmdPort.sendPort);

  RawDatagramSocket? socket;
  final active = <int, List<Uint8List?>>{};
  final chunkCounts = <int, int>{};
  int highestFrameId = 0;
  int bytesAccum = 0;

  // Mailbox «только latest»: если main ещё не ack'нул предыдущий кадр,
  // новый готовый кадр перезаписывает слот — очередь не растёт.
  _UdpIsolateFrame? mailbox;
  bool awaitingAck = false;

  void tryFlushMailbox() {
    if (awaitingAck || mailbox == null) return;
    final frame = mailbox!;
    mailbox = null;
    awaitingAck = true;
    config.mainSendPort.send(frame);
  }

  void publishFrame(_UdpIsolateFrame frame) {
    // Фото (READ) всегда доставляем — не дропаем и не перезаписываем видео.
    if (frame.isPhoto) {
      mailbox = frame;
      tryFlushMailbox();
      return;
    }
    // Не затираем непрочитанное фото свежим видео.
    if (mailbox != null && mailbox!.isPhoto) {
      return;
    }
    // Видео: оставляем только самый свежий frameId.
    if (mailbox != null && mailbox!.frameId > frame.frameId) {
      return;
    }
    mailbox = frame;
    tryFlushMailbox();
  }

  try {
    socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      config.port,
      reuseAddress: true,
    );
    // Большой SO_RCVBUF: кратковременный лаг main не роняет UDP-пакеты ОС.
    // Нарастающей задержки нет — приложение берёт только latest (mailbox).
    try {
      // SO_RCVBUF: Android/Linux = level 1 option 8
      socket.setRawOption(
        RawSocketOption.fromInt(
          RawSocketOption.levelSocket,
          8,
          config.rcvBufBytes,
        ),
      );
    } catch (e) {
      // ignore: avoid_print
      print('SO_RCVBUF set failed: $e');
    }
    socket.readEventsEnabled = true;

    int pktCount = 0;
    int lastLogMs = DateTime.now().millisecondsSinceEpoch;

    cmdPort.listen((msg) {
      if (msg == 'stop') {
        socket?.close();
        cmdPort.close();
        return;
      }
      if (msg == 'ack') {
        awaitingAck = false;
        tryFlushMailbox();
      }
    });

    await for (final event in socket) {
      if (event != RawSocketEvent.read) continue;

      Datagram? dg;
      while ((dg = socket.receive()) != null) {
        final data = dg!.data;
        pktCount++;
        bytesAccum += data.length;
        final now = DateTime.now().millisecondsSinceEpoch;
        if (now - lastLogMs >= 3000) {
          // ignore: avoid_print
          print(
            'UDP rx: $pktCount pkts / 3s from ${dg.address.address}, '
            'activeFrames=${active.length}',
          );
          pktCount = 0;
          lastLogMs = now;
        }
        if (data.length < 10) continue;

        final bd = ByteData.sublistView(data, 0, 9);
        final fId = bd.getUint32(0, Endian.little);
        final cId = bd.getUint16(4, Endian.little);
        final tChunks = bd.getUint16(6, Endian.little);
        final isPhoto = data[8] == 1;
        if (tChunks == 0 || tChunks > 512 || cId >= tChunks) continue;

        // wrap / reset счётчика frameId на камере
        if (highestFrameId > 0 && fId < highestFrameId - 200) {
          highestFrameId = 0;
          active.clear();
          chunkCounts.clear();
        }
        // Старые чанки — сразу в мусор (не копим задержку)
        if (!isPhoto &&
            highestFrameId > 0 &&
            fId < highestFrameId - _kMaxLagFrames) {
          continue;
        }
        if (fId > highestFrameId) {
          highestFrameId = fId;
          // При новом кадре вычищаем все незавершённые старше окна
          active.removeWhere((id, _) => id < fId - _kMaxInFlightFrames);
          chunkCounts.removeWhere((id, _) => id < fId - _kMaxInFlightFrames);
        }

        var slots = active[fId];
        if (slots == null || slots.length != tChunks) {
          if (active.length >= _kMaxInFlightFrames && !active.containsKey(fId)) {
            final oldest = active.keys.reduce((a, b) => a < b ? a : b);
            active.remove(oldest);
            chunkCounts.remove(oldest);
          }
          slots = List<Uint8List?>.filled(tChunks, null);
          active[fId] = slots;
          chunkCounts[fId] = 0;
        }

        if (slots[cId] == null) {
          slots[cId] = Uint8List.fromList(data.sublist(9));
          chunkCounts[fId] = (chunkCounts[fId] ?? 0) + 1;
        }

        if (chunkCounts[fId] == tChunks) {
          final builder = BytesBuilder(copy: false);
          for (final chunk in slots) {
            builder.add(chunk!);
          }
          active.remove(fId);
          chunkCounts.remove(fId);
          final jpeg = builder.takeBytes();
          if (jpeg.length >= 2 && jpeg[0] == 0xFF && jpeg[1] == 0xD8) {
            final reportedBytes = bytesAccum;
            bytesAccum = 0;
            publishFrame(
              _UdpIsolateFrame(
                jpeg: jpeg,
                sourceIp: dg.address.address,
                frameId: fId,
                isPhoto: isPhoto,
                bytes: reportedBytes,
              ),
            );
          }
        }
      }
    }
  } catch (e) {
    config.mainSendPort.send('ERR:udp isolate: $e');
  } finally {
    socket?.close();
    cmdPort.close();
  }
}
