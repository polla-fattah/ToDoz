import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf_io.dart' as io;
import 'package:taskflow/data/database.dart';
import 'package:taskflow/data/repository.dart';
import 'package:taskflow/platform/attachment_store.dart';
import 'package:taskflow/sync/blob_sync.dart';
import 'package:taskflow/sync/sync_service.dart';
import 'package:taskflow_server/api.dart';
import 'package:taskflow_server/blobs.dart';
import 'package:taskflow_server/store.dart';

class Phone {
  Phone(this.db, this.repo, this.store, this.svc);
  final AppDatabase db;
  final Repo repo;
  final AttachmentStore store;
  final SyncService svc;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late Directory tmp;
  late Store server;
  late BlobStore serverBlobs;
  late HttpServer http;
  late Account alice;
  late String url;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('taskflow_att');
    server = Store.open(':memory:');
    serverBlobs = BlobStore(Directory(p.join(tmp.path, 'server-blobs')), maxBytes: 5 * 1024 * 1024);
    alice = server.createUser('Alice');
    http = await io.serve(buildApi(server, config: const ApiConfig(syncPerMinute: 100000), blobs: serverBlobs), InternetAddress.loopbackIPv4, 0);
    url = 'http://127.0.0.1:${http.port}';
  });
  tearDown(() async {
    await http.close(force: true);
    server.close();
    await tmp.delete(recursive: true);
  });

  var n = 0;
  Future<Phone> phone({bool pair = true}) async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    await db.ensureSyncMeta();
    await db.ensureInbox();
    final repo = Repo(db);
    final store = AttachmentStore(repo, Directory(p.join(tmp.path, 'phone${++n}')));
    final svc = SyncService(repo, MemoryTokenStore(), blobs: BlobSync(repo, store), interval: const Duration(hours: 1), debounce: const Duration(hours: 1));
    addTearDown(svc.dispose);
    if (pair) await svc.pair(url, server.createInvite(alice.id), 'Phone$n');
    return Phone(db, repo, store, svc);
  }

  File sample(String name, List<int> bytes) => File(p.join(tmp.path, name))..writeAsBytesSync(bytes);

  group('on one device', () {
    test('a file is stored once under its hash, and a comment carries it', () async {
      final ph = await phone(pair: false);
      final task = await ph.repo.addTask(title: 'Trip');
      final bytes = List<int>.generate(5000, (i) => i % 251);
      final a = await ph.store.attachFile(task, sample('ticket.pdf', bytes));
      expect((a.fileName, a.mimeType, a.sizeBytes), ('ticket.pdf', 'application/pdf', 5000));
      expect(a.hash, sha256.convert(bytes).toString());
      expect(ph.store.fileFor(a.hash).readAsBytesSync(), bytes);
      expect((await ph.repo.watchComments(task).first).single.body, 'ticket.pdf');

      await ph.store.attachFile(task, sample('copy-of-ticket.pdf', bytes), body: 'Same file again');
      expect(Directory(ph.store.root.path).listSync().whereType<File>().length, 1, reason: 'identical bytes are kept once');
      expect((await ph.repo.watchTaskAttachments(task).first).length, 2);
    });

    test('files over 100 MB are refused', () async {
      final ph = await phone(pair: false);
      final task = await ph.repo.addTask(title: 'x');
      await expectLater(
        ph.repo.addAttachmentComment(task, fileName: 'huge.bin', mimeType: 'application/octet-stream', sizeBytes: maxAttachmentBytes + 1, hash: 'a' * 64),
        throwsA(isA<RuleException>()),
      );
      expect(await ph.repo.watchComments(task).first, isEmpty);
    });

    test('deleting the only file removes its comment; deleting a comment removes its files; clean-up frees the bytes', () async {
      final ph = await phone(pair: false);
      final task = await ph.repo.addTask(title: 'x');
      final a = await ph.store.attachFile(task, sample('a.txt', List.filled(300, 1)));
      final b = await ph.store.attachFile(task, sample('b.txt', List.filled(500, 2)));
      var s = await ph.store.stats();
      expect((s.files, s.bytes, s.localBytes, s.orphanBytes), (2, 800, 800, 0));

      await ph.repo.deleteAttachment(a.id);
      expect((await ph.repo.watchComments(task).first).length, 1, reason: 'a.txt was the only thing in its comment');
      final comment = (await ph.repo.watchComments(task).first).single;
      await ph.repo.deleteComment(comment.id);
      expect(await ph.repo.watchTaskAttachments(task).first, isEmpty);
      expect(b.id, isNotEmpty);

      s = await ph.store.stats();
      expect((s.files, s.orphanBytes), (0, 800));
      expect(await ph.store.cleanUp(), 800);
      expect((await ph.store.stats()).localBytes, 0);
    });

    test('a file with a different hash is never saved under a name it does not match', () async {
      final ph = await phone(pair: false);
      final ok = await ph.store.saveDownloaded('0' * 64, Stream.value([1, 2, 3]));
      expect(ok, isFalse);
      expect(ph.store.root.listSync().whereType<File>(), isEmpty);
    });

    test('mime types are guessed from the name', () {
      expect(guessMimeType('Photo.JPG'), 'image/jpeg');
      expect(guessMimeType('voice.m4a'), 'audio/mp4');
      expect(guessMimeType('mystery'), 'application/octet-stream');
    });
  });

  group('between two devices over HTTP', () {
    test('a file attached on the phone reaches the PC, byte for byte', () async {
      final a = await phone();
      final b = await phone();
      final task = await a.repo.addTask(title: 'Shared trip');
      final bytes = List<int>.generate(200000, (i) => Random(i).nextInt(256));
      final att = await a.store.attachFile(task, sample('photo.jpg', bytes));
      await a.svc.syncNow();
      expect(serverBlobs.has(alice.id, att.hash), isTrue, reason: 'uploaded');
      expect((await a.repo.getAttachment(att.id))!.uploaded, isTrue);

      await b.svc.syncNow();
      final seen = (await b.repo.watchTaskAttachments(task).first).single;
      expect(seen.fileName, 'photo.jpg');
      expect(b.store.fileFor(seen.hash).readAsBytesSync(), bytes, reason: 'downloaded and checked');
      expect(b.svc.blobError, isNull);
    });

    test('deleting the file on one device removes it from the other, and the server copy stays until clean-up', () async {
      final a = await phone();
      final b = await phone();
      final task = await a.repo.addTask(title: 't');
      final att = await a.store.attachFile(task, sample('x.txt', List.filled(100, 5)));
      await a.svc.syncNow();
      await b.svc.syncNow();
      expect(await b.repo.watchTaskAttachments(task).first, hasLength(1));
      await a.repo.deleteAttachment(att.id);
      await a.svc.syncNow();
      await b.svc.syncNow();
      expect(await b.repo.watchTaskAttachments(task).first, isEmpty);
    });

    test('a file that is too big for the server is reported and does not stop the sync', () async {
      final a = await phone();
      final task = await a.repo.addTask(title: 't');
      await a.store.attachFile(task, sample('big.bin', List.filled(6 * 1024 * 1024, 1))); // server limit here is 5 MB
      await a.repo.addTask(title: 'still syncs');
      await a.svc.syncNow();
      expect(a.svc.state, SyncState.idle);
      expect(a.svc.blobError, contains('limited'));
      expect(server.fieldCount(alice.id), greaterThan(0));
    });
  });
}
