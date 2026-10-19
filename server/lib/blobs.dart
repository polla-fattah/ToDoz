/// Attachment files, stored by their SHA-256 so the same file is kept once
/// per person. Each person has their own folder; one person can never name
/// another's (the folder comes from the authenticated user, SEC-5).
library;

import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

class BlobTooLarge implements Exception {
  BlobTooLarge(this.limit);
  final int limit;
}

class BlobQuotaExceeded implements Exception {}

class BlobHashMismatch implements Exception {}

final _hashPattern = RegExp(r'^[0-9a-f]{64}$');

bool isBlobHash(String s) => _hashPattern.hasMatch(s);

class BlobStore {
  BlobStore(this.root, {this.maxBytes = 100 * 1024 * 1024, this.quotaBytes = 5 * 1024 * 1024 * 1024});

  final Directory root;

  /// The largest single file (FR-C2: 100 MB).
  final int maxBytes;

  /// Everything one person may store.
  final int quotaBytes;

  Directory _dir(String userId) => Directory('${root.path}${Platform.pathSeparator}$userId');

  File _file(String userId, String hash) => File('${_dir(userId).path}${Platform.pathSeparator}$hash');

  bool has(String userId, String hash) => isBlobHash(hash) && _file(userId, hash).existsSync();

  int? size(String userId, String hash) => has(userId, hash) ? _file(userId, hash).lengthSync() : null;

  /// The file, or null if this person has no such blob.
  File? open(String userId, String hash) => has(userId, hash) ? _file(userId, hash) : null;

  int usedBytes(String userId) {
    final d = _dir(userId);
    if (!d.existsSync()) return 0;
    var n = 0;
    for (final e in d.listSync()) {
      if (e is File && !e.path.endsWith('.part')) n += e.lengthSync();
    }
    return n;
  }

  /// Stores [data] if its SHA-256 is [hash]. The bytes go to a temporary file
  /// first, so a dropped connection or a wrong hash never leaves a bad blob.
  Future<int> put(String userId, String hash, Stream<List<int>> data) async {
    if (!isBlobHash(hash)) throw ArgumentError('Bad hash');
    final existing = size(userId, hash);
    if (existing != null) {
      await data.drain<void>();
      return existing;
    }
    final dir = _dir(userId)..createSync(recursive: true);
    final temp = File('${dir.path}${Platform.pathSeparator}$hash.${DateTime.now().microsecondsSinceEpoch}.part');
    final sink = temp.openWrite();
    final digest = _Digest();
    final hasher = sha256.startChunkedConversion(digest);
    var total = 0;
    final used = usedBytes(userId);
    try {
      await for (final chunk in data) {
        total += chunk.length;
        if (total > maxBytes) throw BlobTooLarge(maxBytes);
        if (used + total > quotaBytes) throw BlobQuotaExceeded();
        hasher.add(chunk);
        sink.add(chunk);
      }
      hasher.close();
      await sink.flush();
      await sink.close();
      if (digest.value.toString() != hash) throw BlobHashMismatch();
      await temp.rename(_file(userId, hash).path);
      return total;
    } catch (_) {
      try {
        await sink.close();
      } catch (_) {}
      if (temp.existsSync()) temp.deleteSync();
      rethrow;
    }
  }

  void deleteUser(String userId) {
    final d = _dir(userId);
    if (d.existsSync()) d.deleteSync(recursive: true);
  }
}

class _Digest implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
