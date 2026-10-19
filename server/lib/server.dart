/// Starting the server and the owner's admin commands.
library;

import 'dart:async';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:shelf/shelf_io.dart' as io;
import 'package:taskflow_core/sync.dart';

import 'api.dart';
import 'blobs.dart';
import 'google_api.dart';
import 'google_sync.dart';
import 'hooks.dart';
import 'store.dart';

/// Where attachment files live: `--blobs`, `TASKFLOW_BLOBS`, or a `blobs` folder beside the database.
Directory _blobDir(String dbPath, [String? override]) {
  final chosen = override ?? Platform.environment['TASKFLOW_BLOBS'];
  if (chosen != null && chosen.isNotEmpty) return Directory(chosen);
  return Directory('${File(dbPath).parent.path}${Platform.pathSeparator}blobs');
}

String _defaultDb() => Platform.environment['TASKFLOW_DB'] ?? 'data/taskflow.sqlite';

Store _open(String path) {
  final dir = File(path).parent;
  if (path != ':memory:' && !dir.existsSync()) dir.createSync(recursive: true);
  return Store.open(path);
}

class ServeCommand extends Command<int> {
  ServeCommand() {
    argParser
      ..addOption('port', defaultsTo: Platform.environment['PORT'] ?? '8080')
      ..addOption('host', defaultsTo: '0.0.0.0', help: 'Use 127.0.0.1 when a proxy such as Caddy is in front.')
      ..addOption('blobs', help: 'Folder for attachment files (default: a blobs folder beside the database).')
      ..addOption('max-file-mb', defaultsTo: '100', help: 'Largest single attachment.')
      ..addOption('quota-mb', defaultsTo: '5120', help: 'Most one person may store.')
      ..addOption('google-client-id', help: 'Google OAuth client id (or GOOGLE_CLIENT_ID). Turns on the Google Calendar connection.')
      ..addOption('google-client-secret', help: 'Google OAuth client secret (or GOOGLE_CLIENT_SECRET).')
      ..addOption('public-url', help: 'This server\'s public address, such as https://sync.example.com (or TASKFLOW_PUBLIC_URL). Needed for Google sign-in to come back.')
      ..addFlag('web', defaultsTo: true, help: 'Serve NoteDo for the web at /app (online only). Use --no-web to turn it off.')
      ..addFlag('allow-private-webhooks', help: 'Let webhooks call addresses on this server\'s own network. Off by default.')
      ..addFlag('trust-proxy', help: 'Read client addresses from X-Forwarded-For (only behind your own proxy).');
  }

  @override
  String get name => 'serve';
  @override
  String get description => 'Run the sync server.';

