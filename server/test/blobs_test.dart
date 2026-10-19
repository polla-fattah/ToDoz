import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:shelf/shelf.dart';
import 'package:taskflow_server/api.dart';
import 'package:taskflow_server/blobs.dart';
import 'package:taskflow_server/store.dart';
import 'package:test/test.dart';

String sha(List<int> bytes) => sha256.convert(bytes).toString();

void main() {
  late Store store;
  late Directory dir;
  late BlobStore blobs;
  late Handler api;
  late Account alice;
  late Account bob;

  setUp(() async {
    store = Store.open(':memory:');
    dir = await Directory.systemTemp.createTemp('taskflow_blobs');
    blobs = BlobStore(dir, maxBytes: 1000, quotaBytes: 2500);
    api = buildApi(store, config: const ApiConfig(trustProxy: true), blobs: blobs);
    alice = store.createUser('Alice');
    bob = store.createUser('Bob');
  });
  tearDown(() async {
    store.close();
    await dir.delete(recursive: true);
  });

  Future<String> token(Account a) async {
    final r = await api(Request('POST', Uri.parse('http://x/v1/pair'),
        headers: {'content-type': 'application/json', 'x-forwarded-for': '1.1.1.1'}, body: jsonEncode({'code': store.createInvite(a.id), 'deviceName': 'p'})));
    return (jsonDecode(await r.readAsString()) as Map)['token'] as String;
  }

  Future<Response> call(String method, String path, {String? token, List<int>? body}) async =>
      await api(Request(method, Uri.parse('http://x$path'), headers: {if (token != null) 'authorization': 'Bearer $token', 'x-forwarded-for': '1.1.1.1'}, body: body));

  test('a file is stored under its hash and read back byte for byte', () async {
    final t = await token(alice);
    final bytes = List<int>.generate(700, (i) => i % 256);
    final put = await call('PUT', '/v1/blobs/${sha(bytes)}', token: t, body: bytes);
    expect(put.statusCode, 201);
    final head = await call('HEAD', '/v1/blobs/${sha(bytes)}', token: t);
    expect((head.statusCode, head.headers['content-length']), (200, '700'));
    final get = await call('GET', '/v1/blobs/${sha(bytes)}', token: t);
    expect(await get.read().expand((c) => c).toList(), bytes);
    // Uploading it again is a harmless no-op.
    expect((await call('PUT', '/v1/blobs/${sha(bytes)}', token: t, body: bytes)).statusCode, 201);
    expect(blobs.usedBytes(alice.id), 700);
  });

  test('a file whose bytes do not match its name is refused and leaves nothing behind', () async {
    final t = await token(alice);
    final wrong = sha(utf8.encode('something else'));
    final r = await call('PUT', '/v1/blobs/$wrong', token: t, body: utf8.encode('these bytes'));
    expect(r.statusCode, 422);
    expect(blobs.has(alice.id, wrong), isFalse);
    expect(Directory('${dir.path}/${alice.id}').listSync(), isEmpty, reason: 'no .part file left');
  });

  test('a person only ever sees their own files', () async {
    final a = await token(alice);
    final b = await token(bob);
    final bytes = utf8.encode('private notes');
    await call('PUT', '/v1/blobs/${sha(bytes)}', token: a, body: bytes);
    expect((await call('GET', '/v1/blobs/${sha(bytes)}', token: b)).statusCode, 404);
    expect((await call('HEAD', '/v1/blobs/${sha(bytes)}', token: b)).statusCode, 404);
    expect(blobs.usedBytes(bob.id), 0);
  });

  test('needs a signed-in device, a proper hash, and rejects path tricks', () async {
    expect((await call('GET', '/v1/blobs/${sha([1])}')).statusCode, 401);
    final t = await token(alice);
    expect((await call('GET', '/v1/blobs/notahash', token: t)).statusCode, 400);
    expect((await call('GET', '/v1/blobs/..%2F..%2Fx', token: t)).statusCode, anyOf(400, 404));
    expect((await call('PUT', '/v1/blobs/${sha([1]).toUpperCase()}', token: t, body: [1])).statusCode, 400);
  });

  test('a file over the size limit is refused, as is one that would pass the storage quota', () async {
    final t = await token(alice);
    final big = List<int>.filled(1001, 7);
    expect((await call('PUT', '/v1/blobs/${sha(big)}', token: t, body: big)).statusCode, 413);
    for (var i = 0; i < 2; i++) {
      final b = List<int>.filled(1000, i);
      expect((await call('PUT', '/v1/blobs/${sha(b)}', token: t, body: b)).statusCode, 201);
    }
    final third = List<int>.filled(900, 9);
    expect((await call('PUT', '/v1/blobs/${sha(third)}', token: t, body: third)).statusCode, 507);
    expect(blobs.usedBytes(alice.id), 2000);
  });

  test('me reports storage use, and deleting the account removes the files', () async {
    final t = await token(alice);
    final bytes = utf8.encode('x' * 100);
    await call('PUT', '/v1/blobs/${sha(bytes)}', token: t, body: bytes);
    final me = jsonDecode(await (await call('GET', '/v1/me', token: t)).readAsString()) as Map;
    expect((me['storage'] as Map)['usedBytes'], 100);
    final del = await api(Request('POST', Uri.parse('http://x/v1/me/delete'),
        headers: {'authorization': 'Bearer $t', 'content-type': 'application/json'}, body: jsonEncode({'confirm': 'DELETE MY DATA'})));
    expect(del.statusCode, 204);
    expect(Directory('${dir.path}/${alice.id}').existsSync(), isFalse);
  });

  test('a server without file storage says so', () async {
    final bare = buildApi(store, config: const ApiConfig(trustProxy: true));
    final r = await bare(Request('POST', Uri.parse('http://x/v1/pair'),
        headers: {'content-type': 'application/json', 'x-forwarded-for': '2.2.2.2'}, body: jsonEncode({'code': store.createInvite(alice.id), 'deviceName': 'p'})));
    final t = (jsonDecode(await r.readAsString()) as Map)['token'] as String;
    final get = await bare(Request('GET', Uri.parse('http://x/v1/blobs/${sha([1])}'), headers: {'authorization': 'Bearer $t'}));
    expect(get.statusCode, 501);
  });
}
