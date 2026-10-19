import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:taskflow_server/server.dart';

Future<void> main(List<String> args) async {
  try {
    final code = await buildRunner().run(args) ?? 0;
    await stdout.flush();
    exit(code);
  } on UsageException catch (e) {
    stderr.writeln(e);
    exit(64);
  }
}
