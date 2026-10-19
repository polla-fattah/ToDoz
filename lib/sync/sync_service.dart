import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:taskflow_core/sync.dart';

import '../data/database.dart';
import '../data/repository.dart';
import 'blob_sync.dart';
import 'share_notifier.dart';
import 'sync_engine.dart';
import 'transport.dart';

/// Where the device token is kept. The real one uses the platform's secure
/// storage (Android Keystore); tests use memory (SEC-3).
abstract class TokenStore {
  Future<String?> read();
  Future<void> write(String token);
  Future<void> clear();
}

class MemoryTokenStore implements TokenStore {
  String? _token;
  @override
  Future<String?> read() async => _token;
  @override
  Future<void> write(String token) async => _token = token;
  @override
  Future<void> clear() async => _token = null;
}

/// Schedules the sync that runs while the app is closed. The real one is WorkManager (Android);
/// tests use a recorder.
abstract class BackgroundScheduler {
  Future<void> enable();
  Future<void> disable();
}

enum SyncState { unpaired, idle, syncing, error, signedOut }

/// Pairing, and keeping this device in step with the server. One per app.
class SyncService extends ChangeNotifier with WidgetsBindingObserver {
  SyncService(this.repo, this.tokens,
      {this.blobs, this.notifier, this.client, this.scheduler, this.interval = const Duration(seconds: 30), this.debounce = const Duration(seconds: 2)});

  final Repo repo;
  AppDatabase get db => repo.db;
  final TokenStore tokens;

  /// Moves attachment files after each sync; null when attachments are not used (tests).
  final BlobSync? blobs;

  /// Tells the person about comments and assignments from others after each sync; null in tests that do not need it.
  final ShareNotifier? notifier;

  /// The last problem moving files, shown beside the sync status.
  String? blobError;
  final http.Client? client;

  /// Runs a sync every so often while the app is closed; null where that is not available.
  final BackgroundScheduler? scheduler;

  /// Whether to sync while the app is closed (Settings, Sync). On unless switched off.
  bool backgroundSync = true;
  final Duration interval;
  final Duration debounce;

  SyncState state = SyncState.unpaired;
  Uri? serverUrl;
  String? userName;
  String? deviceName;
  DateTime? lastSyncAt;
  String? lastError;
  int pendingChanges = 0;

  String? _token;
  bool _again = false;
  Future<void>? _current;
  bool _disposed = false;
  Timer? _timer;
  Timer? _debounceTimer;
  StreamSubscription<int>? _outboxWatch;

  bool get paired => state != SyncState.unpaired;

  void _set(void Function() f) {
    if (_disposed) return;
    f();
    notifyListeners();
  }

  ServerApi _api({String? token}) => ServerApi(serverUrl!, token: token ?? _token, client: client);

  /// Loads the saved pairing (if any). With [background] (the app) it also starts syncing on a timer and after
  /// edits; without it (the job that runs while the app is closed) nothing is started and the caller syncs once.
  Future<void> init({bool background = true}) async {
    final url = await repo.getSetting('sync.url');
    final token = await tokens.read();
    if (url == null || token == null || Uri.tryParse(url) == null) {
      _set(() => state = SyncState.unpaired);
      return;
    }
    serverUrl = Uri.parse(url);
    _token = token;
    userName = await repo.getSetting('sync.user');
    deviceName = await repo.getSetting('sync.device');
    final last = int.tryParse(await repo.getSetting('sync.last') ?? '');
    lastSyncAt = last == null ? null : DateTime.fromMillisecondsSinceEpoch(last);
    state = (await repo.getSetting('sync.signedout')) == '1' ? SyncState.signedOut : SyncState.idle;
    backgroundSync = (await repo.getSetting(backgroundSyncKey)) != '0';
    await repo.loadMe();
    if (!background) return;
    _startBackground();
    notifyListeners();
    unawaited(_reconcileSchedule());
    if (state == SyncState.idle) unawaited(syncNow());
  }

  /// The setting that switches syncing while the app is closed off (`0`) or on.
  static const backgroundSyncKey = 'sync.background';