  @override
  Future<int> run() async {
    final store = _open(globalResults!['db'] as String);
    final allowPrivate = argResults!['allow-private-webhooks'] as bool;
    final hooks = WebhookDispatcher(store, allowPrivate: allowPrivate, log: stdout.writeln);
    final googleConfig = GoogleConfig.fromEnvironment(
      Platform.environment,
      clientId: argResults!['google-client-id'] as String?,
      clientSecret: argResults!['google-client-secret'] as String?,
      publicUrl: argResults!['public-url'] as String?,
    );
    final google = googleConfig == null ? null : GoogleApi(googleConfig);
    final googleSync = google == null ? null : GoogleSyncer(store, google, log: stdout.writeln);
    final googleTimers = <String, Timer>{};
    store.onApplied = (userId, applied) {
      hooks.onChanges(userId, applied);
      // A task changed: bring the person's Google calendar up to date soon (once a burst of edits settles).
      if (googleSync != null && !googleSync.isRunning(userId) && store.googleAccount(userId) != null) {
        googleTimers[userId]?.cancel();
        googleTimers[userId] = Timer(const Duration(seconds: 20), () => googleSync.syncInBackground(userId));
      }
    };
    Timer? googlePoll;
    if (googleSync != null) {
      // Also look for changes made in Google, which do not tell us themselves.
      googlePoll = Timer.periodic(const Duration(minutes: 5), (_) => googleSync.syncAll());
      stdout.writeln('Google Calendar connection is on (redirect address ${googleConfig!.redirectUri}).');
    }
    final handler = buildApi(
      store,
      config: ApiConfig(trustProxy: argResults!['trust-proxy'] as bool, allowPrivateWebhooks: allowPrivate, webClient: argResults!['web'] as bool),
      blobs: BlobStore(
        _blobDir(globalResults!['db'] as String, argResults!['blobs'] as String?)..createSync(recursive: true),
        maxBytes: int.parse(argResults!['max-file-mb'] as String) * 1024 * 1024,
        quotaBytes: int.parse(argResults!['quota-mb'] as String) * 1024 * 1024,
      ),
      google: google,
      googleSync: googleSync,
      log: stdout.writeln,
    );
    final server = await io.serve(handler, argResults!['host'] as String, int.parse(argResults!['port'] as String));
    stdout.writeln('TaskFlow sync server listening on ${server.address.host}:${server.port} (database: ${globalResults!['db']})');
    // Close cleanly on Ctrl+C or docker stop so SQLite finishes its writes.
    final done = Completer<void>();
    for (final signal in [ProcessSignal.sigint, if (!Platform.isWindows) ProcessSignal.sigterm]) {
      signal.watch().listen((_) async {
        if (done.isCompleted) return;
        await server.close(force: false);
        googlePoll?.cancel();
        for (final t in googleTimers.values) {
          t.cancel();
        }
        await hooks.flush();
        await googleSync?.flush();
        store.close();
        done.complete();
      });
    }
    await done.future;
    return 0;
  }
}

class UserCommand extends Command<int> {
  UserCommand() {
    addSubcommand(_UserAdd());
    addSubcommand(_UserList());
    addSubcommand(_UserDelete());
  }
  @override
  String get name => 'user';
  @override
  String get description => 'Add, list or delete people.';
}

class _UserAdd extends Command<int> {
  @override
  String get name => 'add';
  @override
  String get description => 'user add <name>: create an account (no password; devices join with a pairing code).';
  @override
  int run() {
    final names = argResults!.rest;
    if (names.length != 1) usageException('Give one name.');
    final store = _open(globalResults!['db'] as String);
    try {
      final a = store.createUser(names.first);
      stdout.writeln('Created ${a.name}. Make a pairing code with: invite ${a.name}');
      return 0;
    } on ArgumentError catch (e) {
      stderr.writeln(e.message);
      return 1;
    } finally {
      store.close();
    }
  }
}

class _UserList extends Command<int> {
  @override
  String get name => 'list';
  @override
  String get description => 'List people and their devices.';
  @override
  int run() {
    final store = _open(globalResults!['db'] as String);
    try {
      for (final u in store.listUsers()) {
        stdout.writeln('${u.name}  (${store.fieldCount(u.id)} stored fields)');
        for (final d in store.listDevices(u.id)) {
          final seen = d.lastSeen == null ? 'never' : DateTime.fromMillisecondsSinceEpoch(d.lastSeen! * 1000).toIso8601String();
          stdout.writeln('  ${d.id.substring(0, 8)}  ${d.name}  last seen $seen${d.revoked ? '  REVOKED' : ''}');
        }
      }
      return 0;
    } finally {
      store.close();
    }
  }
}

class _UserDelete extends Command<int> {
  _UserDelete() {
    argParser.addFlag('yes', help: 'Confirm that the person and all their data are deleted.');
  }
  @override
  String get name => 'delete';
  @override
  String get description => 'user delete <name> --yes: remove a person, their devices and all their data.';
  @override
  int run() {
    final names = argResults!.rest;
    if (names.length != 1) usageException('Give one name.');
    if (argResults!['yes'] != true) usageException('This deletes everything for ${names.first}. Add --yes to confirm.');
    final store = _open(globalResults!['db'] as String);
    try {
      final u = store.findUser(names.first);
      if (u == null) {
        stderr.writeln('No such user.');
        return 1;
      }
      store.deleteUser(u.id);
      BlobStore(_blobDir(globalResults!['db'] as String)).deleteUser(u.id);
      stdout.writeln('Deleted ${u.name}.');
      return 0;
    } finally {
      store.close();
    }
  }
}

