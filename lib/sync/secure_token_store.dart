import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'sync_service.dart';

/// Keeps the device token in the platform's protected storage (Android
/// Keystore, Windows credential store), never in the database or a backup (SEC-3).
class SecureTokenStore implements TokenStore {
  SecureTokenStore([FlutterSecureStorage? storage]) : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;
  static const _key = 'taskflow.sync.token';

  @override
  Future<String?> read() async {
    try {
      return await _storage.read(key: _key);
    } catch (_) {
      return null; // unreadable (for example after a reinstall): the device must pair again
    }
  }

  @override
  Future<void> write(String token) => _storage.write(key: _key, value: token);

  @override
  Future<void> clear() => _storage.delete(key: _key);
}
