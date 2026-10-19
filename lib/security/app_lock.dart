import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:local_auth/local_auth.dart';

import 'secret_store.dart';

/// Fingerprint or face check, behind an interface so tests need no phone.
abstract class Biometric {
  Future<bool> available();
  Future<bool> authenticate(String reason);
}

class DeviceBiometric implements Biometric {
  final _auth = LocalAuthentication();

  @override
  Future<bool> available() async {
    try {
      return await _auth.canCheckBiometrics && (await _auth.getAvailableBiometrics()).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> authenticate(String reason) async {
    try {
      return await _auth.authenticate(localizedReason: reason, biometricOnly: true, persistAcrossBackgrounding: true);
    } catch (_) {
      return false;
    }
  }
}

enum UnlockResult { ok, wrong, waiting }

/// A PIN (and optionally biometrics) that must be passed when the app opens
/// and after it has been in the background for a while (FR-U4).
///
/// The PIN is never stored: only a salted hash, made slow with many rounds,
/// in the platform's secure storage. After five wrong tries the next try has
/// to wait, and the wait doubles.
class AppLock extends ChangeNotifier with WidgetsBindingObserver {
  AppLock(this._store, {this.biometric, this.timeout = const Duration(minutes: 1), DateTime Function()? clock, this.rounds = 20000})
      : _now = clock ?? DateTime.now;

  final SecretStore _store;
  final Biometric? biometric;
  final Duration timeout;
  final int rounds;
  final DateTime Function() _now;

  static const _kHash = 'taskflow.lock.pin';
  static const _kBio = 'taskflow.lock.biometric';
  static const _kFails = 'taskflow.lock.fails';
  static const _kUntil = 'taskflow.lock.until';
  static const freeTries = 5;

  bool enabled = false;
  bool locked = false;
  bool biometricEnabled = false;
  int failures = 0;
  DateTime? waitUntil;
  DateTime? _wentToBackground;
  bool _observing = false;

  Future<void> init() async {
    enabled = await _store.read(_kHash) != null;
    biometricEnabled = enabled && await _store.read(_kBio) == '1';
    failures = int.tryParse(await _store.read(_kFails) ?? '') ?? 0;
    final until = int.tryParse(await _store.read(_kUntil) ?? '');
    waitUntil = until == null ? null : DateTime.fromMillisecondsSinceEpoch(until);
    locked = enabled; // opening the app always starts locked
    _observe();
    notifyListeners();
  }

  void _observe() {
    if (_observing) return;
    _observing = true;
    WidgetsBinding.instance.addObserver(this);
  }

  Future<bool> canUseBiometric() async => await biometric?.available() ?? false;

  // --- the PIN ---------------------------------------------------------------------

  static bool validPin(String pin) => RegExp(r'^\d{4,12}$').hasMatch(pin);

  String _hash(String pin, List<int> salt, int rounds) {
    var h = sha256.convert([...salt, ...utf8.encode(pin)]).bytes;
    for (var i = 1; i < rounds; i++) {
      h = sha256.convert([...salt, ...h]).bytes;
    }
    return 'v1:$rounds:${base64.encode(salt)}:${base64.encode(h)}';
  }

  bool _check(String pin, String stored) {
    final parts = stored.split(':');
    if (parts.length != 4 || parts[0] != 'v1') return false;
    final expected = _hash(pin, base64.decode(parts[2]), int.parse(parts[1]));
    if (expected.length != stored.length) return false;
    var diff = 0;
    for (var i = 0; i < expected.length; i++) {
      diff |= expected.codeUnitAt(i) ^ stored.codeUnitAt(i);
    }
    return diff == 0;
  }

  /// Turns the lock on with a new PIN of 4 to 12 digits.
  Future<void> enable(String pin, {bool useBiometric = false}) async {
    if (!validPin(pin)) throw ArgumentError('The PIN must be 4 to 12 digits');
    final rnd = Random.secure();
    final salt = List<int>.generate(16, (_) => rnd.nextInt(256));
    await _store.write(_kHash, _hash(pin, salt, rounds));
    await _store.write(_kBio, useBiometric ? '1' : '0');
    await _resetFailures();
    enabled = true;
    biometricEnabled = useBiometric;
    locked = false; // the person has just proved they know it
    notifyListeners();
  }

  /// Turns the lock off; needs the current PIN.
  Future<bool> disable(String pin) async {
    if (await _verify(pin) != UnlockResult.ok) return false;
    await _store.delete(_kHash);
    await _store.delete(_kBio);
    await _resetFailures();
    enabled = false;
    biometricEnabled = false;
    locked = false;
    notifyListeners();
    return true;
  }

  Future<void> setBiometric(bool on) async {
    if (!enabled) return;
    await _store.write(_kBio, on ? '1' : '0');
    biometricEnabled = on;
    notifyListeners();
  }

  Future<UnlockResult> _verify(String pin) async {
    final until = waitUntil;
    if (until != null && _now().isBefore(until)) return UnlockResult.waiting;
    final stored = await _store.read(_kHash);
    if (stored == null) return UnlockResult.ok;
    if (_check(pin, stored)) {
      await _resetFailures();
      return UnlockResult.ok;
    }
    failures++;
    await _store.write(_kFails, '$failures');
    if (failures >= freeTries) {
      final seconds = min(30 * pow(2, failures - freeTries).toInt(), 15 * 60);
      waitUntil = _now().add(Duration(seconds: seconds));
      await _store.write(_kUntil, '${waitUntil!.millisecondsSinceEpoch}');
    }
    notifyListeners();
    return UnlockResult.wrong;
  }

  Future<void> _resetFailures() async {
    failures = 0;
    waitUntil = null;
    await _store.delete(_kFails);
    await _store.delete(_kUntil);
  }

  /// Seconds left until another PIN try is allowed; 0 when free.
  int get waitSeconds {
    final until = waitUntil;
    if (until == null) return 0;
    final left = until.difference(_now()).inSeconds + 1;
    return left > 0 ? left : 0;
  }

  Future<UnlockResult> unlock(String pin) async {
    final r = await _verify(pin);
    if (r == UnlockResult.ok) {
      locked = false;
      notifyListeners();
    }
    return r;
  }

  Future<bool> unlockWithBiometric() async {
    if (!biometricEnabled || biometric == null) return false;
    final ok = await biometric!.authenticate('Unlock TaskFlow');
    if (ok) {
      locked = false;
      notifyListeners();
    }
    return ok;
  }

  /// Locks at once (the "lock now" button).
  void lockNow() {
    if (!enabled) return;
    locked = true;
    notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!enabled) return;
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _wentToBackground ??= _now();
    } else if (state == AppLifecycleState.resumed) {
      final left = _wentToBackground;
      _wentToBackground = null;
      if (left != null && _now().difference(left) >= timeout && !locked) {
        locked = true;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    if (_observing) WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
