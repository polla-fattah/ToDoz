import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:taskflow/platform/notification_service.dart';
import 'package:taskflow/platform/windows_shortcut.dart';

/// Windows reminders: the Start Menu shortcut Windows needs before it shows notifications, and the buttons on a toast.
void main() {
  late Directory dir;
  late File lnk;
  late File marker;
  var runs = 0;
  var runnerWorks = true;

  WindowsShortcut shortcut() => WindowsShortcut(
        appId: 'Taskflow.NoteDo.App',
        activatorGuid: 'b8f5f1a2-6d3c-4f6e-9a0b-4c2e7d1a9e35',
        run: (script) async {
          runs++;
          if (runnerWorks) lnk.writeAsStringSync('shortcut'); // what the real script does
          return runnerWorks;
        },
      );

  setUp(() {
    dir = Directory.systemTemp.createTempSync('noteDo_shortcut');
    lnk = File('${dir.path}/Programs/NoteDo.lnk');
    marker = File('${dir.path}/NoteDo/target.txt');
    runs = 0;
    runnerWorks = true;
  });

  tearDown(() => dir.deleteSync(recursive: true));

  group('the Start Menu shortcut', () {
    test('is made the first time, and remembers which program it was made for', () async {
      expect(await shortcut().ensure(target: r'C:\Apps\NoteDo\taskflow.exe', lnk: lnk, marker: marker), isTrue);
      expect(runs, 1);
      expect(lnk.existsSync(), isTrue);
      expect(marker.readAsStringSync(), r'C:\Apps\NoteDo\taskflow.exe');
    });

    test('is left alone when it is already there for the same program', () async {
      await shortcut().ensure(target: r'C:\Apps\NoteDo\taskflow.exe', lnk: lnk, marker: marker);
      expect(await shortcut().ensure(target: r'C:\Apps\NoteDo\taskflow.exe', lnk: lnk, marker: marker), isTrue);
      expect(runs, 1, reason: 'no second PowerShell run on every start');
    });

    test('is made again when the app runs from another place, or the shortcut was deleted', () async {
      await shortcut().ensure(target: r'C:\Apps\NoteDo\taskflow.exe', lnk: lnk, marker: marker);
      await shortcut().ensure(target: r'D:\Portable\taskflow.exe', lnk: lnk, marker: marker);
      expect(runs, 2);
      expect(marker.readAsStringSync(), r'D:\Portable\taskflow.exe');
      lnk.deleteSync();
      await shortcut().ensure(target: r'D:\Portable\taskflow.exe', lnk: lnk, marker: marker);
      expect(runs, 3);
    });

    test('a failure is reported (false), not thrown, and nothing is remembered', () async {
      runnerWorks = false;
      expect(await shortcut().ensure(target: r'C:\Apps\NoteDo\taskflow.exe', lnk: lnk, marker: marker), isFalse);
      expect(marker.existsSync(), isFalse, reason: 'so the next start tries again');
    });

    test('the script carries the app id, the activator, and paths with apostrophes safely', () {
      final s = shortcut().script(target: r"C:\Users\O'Neil\NoteDo\taskflow.exe", lnk: r'C:\Menu\NoteDo.lnk');
      expect(s, contains(r"$Target = 'C:\Users\O''Neil\NoteDo\taskflow.exe'"));
      expect(s, contains(r"$Aumid = 'Taskflow.NoteDo.App'"));
      expect(s, contains(r"$Clsid = 'b8f5f1a2-6d3c-4f6e-9a0b-4c2e7d1a9e35'"));
      expect(s, contains('StartMenuShortcut'));
    });
  });

  group('the buttons on a Windows toast', () {
    test('Complete and Snooze come back as "action:task id"', () {
      final c = ToastAction.parse('complete:7f09ec35-f0d4-4715-80b0-898cd6141889')!;
      expect((c.kind, c.taskId), ('complete', '7f09ec35-f0d4-4715-80b0-898cd6141889'));
      final s = ToastAction.parse('snooze10:abc')!;
      expect((s.kind, s.taskId), ('snooze10', 'abc'));
    });

    test('a plain tap hands back just the task id, which is not an action', () {
      expect(ToastAction.parse('7f09ec35-f0d4-4715-80b0-898cd6141889'), isNull);
      expect(ToastAction.parse(''), isNull);
      expect(ToastAction.parse('complete:'), isNull);
      expect(ToastAction.parse('delete:abc'), isNull, reason: 'only the buttons NoteDo puts on a toast');
    });
  });
}