  /// Turns syncing while the app is closed on or off.
  Future<void> setBackgroundSync(bool on) async {
    backgroundSync = on;
    await repo.setSetting(backgroundSyncKey, on ? '1' : '0');
    notifyListeners();
    await _reconcileSchedule();
  }

  /// Makes the scheduled job match the pairing and the setting.
  Future<void> _reconcileSchedule() async {
    final s = scheduler;
    if (s == null) return;
    try {
      if (paired && state != SyncState.signedOut && backgroundSync) {
        await s.enable();
      } else {
        await s.disable();
      }
    } catch (_) {
      // The platform may not support it; the app still syncs while it is open.
    }
  }

  // ---------------------------------------------------------------------------
  // Pairing
  // ---------------------------------------------------------------------------

  /// Swaps a pairing code for a device token, then uploads this device's data
  /// and downloads the rest. Throws [SyncTransportException] with a message
  /// fit to show the owner.
  Future<void> pair(String urlText, String code, String device) async {
    final url = parseServerUrl(urlText);
    if (url == null) {
      throw SyncTransportException('Enter the server address, for example sync.example.com. Plain http:// is only allowed on your own network.');
    }
    final api = ServerApi(url, client: client);
    final info = await api.pair(code, device);
    serverUrl = url;
    _token = info.token;
    await tokens.write(info.token);
    await repo.setSetting('sync.url', url.toString());
    await repo.setSetting('sync.user', info.userName);
    await repo.setSetting('sync.device', device.trim().isEmpty ? 'Device' : device.trim());
    await repo.setSetting('sync.signedout', '0');
    await repo.setMe(info.userId);
    userName = info.userName;
    deviceName = device;
    await SyncEngine(db, _api()).enable();
    _set(() => state = SyncState.idle);
    _startBackground();
    unawaited(_reconcileSchedule());
    await syncNow();
  }

  /// Forgets the server on this device. Local tasks stay (FR-A3: sync is an add-on).
  Future<void> unpair() async {
    _stopBackground();
    await SyncEngine(db, MemoryTransport()).disable();
    await tokens.clear();
    await repo.setMe(null);
    await repo.forgetShares();
    for (final k in ['sync.url', 'sync.user', 'sync.device', 'sync.last', 'sync.signedout']) {
      await db.customStatement('DELETE FROM settings WHERE key = ?', [k]);
    }
    _token = null;
    serverUrl = null;
    userName = null;
    lastSyncAt = null;
    lastError = null;
    pendingChanges = 0;
    _set(() => state = SyncState.unpaired);
    await _reconcileSchedule();
  }

  // ---------------------------------------------------------------------------
  // Syncing
  // ---------------------------------------------------------------------------

  /// Syncs now. If a sync is already running, it goes round once more and
  /// this completes when that is done, so callers can rely on "my edits are sent".
  Future<void> syncNow() {
    if (!paired || state == SyncState.signedOut || _token == null) return Future.value();
    final running = _current;
    if (running != null) {
      _again = true; // something changed during a sync: go round once more
      return running;
    }
    return _current = _loop();
  }

  Future<void> _loop() async {
    try {
      // Nothing may be awaited between the last check of _again and clearing
      // _current, or an edit that arrives in that gap would wait for the next timer.
      do {
        _again = false;
        await _pass();
      } while (_again && state == SyncState.idle);
    } finally {
      _current = null;
    }
  }

  Future<void> _pass() async {
    _set(() {
      state = SyncState.syncing;
      lastError = null;
    });
    try {
      await SyncEngine(db, _api()).run();
      if (repo.me == null) await _learnWhoIAm();
      await _moveFiles();
      try {
        await notifier?.check();
      } catch (_) {
        // A failed alert must never fail the sync.
      }
      lastSyncAt = repo.now;
      await repo.setSetting('sync.last', '${lastSyncAt!.millisecondsSinceEpoch}');
      _set(() => state = SyncState.idle);
    } on SyncTransportException catch (e) {
      if (e.unauthorized) {
        await repo.setSetting('sync.signedout', '1');
        _stopBackground();
        _set(() {
          state = SyncState.signedOut;
          lastError = e.message;
        });
        unawaited(_reconcileSchedule());
      } else {
        _set(() {
          state = SyncState.error;
          lastError = e.message;
        });
      }
    } catch (e) {
      _set(() {
        state = SyncState.error;
        lastError = 'Sync failed: $e';
      });
    } finally {
      pendingChanges = await SyncEngine(db, MemoryTransport()).pending();
      if (!_disposed) notifyListeners();
    }
  }

