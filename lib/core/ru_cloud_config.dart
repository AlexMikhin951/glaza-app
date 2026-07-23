import 'package:shared_preferences/shared_preferences.dart';

/// Контур российских облачных API (Yandex Cloud + опционально GigaChat).
///
/// Ключи: `--dart-define=YANDEX_CLOUD_API_KEY=...` и
/// `--dart-define=YANDEX_FOLDER_ID=...` или настройки приложения.
class RuCloudConfig {
  static const _prefOffline = 'offline_only';
  static const _prefApiKey = 'yandex_cloud_api_key';
  static const _prefFolder = 'yandex_folder_id';
  static const _prefSpeechRate = 'tts_speech_rate';
  static const _prefSosPhone = 'sos_phone';
  static const _prefSosName = 'sos_contact_name';
  static const _prefStreetQuiet = 'street_quiet';
  static const _prefSoundscape = 'soundscape_enabled';
  static const _prefGiga = 'gigachat_auth_key';

  static const String _defineApiKey = String.fromEnvironment(
    'YANDEX_CLOUD_API_KEY',
    defaultValue: '',
  );
  static const String _defineFolder = String.fromEnvironment(
    'YANDEX_FOLDER_ID',
    defaultValue: '',
  );
  static const String _defineGiga = String.fromEnvironment(
    'GIGACHAT_AUTH_KEY',
    defaultValue: '',
  );

  bool offlineOnly = false;
  String apiKey = '';
  String folderId = '';
  String gigachatAuthKey = '';
  double speechRate = 0.5;
  String sosPhone = '';
  String sosContactName = '';
  bool streetQuiet = false;
  bool soundscapeEnabled = true;

  bool get hasYandexCloud =>
      !offlineOnly && apiKey.isNotEmpty && folderId.isNotEmpty;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    offlineOnly = prefs.getBool(_prefOffline) ?? false;
    apiKey = prefs.getString(_prefApiKey) ?? _defineApiKey;
    folderId = prefs.getString(_prefFolder) ?? _defineFolder;
    gigachatAuthKey = prefs.getString(_prefGiga) ?? _defineGiga;
    speechRate = prefs.getDouble(_prefSpeechRate) ?? 0.5;
    sosPhone = prefs.getString(_prefSosPhone) ?? '';
    sosContactName = prefs.getString(_prefSosName) ?? '';
    streetQuiet = prefs.getBool(_prefStreetQuiet) ?? false;
    soundscapeEnabled = prefs.getBool(_prefSoundscape) ?? true;
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefOffline, offlineOnly);
    await prefs.setString(_prefApiKey, apiKey);
    await prefs.setString(_prefFolder, folderId);
    await prefs.setString(_prefGiga, gigachatAuthKey);
    await prefs.setDouble(_prefSpeechRate, speechRate);
    await prefs.setString(_prefSosPhone, sosPhone);
    await prefs.setString(_prefSosName, sosContactName);
    await prefs.setBool(_prefStreetQuiet, streetQuiet);
    await prefs.setBool(_prefSoundscape, soundscapeEnabled);
  }

  Future<void> setOfflineOnly(bool value) async {
    offlineOnly = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefOffline, value);
  }

  Future<void> setSpeechRate(double rate) async {
    speechRate = rate.clamp(0.2, 1.0);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_prefSpeechRate, speechRate);
  }

  Future<void> setSosContact({required String phone, String name = ''}) async {
    sosPhone = phone.trim();
    sosContactName = name.trim();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefSosPhone, sosPhone);
    await prefs.setString(_prefSosName, sosContactName);
  }
}
