// lib/setup_screen.dart
import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:app_settings/app_settings.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app_theme.dart';
import 'app_widgets.dart';
import 'fpv_screen.dart';

const int kUdpPort = 12345;
const int kEspCommandPort = 12346;

class SetupScreen extends StatefulWidget {
  const SetupScreen({super.key});
  @override
  State<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends State<SetupScreen> with WidgetsBindingObserver {
  final TextEditingController _ssidController = TextEditingController();
  final TextEditingController _passController = TextEditingController();
  bool _isConnecting = false;
  bool _isHotspotMode = true;
  String _statusText = "Укажите данные Wi-Fi и нажмите старт";
  RawDatagramSocket? _tempUdpSocket;
  bool _isTransitioning = false;

  final TextEditingController _placeNameController = TextEditingController();
  final TextEditingController _placeAddrController = TextEditingController();
  Map<String, String> _savedPlaces = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadSavedCredentials();
    _loadSavedPlaces();
    _startAutoDetectListener();
  }

  Future<void> _loadSavedCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _ssidController.text = prefs.getString('wifi_ssid') ?? '';
      _passController.text = prefs.getString('wifi_pass') ?? '';
      _isHotspotMode = prefs.getBool('wifi_hotspot') ?? true;
    });
  }

  Future<void> _saveCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('wifi_ssid', _ssidController.text.trim());
    await prefs.setString('wifi_pass', _passController.text.trim());
    await prefs.setBool('wifi_hotspot', _isHotspotMode);
  }

  Future<void> _loadSavedPlaces() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('saved_places') ?? '{}';
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _savedPlaces = map.cast<String, String>();
      });
    } catch (_) {}
  }

  Future<void> _savePlaces() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('saved_places', jsonEncode(_savedPlaces));
  }

  void _addPlace() {
    final name = _placeNameController.text.trim().toLowerCase();
    final addr = _placeAddrController.text.trim();
    if (name.isEmpty || addr.isEmpty) return;
    setState(() => _savedPlaces[name] = addr);
    _savePlaces();
    _placeNameController.clear();
    _placeAddrController.clear();
  }

  void _deletePlace(String key) {
    setState(() => _savedPlaces.remove(key));
    _savePlaces();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tempCleanup();
    _ssidController.dispose();
    _passController.dispose();
    _placeNameController.dispose();
    _placeAddrController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _startAutoDetectListener();
    } else if (state == AppLifecycleState.paused) {
      _tempCleanup();
    }
  }

  void _startAutoDetectListener() async {
    if (_tempUdpSocket != null || _isTransitioning) return;
    try {
      _tempUdpSocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        kUdpPort,
        reuseAddress: true,
      );
      _tempUdpSocket!.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read && !_isTransitioning) {
          Datagram? dg = _tempUdpSocket!.receive();
          if (dg != null && dg.data.isNotEmpty) {
            _goToFpvScreen();
          }
        }
      });
    } catch (e) {
      debugPrint("AutoDetect error: $e");
    }
  }

  void _tempCleanup() {
    _tempUdpSocket?.close();
    _tempUdpSocket = null;
  }

  void _goToFpvScreen() {
    if (_isTransitioning) return;
    setState(() => _isTransitioning = true);
    _tempCleanup();
    _saveCredentials();
    if (mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => FpvScreen(savedPlaces: Map.from(_savedPlaces)),
        ),
      );
    }
  }

  Future<String> _getMyIp({required bool hotspotMode}) async {
    if (hotspotMode) return "0.0.0.0";
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (var iface in interfaces) {
        final name = iface.name.toLowerCase();
        if (name.contains('rmnet') ||
            name.contains('ccmni') ||
            name.contains('tun') ||
            name.contains('ppp')) {
          continue;
        }
        for (var addr in iface.addresses) {
          final ip = addr.address;
          if (ip.startsWith('192.168.') ||
              ip.startsWith('10.') ||
              ip.startsWith('172.')) {
            return ip;
          }
        }
      }
    } catch (e) {
      debugPrint("Ошибка определения IP: $e");
    }
    return "0.0.0.0";
  }

  Future<void> _startProvisioning() async {
    setState(() {
      _isConnecting = true;
      _statusText = "Запрос разрешений...";
    });
    _tempCleanup();

    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
      Permission.microphone,
    ].request();
    debugPrint("BLE разрешения: $statuses");
    await Future.delayed(const Duration(milliseconds: 500));

    if (!mounted) return;
    setState(() => _statusText = "Проверка Bluetooth...");
    BluetoothAdapterState adapterState = BluetoothAdapterState.unknown;
    for (int i = 0; i < 10; i++) {
      adapterState = await FlutterBluePlus.adapterState.first;
      if (adapterState == BluetoothAdapterState.on) break;
      await Future.delayed(const Duration(milliseconds: 500));
    }

    if (adapterState != BluetoothAdapterState.on) {
      if (!mounted) return;
      setState(() {
        _statusText = "Ошибка: Включите Bluetooth!\nСостояние: $adapterState";
        _isConnecting = false;
      });
      _startAutoDetectListener();
      return;
    }

    if (!mounted) return;
    setState(() => _statusText = "Определяем настройки подключения...");
    final String myIp = await _getMyIp(hotspotMode: _isHotspotMode);

    if (!mounted) return;
    setState(
      () =>
          _statusText = "Поиск очков (30 сек)...\nУбедитесь что очки включены",
    );

    await Future.delayed(const Duration(milliseconds: 300));
    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 30));

    BluetoothDevice? targetDevice;
    int scanCount = 0;
    await for (var results in FlutterBluePlus.scanResults) {
      scanCount++;
      if (scanCount % 20 == 0) {
        final names = results
            .map(
              (r) => r.device.platformName.isEmpty
                  ? r.device.remoteId.toString()
                  : r.device.platformName,
            )
            .join(", ");
        if (mounted) {
          setState(
            () => _statusText = "Ищем... Найдено: ${results.length}\n$names",
          );
        }
      }
      for (var result in results) {
        if (result.device.platformName == "SmartGlasses") {
          targetDevice = result.device;
          FlutterBluePlus.stopScan();
          break;
        }
      }
      if (targetDevice != null) break;
    }

    if (targetDevice == null) {
      if (!mounted) return;
      setState(() {
        _statusText = "Очки не найдены. Мигают синим?";
        _isConnecting = false;
      });
      _startAutoDetectListener();
      return;
    }

    if (!mounted) return;
    setState(() => _statusText = "Подключение к очкам...");
    try {
      await targetDevice.connect(timeout: const Duration(seconds: 5));
      await Future.delayed(const Duration(milliseconds: 600));

      if (Platform.isAndroid) {
        try {
          setState(() => _statusText = "Согласование MTU...");
          await targetDevice.requestMtu(512);
          await Future.delayed(const Duration(milliseconds: 300));
        } catch (e) {
          debugPrint("MTU warning: $e");
        }
      }

      setState(() => _statusText = "Поиск характеристики...");
      List<BluetoothService> services = await targetDevice.discoverServices();
      await Future.delayed(const Duration(milliseconds: 300));

      BluetoothCharacteristic? targetChar;
      for (var s in services) {
        if (s.uuid.toString().toUpperCase().contains("FFFF")) {
          for (var c in s.characteristics) {
            if (c.uuid.toString().toUpperCase().contains("FF01")) {
              targetChar = c;
            }
          }
        }
      }

      if (targetChar != null) {
        setState(() => _statusText = "Отправка настроек...");
        String payload = jsonEncode({
          "s": _ssidController.text.trim(),
          "p": _passController.text.trim(),
          "i": myIp,
          "o": kUdpPort,
        });
        try {
          await targetChar.write(utf8.encode(payload), withoutResponse: false);
        } catch (e) {
          if (!e.toString().contains("133")) rethrow;
        }

        setState(
          () => _statusText =
              "Успешно! Очки перезагружаются...\nОжидаем видео поток...",
        );
        try {
          await targetDevice.disconnect();
        } catch (_) {}
        await Future.delayed(const Duration(seconds: 4));
        if (!mounted) return;
        _goToFpvScreen();
      } else {
        setState(() {
          _statusText = "Ошибка: характеристика BLE не найдена.";
          _isConnecting = false;
        });
        targetDevice.disconnect();
        _startAutoDetectListener();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _statusText = "Ошибка BLE: $e";
        _isConnecting = false;
      });
      targetDevice.disconnect();
      _startAutoDetectListener();
    }
  }

  bool get _statusIsError =>
      _statusText.contains('Ошибка') || _statusText.contains('не найден');

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text("Smart Glasses"),
        backgroundColor: Colors.transparent,
      ),
      body: GradientBackground(
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Center(child: HeroIcon()),
                const SizedBox(height: 8),
                const Center(
                  child: Text(
                    "Подключение очков",
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                      letterSpacing: -0.3,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                const Center(
                  child: Text(
                    "Настройте Wi-Fi и отправьте данные на устройство",
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 13,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
                const SizedBox(height: 28),

                GlassCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SectionHeader(
                        title: "Wi-Fi сеть",
                        subtitle: "Данные для подключения очков к интернету",
                        icon: Icons.wifi_rounded,
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _ssidController,
                        decoration: const InputDecoration(
                          labelText: "Название сети (SSID)",
                          prefixIcon: Icon(Icons.router_rounded, size: 20),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _passController,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: "Пароль",
                          prefixIcon: Icon(Icons.lock_outline_rounded, size: 20),
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Divider(),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text(
                          "Режим «Точка доступа»",
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        subtitle: const Text(
                          "Включите, если телефон раздаёт интернет (2.4 ГГц)",
                          style: TextStyle(fontSize: 12),
                        ),
                        value: _isHotspotMode,
                        onChanged: (val) => setState(() => _isHotspotMode = val),
                      ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          icon: const Icon(Icons.settings_cell_rounded, size: 18),
                          label: const Text("Настройки раздачи"),
                          onPressed: () {
                            AppSettings.openAppSettings(
                              type: AppSettingsType.hotspot,
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                GlassCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SectionHeader(
                        title: "Мои места",
                        subtitle:
                            "Скажите «иду домой» — и карта проложит маршрут",
                        icon: Icons.place_rounded,
                      ),
                      const SizedBox(height: 16),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            flex: 2,
                            child: TextField(
                              controller: _placeNameController,
                              decoration: const InputDecoration(
                                labelText: "«домой»",
                                isDense: true,
                              ),
                              textCapitalization: TextCapitalization.none,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            flex: 3,
                            child: TextField(
                              controller: _placeAddrController,
                              decoration: const InputDecoration(
                                labelText: "Адрес",
                                isDense: true,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            decoration: BoxDecoration(
                              gradient: AppColors.gradientPrimary,
                              borderRadius: BorderRadius.circular(14),
                            ),
                            child: Material(
                              color: Colors.transparent,
                              child: InkWell(
                                onTap: _addPlace,
                                borderRadius: BorderRadius.circular(14),
                                child: const SizedBox(
                                  width: 48,
                                  height: 48,
                                  child: Icon(
                                    Icons.add_rounded,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (_savedPlaces.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 8),
                          child: Text(
                            "Мест пока нет — добавьте хотя бы одно",
                            style: TextStyle(
                              color: AppColors.textMuted,
                              fontSize: 13,
                            ),
                          ),
                        )
                      else
                        ..._savedPlaces.entries.map(
                          (e) => PlaceChip(
                            name: e.key,
                            address: e.value,
                            onDelete: () => _deletePlace(e.key),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                GradientButton(
                  label: "Отправить на очки",
                  icon: Icons.bluetooth_connected_rounded,
                  isLoading: _isConnecting,
                  onPressed: _isConnecting ? null : _startProvisioning,
                ),
                const SizedBox(height: 12),
                Center(
                  child: TextButton.icon(
                    onPressed: _goToFpvScreen,
                    icon: const Icon(Icons.videocam_rounded, size: 18),
                    label: const Text("Очки уже подключены? Открыть камеру"),
                  ),
                ),
                const SizedBox(height: 20),
                StatusBanner(
                  text: _statusText,
                  isError: _statusIsError,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
