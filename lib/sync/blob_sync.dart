import '../data/repository.dart';
import '../platform/attachment_store.dart';
import 'sync_engine.dart';
import 'transport.dart';

class BlobReport {
  int uploaded = 0;
  int downloaded = 0;
  int failed = 0;
  String? error;
}

/// Moves attachment files between this device and the server. The metadata
/// travels with normal sync; the bytes travel here, once per file.
class BlobSync {
  BlobSync(this.repo, this.store);

  final Repo repo;
  final AttachmentStore store;

  /// Sends files the server lacks and fetches files this device lacks. At
  /// most [limit] of each per run, so a big backlog never blocks a sync.
  Future<BlobReport> run(ServerApi api, {int limit = 20}) async {
    final report = BlobReport();
    var uploads = 0;
    for (final a in await repo.attachmentsToUpload()) {
      if (uploads >= limit) break;
      final file = store.fileFor(a.hash);
      if (!file.existsSync()) continue; // not downloaded here yet
      try {
        if (!await api.hasBlob(a.hash)) {
          await api.putBlob(a.hash, file.openRead(), file.lengthSync());
          report.uploaded++;
        }
        await repo.markUploaded(a.id);
        uploads++;
      } on SyncTransportException catch (e) {
        if (e.unauthorized) rethrow;
        report.failed++;
        report.error = e.message;
      }
    }
    var downloads = 0;
    for (final a in await repo.liveAttachments()) {
      if (downloads >= limit) break;
      if (store.exists(a)) continue;
      try {
        final stream = await api.getBlob(a.hash);
        if (stream == null) continue;
        if (await store.saveDownloaded(a.hash, stream)) {
          report.downloaded++;
        } else {
          report.failed++;
          report.error = 'A file from the server did not match its checksum and was discarded';
        }
        downloads++;
      } on SyncTransportException catch (e) {
        if (e.unauthorized) rethrow;
        report.failed++;
        report.error = e.message;
      }
    }
    return report;
  }

  /// Fetches one file now (the person tapped it). Returns false if the server does not have it.
  Future<bool> fetch(ServerApi api, String hash) async {
    final stream = await api.getBlob(hash);
    if (stream == null) return false;
    return store.saveDownloaded(hash, stream);
  }
}