  /// A device paired before sharing existed does not know its user id yet: ask once.
  Future<void> _learnWhoIAm() async {
    try {
      final me = await _api().me();
      if (me.userId != null) await repo.setMe(me.userId);
    } catch (_) {
      // Try again at the next sync.
    }
  }

  Future<void> _moveFiles() async {
    final b = blobs;
    if (b == null) return;
    try {
      final r = await b.run(_api());
      blobError = r.error;
    } on SyncTransportException catch (e) {
      if (e.unauthorized) rethrow;
      blobError = e.message;
    } catch (e) {
      blobError = 'Files could not be moved: ${e.toString().split('\n').first}';
    }
  }

  /// Downloads one attachment now, for a person who tapped it. Returns false if it is not on the server.
  Future<bool> fetchAttachment(String hash) async {
    final b = blobs;
    if (b == null || serverUrl == null || _token == null) return false;
    return b.fetch(_api(), hash);
  }

  /// Discards this device's synced data and downloads it again (FR-S7).
  Future<void> resetFromServer() async {
    _debounceTimer?.cancel();
    while (_current != null) {
      await _current; // let a sync in progress finish first
    }
    final done = Completer<void>();
    _current = done.future; // keeps background syncs out while the data is replaced
    _set(() => state = SyncState.syncing);
    try {
      await SyncEngine(db, _api()).resetFromServer();
      lastSyncAt = repo.now;
      _set(() => state = SyncState.idle);
    } on SyncTransportException catch (e) {
      _set(() {
        state = e.unauthorized ? SyncState.signedOut : SyncState.error;
        lastError = e.message;
      });
      rethrow;
    } finally {
      _current = null;
      done.complete();
      db.markTablesUpdated(db.allTables);
    }
  }

  /// A client for the paired server (for the integrations screen), or null when not paired.
  ServerApi? get api => serverUrl == null || _token == null ? null : _api();

  Future<MeInfo> loadMe() => _api().me();

  Future<void> revokeDevice(String id) => _api().revokeDevice(id);

  /// Deletes the account and everything stored for it on the server (SEC-17),
  /// then unpairs this device. Local data stays.
  Future<void> deleteServerData() async {
    await _api().deleteAccount();
    await unpair();
  }

  // ---------------------------------------------------------------------------
  // Background upkeep
  // ---------------------------------------------------------------------------

  void _startBackground() {
    _stopBackground();
    // Send soon after an edit (FR-S2): watch the queue and sync a moment after it grows.
    _outboxWatch = db
        .customSelect('SELECT COUNT(*) AS n FROM outbox', readsFrom: {db.outbox})
        .watchSingle()
        .map((r) => r.read<int>('n'))
        .listen((n) {
      if (_disposed) return;
      pendingChanges = n;
      notifyListeners();
      if (n > 0) {
        _debounceTimer?.cancel();
        _debounceTimer = Timer(debounce, () => syncNow());
      }
    });
    _timer = Timer.periodic(interval, (_) => syncNow());
    WidgetsBinding.instance.addObserver(this);
  }

  void _stopBackground() {
    _timer?.cancel();
    _debounceTimer?.cancel();
    _outboxWatch?.cancel();
    _timer = null;
    _outboxWatch = null;
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // The job that runs while the app is closed writes to the file from another isolate, which this
      // one is not told about: make open screens read it again.
      db.markTablesUpdated(db.allTables);
      unawaited(syncNow());
    }
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _stopBackground();
    super.dispose();
  }
}

/// A transport that is never used, for engine calls that only touch the local database.
class MemoryTransport implements SyncTransport {
  @override
  Future<SyncResponse> sync(SyncRequest request) => throw UnsupportedError('No server');
}
