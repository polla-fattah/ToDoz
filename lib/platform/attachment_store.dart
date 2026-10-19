import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../data/database.dart';
import '../data/repository.dart';

const _mimeByExtension = {
  'jpg': 'image/jpeg', 'jpeg': 'image/jpeg', 'png': 'image/png', 'gif': 'image/gif', 'webp': 'image/webp', 'heic': 'image/heic', 'bmp': 'image/bmp',
  'pdf': 'application/pdf', 'txt': 'text/plain', 'md': 'text/markdown', 'csv': 'text/csv', 'json': 'application/json', 'html': 'text/html',
  'doc': 'application/msword', 'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'xls': 'application/vnd.ms-excel', 'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'ppt': 'application/vnd.ms-powerpoint', 'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  'zip': 'application/zip', 'mp3': 'audio/mpeg', 'm4a': 'audio/mp4', 'aac': 'audio/aac', 'wav': 'audio/wav', 'ogg': 'audio/ogg', 'opus': 'audio/opus',
  'mp4': 'video/mp4', 'mov': 'video/quicktime', 'mkv': 'video/x-matroska', 'webm': 'video/webm', 'ics': 'text/calendar',
};

String guessMimeType(String fileName) => _mimeByExtension[p.extension(fileName).replaceFirst('.', '').toLowerCase()] ?? 'application/octet-stream';

bool isImage(Attachment a) => a.mimeType.startsWith('image/') && a.mimeType != 'image/heic';
bool isAudio(Attachment a) => a.mimeType.startsWith('audio/');

class StorageStats {
  const StorageStats({required this.files, required this.bytes, required this.localBytes, required this.orphanBytes});

  /// Live attachments and their total size, as recorded (this includes files that are still on the server only).
  final int files;
  final int bytes;

  /// Bytes actually on this device.
  final int localBytes;

  /// Bytes on this device that no attachment points to any more (what clean-up frees).
  final int orphanBytes;
}

/// Keeps attachment files on this device, named by the SHA-256 of their bytes
/// so the same file is stored once (SRS 6.2), and ties them to comments.
class AttachmentStore {
  AttachmentStore(this.repo, this.root);

  final Repo repo;
  final Directory root;

  File fileFor(String hash) => File(p.join(root.path, hash));

  bool exists(Attachment a) => fileFor(a.hash).existsSync();

  /// Copies [source] in and attaches it to a new comment on [taskId].
  Future<Attachment> attachFile(String taskId, File source, {String? fileName, String? mimeType, String? body}) =>
      attachStream(taskId, source.openRead(), fileName: fileName ?? p.basename(source.path), mimeType: mimeType, body: body);

  /// Stores the bytes of [bytes] and attaches them to a new comment on [taskId].
  /// Reading stops with a [RuleException] as soon as the file passes the size limit.
  Future<Attachment> attachStream(String taskId, Stream<List<int>> bytes, {required String fileName, String? mimeType, String? body}) async {
    final name = fileName;
    await root.create(recursive: true);
    final temp = File(p.join(root.path, '.incoming-${DateTime.now().microsecondsSinceEpoch}'));
    final (digest, length) = await _copyHashing(bytes, temp, max: maxAttachmentBytes);
    final hash = digest.toString();
    final dest = fileFor(hash);
    if (dest.existsSync()) {
      await temp.delete();
    } else {
      await temp.rename(dest.path);
    }
    final (_, id) = await repo.addAttachmentComment(
      taskId,
      fileName: name,
      mimeType: mimeType ?? guessMimeType(name),
      sizeBytes: length,
      hash: hash,
      body: body,
    );
    return (await repo.getAttachment(id))!;
  }

  /// Saves bytes that arrived from the server under [hash], checking the hash first.
  Future<bool> saveDownloaded(String hash, Stream<List<int>> bytes) async {
    await root.create(recursive: true);
    final temp = File(p.join(root.path, '.download-${DateTime.now().microsecondsSinceEpoch}'));
    try {
      final (digest, _) = await _copyHashing(bytes, temp);
      if (digest.toString() != hash) {
        await temp.delete();
        return false;
      }
      await temp.rename(fileFor(hash).path);
      return true;
    } catch (_) {
      if (temp.existsSync()) await temp.delete();
      rethrow;
    }
  }

  Future<(Digest, int)> _copyHashing(Stream<List<int>> from, File to, {int? max}) async {
    final out = AccumulatorSink<Digest>();
    final hasher = sha256.startChunkedConversion(out);
    final sink = to.openWrite();
    var total = 0;
    try {
      await for (final chunk in from) {
        total += chunk.length;
        if (max != null && total > max) throw RuleException('Files are limited to ${max ~/ (1024 * 1024)} MB');
        hasher.add(chunk);
        sink.add(chunk);
      }
      hasher.close();
      await sink.flush();
    } catch (_) {
      await sink.close();
      if (to.existsSync()) to.deleteSync();
      rethrow;
    }
    await sink.close();
    return (out.events.single, total);
  }

  Future<StorageStats> stats() async {
    final live = await repo.liveAttachments();
    final referenced = {for (final a in live) a.hash};
    var local = 0, orphan = 0;
    if (root.existsSync()) {
      for (final e in root.listSync()) {
        if (e is! File) continue;
        final name = p.basename(e.path);
        final len = e.lengthSync();
        local += len;
        if (name.startsWith('.') || !referenced.contains(name)) orphan += len;
      }
    }
    return StorageStats(files: live.length, bytes: live.fold(0, (n, a) => n + a.sizeBytes), localBytes: local, orphanBytes: orphan);
  }

  /// Deletes files on this device that no attachment uses any more (left over
  /// from deleted comments). Returns the bytes freed.
  Future<int> cleanUp() async {
    if (!root.existsSync()) return 0;
    final referenced = {for (final a in await repo.liveAttachments()) a.hash};
    var freed = 0;
    for (final e in root.listSync()) {
      if (e is! File) continue;
      final name = p.basename(e.path);
      if (referenced.contains(name)) continue;
      freed += e.lengthSync();
      try {
        e.deleteSync();
      } catch (_) {}
    }
    return freed;
  }

  /// Frees space by removing the local copy of files the server already has;
  /// they are downloaded again when opened. Returns the bytes freed.
  Future<int> offloadUploaded() async {
    var freed = 0;
    for (final a in await repo.liveAttachments()) {
      if (!a.uploaded) continue;
      final f = fileFor(a.hash);
      if (f.existsSync()) {
        freed += f.lengthSync();
        f.deleteSync();
      }
    }
    return freed;
  }
}

/// A sink that keeps what it is given (the digest of a chunked hash).
class AccumulatorSink<T> implements Sink<T> {
  final List<T> events = [];
  @override
  void add(T data) => events.add(data);
  @override
  void close() {}
}
