import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../data/database.dart';
import '../data/repository.dart';
import '../platform/attachment_store.dart';
import 'catalog.dart';
import 'common.dart';

String formatBytes(int n) {
  if (n < 1024) return '$n B';
  if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(n < 10 * 1024 ? 1 : 0)} KB';
  if (n < 1024 * 1024 * 1024) return '${(n / (1024 * 1024)).toStringAsFixed(n < 10 * 1024 * 1024 ? 1 : 0)} MB';
  return '${(n / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
}

/// Opens an attachment: images are shown larger in the app; other files go to
/// the Android app that handles them (FR-C4). A file that is only on the
/// server is downloaded first.
Future<void> openAttachment(BuildContext context, Attachment a) async {
  final catalog = AppScope.of(context);
  final store = catalog.attachments;
  if (store == null) return;
  if (!store.exists(a)) {
    final sync = catalog.sync;
    showMessage(context, 'Downloading…');
    bool ok = false;
    try {
      ok = await sync?.fetchAttachment(a.hash) ?? false;
    } catch (_) {}
    if (!context.mounted) return;
    if (!ok) {
      showMessage(context, 'This file is not on this device yet, and the server could not give it. Try again after the next sync.');
      return;
    }
  }
  if (!context.mounted) return;
  if (isImage(a)) {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => _ImageViewer(attachment: a, file: store.fileFor(a.hash))));
    return;
  }
  final result = await OpenFilex.open(store.fileFor(a.hash).path, type: a.mimeType);
  if (result.type != ResultType.done && context.mounted) {
    showMessage(context, 'No app on this device can open ${a.fileName}.');
  }
}

class _ImageViewer extends StatelessWidget {
  const _ImageViewer({required this.attachment, required this.file});
  final Attachment attachment;
  final File file;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(attachment.fileName, overflow: TextOverflow.ellipsis)),
        body: InteractiveViewer(
          child: Center(child: Image.file(file, errorBuilder: (_, _, _) => const Text('This image cannot be shown.'))),
        ),
      );
}

/// The files of one comment: a small preview for images, a chip for the rest.
class CommentAttachments extends StatelessWidget {
  const CommentAttachments({super.key, required this.attachments});
  final List<Attachment> attachments;

  @override
  Widget build(BuildContext context) {
    final store = AppScope.of(context).attachments;
    if (attachments.isEmpty || store == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Wrap(spacing: 8, runSpacing: 8, children: [
        for (final a in attachments)
          if (isImage(a) && store.exists(a))
            InkWell(
              onTap: () => openAttachment(context, a),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.file(store.fileFor(a.hash), width: 96, height: 96, fit: BoxFit.cover, cacheWidth: 192, errorBuilder: (_, _, _) => const SizedBox(width: 96, height: 96, child: Icon(Icons.broken_image_outlined))),
              ),
            )
          else
            ActionChip(
              avatar: Icon(isAudio(a) ? Icons.mic_none : (isImage(a) ? Icons.image_outlined : Icons.attach_file), size: 18),
              label: Text('${a.fileName} · ${formatBytes(a.sizeBytes)}${store.exists(a) ? '' : ' · on server'}'),
              onPressed: () => openAttachment(context, a),
            ),
      ]),
    );
  }
}

/// Chooses files and attaches each to a new comment on [taskId].
Future<void> pickAndAttach(BuildContext context, String taskId) async {
  final store = AppScope.of(context).attachments;
  if (store == null) return;
  try {
    final picked = await FilePicker.pickFiles(dialogTitle: 'Attach files');
    if (picked.isEmpty) return;
    var done = 0;
    for (final f in picked) {
      try {
        await store.attachStream(taskId, f.readAsByteStream(), fileName: f.name);
        done++;
      } on RuleException catch (e) {
        if (context.mounted) showMessage(context, '${f.name}: ${e.message}');
      }
    }
    if (context.mounted && done > 0) showMessage(context, done == 1 ? 'File attached' : '$done files attached');
  } catch (_) {
    if (context.mounted) showMessage(context, 'Could not attach the file.');
  }
}

/// Records a voice note and attaches it as a comment (FR-C3).
class VoiceNoteButton extends StatefulWidget {
  const VoiceNoteButton({super.key, required this.taskId});
  final String taskId;

  @override
  State<VoiceNoteButton> createState() => _VoiceNoteButtonState();
}

class _VoiceNoteButtonState extends State<VoiceNoteButton> {
  AudioRecorder? _recorder; // made on first use, so a screen that never records loads no plugin
  bool _recording = false;
  Duration _elapsed = Duration.zero;
  Timer? _ticker;
  String? _path;

  @override
  void dispose() {
    _ticker?.cancel();
    _recorder?.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final recorder = _recorder ??= AudioRecorder();
      if (!await recorder.hasPermission()) {
        if (mounted) showMessage(context, 'Allow the microphone to record a voice note.');
        return;
      }
      final dir = await getTemporaryDirectory();
      _path = p.join(dir.path, 'voice-${DateTime.now().millisecondsSinceEpoch}.m4a');
      await recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 64000, sampleRate: 22050, numChannels: 1), path: _path!);
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) => setState(() => _elapsed += const Duration(seconds: 1)));
      setState(() {
        _recording = true;
        _elapsed = Duration.zero;
      });
    } catch (_) {
      if (mounted) showMessage(context, 'Could not start recording.');
    }
  }

  Future<void> _stop({required bool keep}) async {
    _ticker?.cancel();
    final repoStore = AppScope.of(context).attachments;
    String? path;
    try {
      path = await _recorder?.stop();
    } catch (_) {}
    setState(() => _recording = false);
    path ??= _path;
    if (path == null) return;
    final file = File(path);
    if (!keep || !file.existsSync() || repoStore == null) {
      if (file.existsSync()) await file.delete();
      return;
    }
    final now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final name = 'Voice note ${now.year}-${two(now.month)}-${two(now.day)} ${two(now.hour)}-${two(now.minute)}.m4a';
    try {
      await repoStore.attachFile(widget.taskId, file, fileName: name, mimeType: 'audio/mp4', body: 'Voice note');
      if (mounted) showMessage(context, 'Voice note added');
    } catch (_) {
      if (mounted) showMessage(context, 'Could not save the voice note.');
    } finally {
      if (file.existsSync()) await file.delete();
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_recording) return IconButton(icon: const Icon(Icons.mic_none), tooltip: 'Record a voice note', onPressed: _start);
    final mm = _elapsed.inMinutes.toString().padLeft(2, '0');
    final ss = (_elapsed.inSeconds % 60).toString().padLeft(2, '0');
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.fiber_manual_record, color: Theme.of(context).colorScheme.error, size: 14),
      const SizedBox(width: 4),
      Text('$mm:$ss'),
      IconButton(icon: const Icon(Icons.close), tooltip: 'Discard recording', onPressed: () => _stop(keep: false)),
      IconButton(icon: const Icon(Icons.stop_circle_outlined), tooltip: 'Stop and attach', onPressed: () => _stop(keep: true)),
    ]);
  }
}
