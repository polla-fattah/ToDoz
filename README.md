# TaskFlow 2.0

A personal, offline-first task manager modelled on Todoist (without AI), built with Flutter for Android and Windows.

The requirements are in the [TaskFlow 2.0 SRS](https://claude.ai/code/artifact/796e7f1d-5c0c-447b-bab0-a5e53108adae). This repository is **release R1 (Foundation)** in progress; the old 1.0 app is kept in `legacy-v1/` for reference.

## What R1 has so far

- Inbox, Today (with overdue and a daily goal), Upcoming, Browse; search over open tasks.
- Projects nested up to 3 levels, favorites, archive, duplicate, colors; sections; labels (create, rename, merge, delete).
- Real sub-tasks nested up to 4 levels, with collapse, "complete sub-tasks too?" and "complete the parent too?" prompts.
- Quick Add: type `Review paper tomorrow p1 %reading #work /backlog`; recognised words are highlighted as you type; unknown projects and labels are offered for creation.
- Comments, descriptions, priorities p1-p4, due dates, trash with 30-day recovery, Undo on every destructive action.
- JSON backup export and restore (with a safety copy first). Restore also accepts **TaskFlow 1.0 backups**.

Not yet built (later releases): times of day, recurring dates, reminders, filters, board and calendar views, sync, Karma and charts. See section 7 of the SRS.

## Layout

| Path | What it holds |
| --- | --- |
| `lib/core/` | Pure Dart with no Flutter or database imports: date parser, Quick Add parser, backup and 1.0 import. Shared with the server later. |
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
