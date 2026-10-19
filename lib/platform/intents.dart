import 'dart:io';

import 'package:flutter/services.dart';

/// A file another app shared with NoteDo, already copied into the app's cache.
class SharedFile {
  const SharedFile({required this.path, required this.name, required this.mime});
  final String path;
  final String name;
  final String mime;
}

/// What Android asked NoteDo to do (see MainActivity.kt): handle shared
/// content, a launcher shortcut, or a command from another app.
class IntentMessage {
  const IntentMessage(this.type, {this.text, this.subject, this.silent = false, this.files = const [], this.unreadable = 0});

  /// `share`, `add`, `complete`, `open` (a task, by id in [text]), `today` or `search`.
  final String type;
  final String? text;
  final String? subject;

  /// For `add`: create the task without showing the Quick Add sheet.
  final bool silent;
  final List<SharedFile> files;

  /// How many shared files could not be read (too big, or the other app withdrew them).
  final int unreadable;

  factory IntentMessage.fromMap(Map<Object?, Object?> m) => IntentMessage(
        (m['type'] as String?) ?? 'unknown',
        text: (m['text'] as String?)?.trim().isEmpty ?? true ? null : (m['text'] as String).trim(),
        subject: (m['subject'] as String?)?.trim().isEmpty ?? true ? null : (m['subject'] as String).trim(),
        silent: m['silent'] == true,
        unreadable: (m['unreadable'] as int?) ?? 0,
        files: [
          for (final f in (m['files'] as List<Object?>? ?? const []))
            if (f is Map && f['path'] is String)
              SharedFile(path: f['path'] as String, name: (f['name'] as String?) ?? 'file', mime: (f['mime'] as String?) ?? ''),
        ],
      );
}

/// Listens for Android intents. On other platforms it does nothing.
class AndroidIntents {
  static const _channel = MethodChannel('taskflow/intents');

  /// Calls [onMessage] for the intent that started the app (if any) and for every later one.
  static Future<void> listen(void Function(IntentMessage) onMessage) async {
    if (!Platform.isAndroid) return;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'intent' && call.arguments is Map) onMessage(IntentMessage.fromMap(call.arguments as Map));
    });
    try {
      final initial = await _channel.invokeMethod<Object?>('initial');
      if (initial is Map) onMessage(IntentMessage.fromMap(initial));
    } on MissingPluginException {
      // Running without the Android host (tests): nothing to do.
    }
  }
}