class InviteCommand extends Command<int> {
  @override
  String get name => 'invite';
  @override
  String get description => 'invite <name>: print a one-time pairing code (valid 10 minutes) for a new device.';
  @override
  int run() {
    final names = argResults!.rest;
    if (names.length != 1) usageException('Give one name.');
    final store = _open(globalResults!['db'] as String);
    try {
      final u = store.findUser(names.first);
      if (u == null) {
        stderr.writeln('No such user. Create one with: user add ${names.first}');
        return 1;
      }
      final code = store.createInvite(u.id);
      stdout.writeln('Pairing code for ${u.name}: ${formatPairingCode(code)}');
      stdout.writeln('Enter it in the app (Settings, Sync). It works once and expires in ${pairingCodeTtl.inMinutes} minutes.');
      return 0;
    } finally {
      store.close();
    }
  }
}

class TokenCommand extends Command<int> {
  TokenCommand() {
    argParser.addFlag('read-only', help: 'The token can read but not change data.');
  }
  @override
  String get name => 'token';
  @override
  String get description => 'token <name> <label> [--read-only]: make an API token for scripts (shown once).';
  @override
  int run() {
    final args = argResults!.rest;
    if (args.length != 2) usageException('Give a person and a label, for example: token Alice "backup script".');
    final store = _open(globalResults!['db'] as String);
    try {
      final u = store.findUser(args[0]);
      if (u == null) {
        stderr.writeln('No such user.');
        return 1;
      }
      final t = store.createApiToken(u.id, args[1], readOnly: argResults!['read-only'] as bool);
      stdout.writeln('API token for ${u.name} (${args[1]}):');
      stdout.writeln(t.token);
      stdout.writeln('This is the only time it is shown. Use it as: Authorization: Bearer <token>');
      return 0;
    } on ArgumentError catch (e) {
      stderr.writeln(e.message);
      return 1;
    } finally {
      store.close();
    }
  }
}

class RevokeCommand extends Command<int> {
  @override
  String get name => 'revoke';
  @override
  String get description => 'revoke <name> <device-id-prefix>: sign a device out for good.';
  @override
  int run() {
    final args = argResults!.rest;
    if (args.length != 2) usageException('Give a name and the first characters of a device id (see "user list").');
    final store = _open(globalResults!['db'] as String);
    try {
      final u = store.findUser(args[0]);
      if (u == null) {
        stderr.writeln('No such user.');
        return 1;
      }
      final matches = store.listDevices(u.id).where((d) => d.id.startsWith(args[1])).toList();
      if (matches.length != 1) {
        stderr.writeln(matches.isEmpty ? 'No device starts with that.' : 'More than one device matches; give more characters.');
        return 1;
      }
      store.revokeDevice(u.id, matches.single.id);
      stdout.writeln('Revoked ${matches.single.name}.');
      return 0;
    } finally {
      store.close();
    }
  }
}

class BackupCommand extends Command<int> {
  @override
  String get name => 'backup';
  @override
  String get description => 'backup <file>: write a consistent copy of the database (safe while the server runs).';
  @override
  int run() {
    final args = argResults!.rest;
    if (args.length != 1) usageException('Give a destination file.');
    final store = _open(globalResults!['db'] as String);
    try {
      store.backupTo(args.first);
      stdout.writeln('Wrote ${args.first}');
      return 0;
    } finally {
      store.close();
    }
  }
}

CommandRunner<int> buildRunner() {
  final runner = CommandRunner<int>('taskflow_server', 'The TaskFlow sync server and its admin tools.')
    ..argParser.addOption('db', defaultsTo: _defaultDb(), help: 'Database file (or set TASKFLOW_DB).')
    ..addCommand(ServeCommand())
    ..addCommand(UserCommand())
    ..addCommand(InviteCommand())
    ..addCommand(TokenCommand())
    ..addCommand(RevokeCommand())
    ..addCommand(BackupCommand());
  return runner;
}
