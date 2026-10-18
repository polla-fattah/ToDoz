# TaskFlow 2.0

A personal, offline-first task manager modelled on Todoist (without AI), built with Flutter for Android and Windows.

The requirements are in the [TaskFlow 2.0 SRS](https://claude.ai/code/artifact/796e7f1d-5c0c-447b-bab0-a5e53108adae). This repository holds **R1 (Foundation)** and **R2 (Time)**; the old 1.0 app is kept in `legacy-v1/` for reference.

## What it has so far

**R1 Foundation**
- Inbox, Today (with overdue and a daily goal), Upcoming, Browse; search over open tasks.
- Projects nested up to 3 levels, favorites, archive, duplicate, colors, notes; sections; labels (create, rename, merge, delete).
- Real sub-tasks nested up to 4 levels, with collapse, "complete sub-tasks too?" and "complete the parent too?" prompts.
- Quick Add with live highlighting; unknown projects and labels are offered for creation.
- Comments, descriptions, priorities p1-p4, trash with 30-day recovery, Undo on every destructive action.
- JSON backup export and restore (with a safety copy first). Restore also accepts **TaskFlow 1.0 backups**.

**R2 Time**
- Due times, and overdue only once the time has passed.
- Recurring tasks: `every day`, `every other week`, `every mon, fri at 8pm`, `every 2, 15, 27`, `every 1st wed`, `every last workday`, `every 12 hours starting at 9pm`, bounds (`until`, `for 3 weeks`, `starting`), and completion-based `every! 2 months` / `after 10 days`. Unsupported phrases are refused with a reason instead of guessed.
- Completing a repeating task moves it to its next date; Skip, Stop repeating, and exact Undo.
- Deadlines (`{march 30}`), custom reminders (`!30 min before`, `!14:00`), an automatic reminder, snooze, and a daily digest.
- Duplicate a task; every completion is logged.
- Settings: 24-hour clock, week start, reminder options.

Quick Add syntax: `Review paper tomorrow at 4pm p1 %reading #work /backlog {nov 30} !30 min before`

**Reminders run on Android only for now** and have not yet been tried on a real phone (see below).

Not yet built: filters, board and calendar views, drag and drop, sync, Karma and charts, attachments, widgets, Windows notifications. See section 7 of the SRS.

## Layout

| Path | What it holds |
| --- | --- |
| `lib/core/` | Pure Dart with no Flutter or database imports: date and time parser, recurrence engine, reminder rules, Quick Add parser, backup and 1.0 import. Shared with the server later. |
| `lib/platform/` | Operating-system glue: Android notification scheduling. |
| `lib/data/` | Drift (SQLite) tables and the `Repo` class that holds every rule. |
| `lib/ui/` | Screens and widgets. |
| `test/` | Unit tests for the core and repository, plus widget tests. |
| `legacy-v1/` | TaskFlow 1.0 (WebView app), unchanged. |

## Working on it

Use the Flutter SDK's own `dart`; an older standalone `dart` on `PATH` cannot resolve this project.

```sh
flutter pub get
flutter test
flutter analyze
flutter run -d windows        # or an Android device
flutter build apk --release
```

After changing a table in `lib/data/database.dart`, regenerate the Drift code:

```sh
C:\tools\flutter\bin\dart run build_runner build
```

Windows builds and plugins need **Developer Mode** (Settings, System, For developers) so Flutter can create symbolic links.

## Signing

`taskflow-signing.p12` (from 1.0) is deliberately **not** in git. Keep it private; an update can only install over an existing 1.0 or 2.0 install if it is signed with the same key. The Android signing setup for release builds is still to do.

## Reminders on a real device

Scheduling, the exact-alarm permission, reboot persistence, and the Complete and Snooze buttons on a notification depend on Android and need checking on a phone. Open Settings, Reminders, and grant both permissions. On Android 12 and newer the exact-alarm permission opens a system page. The app schedules the next 48 reminders and rebuilds them whenever tasks change or the app is opened.
