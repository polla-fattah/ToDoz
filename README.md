# ToDoz

A personal, offline-first task manager modelled on Todoist (without AI), built with Flutter for Android and Windows.

The requirements are in the [TaskFlow 2.0 SRS](https://claude.ai/code/artifact/796e7f1d-5c0c-447b-bab0-a5e53108adae). The design and architecture principles are documented in [PHILOSOPHY.md](PHILOSOPHY.md), and the server deployment runbook is in [DEPLOYMENT.md](DEPLOYMENT.md). This repository holds **R1 (Foundation)**, **R2 (Time)**, **R3 (Views and filters)**, **R4 (Sync)**, **R5 (Productivity and integrations)** and **R6 (Sharing)**.

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

**R3 Views and filters**
- Filters: a query language like Todoist's (`(today | overdue) & #Work`, `p1 & overdue, p4 & today`, `##Home & %errands`, `due before: next monday`, `search: invoice`). Save them as views; the editor underlines mistakes and shows how many tasks match. Full syntax is in Help.
- Every project and filter can be shown as a **list, board or calendar**, grouped (section, date, priority, label, project) and sorted (manual, name, date, priority, added), with options saved per project.
- Board: drag cards between columns (this changes the section, priority, date, label or project) and reorder inside a column. Calendar: month or week, drag a task onto a day to reschedule it.
- Upcoming has a week strip; drag a task onto a day to reschedule it.
- **Calendar** (its own destination, on the phone, Windows and the web, and the Calendar layout of any project or filter), drawn like Google Calendar in light and dark (Settings, Appearance: System, Light or Dark; the web follows the system or Ctrl+K, Change theme): Today, back and forward and the month in one bar, a view picker, a blue circle for today, thin grey lines, a red "now" line, and tasks as solid blocks in Google's event colours (each project's colour becomes the nearest of Google's eleven). **Day, 3 days, Week (wide windows only, 900 px and up) and Month**. A time grid with an all-day row, a "now" line, blocks as long as the task's duration (30 minutes if none), and side-by-side layout for overlapping tasks. Tap an empty slot to add a task at that time; drag a block to another time or day, drag its bottom edge to change the duration (15-minute steps); on a touch screen press and hold a block to drag it, with a mouse just drag. In Month drag a task onto another day (its time stays). The view you last used is remembered. Web shortcuts: `d`, `3`, `w`, `m` for the views and `g` then `c` to open the Calendar. Holding a task near the top or bottom of the hours scrolls the grid by itself. A repeating task also shows, faded and with a repeat mark, on each later day in view (tap it to open the task; move the task itself to change it); repeats counted from completion (`every!`, `after`) and hourly repeats are not spread out. Not included: events from other calendars.
- Drag to move and reorder: in a list, grab the grip at the end of a task and drop it on another task (it goes before it), on a section heading (top of that section) or in the space under a section (end of it); in a board, long-press a card and drop it on a column. The list and the board scroll by themselves when you hold a task near their edge. On a wide window, drop a task on a project in the sidebar to move it there (Undo is offered). Reordering needs the Manual sort.
- Long-press tasks to select several, then complete, reschedule, change priority, move, label or delete them together.
- Search looks in titles, descriptions, comments, projects, sections and labels, understands filters, remembers recent searches, and can include completed tasks.
- Task duration; a permanent sidebar on wide windows; an in-app help page.

**R4 Sync**
- A small sync server you run yourself (`server/`, Dart + SQLite) and a pairing screen in Settings, Sync. Each person has their own account; a device joins with a one-time code and gets its own token that can be revoked.
- Edits are merged field by field (last writer wins per field), so two devices changing different things of the same task both keep their change. Deleting and restoring sync too. Device-local things (snooze, settings) do not.
- Works offline: changes queue and are sent when the server is reachable, shortly after each edit, every 30 seconds while the app is open, and when it returns to the foreground. Reset from server, unpair, sign out another device, and delete your data on the server are in the Sync screen.
- Not end-to-end encrypted: whoever runs the server can read the tasks (stated in the app).
- App lock (PIN and fingerprint), automatic backups to a folder, the Android share sheet ("Share to TaskFlow"), launcher shortcuts and an add-task / complete-task intent.
- **Syncing while the app is closed (Android):** about every 15 minutes, when there is a connection, a background job pulls what your other devices and people changed, sends what is waiting, shows the notifications for shared projects and rebuilds the reminders. Switch it off under Settings, Sync. Android decides the exact moment: battery saver, Doze and "battery optimisation" can delay it, and the shortest interval Android allows is 15 minutes, so this is not instant. The job does nothing while the app is open.
- **Windows:** `flutter build windows` works (needs Visual Studio Build Tools 2019 or newer with the "Desktop development with C++" workload, including the ATL component, and Developer Mode). Reminders work on Windows too (see Reminders below); syncing while the app is closed is Android only. `third_party/record_windows` is a one-line patch of the voice-note plugin so it builds with VS 2019 (see `third_party/README.md`).

**R5 Productivity and integrations**
- Productivity page: Karma, levels, streaks, a daily and weekly goal with days off, and charts. An activity log of everything changed, with Undo for most entries.
- Import and export: CSV in Todoist's layout, plain-text lists and ICS files; a project can be exported, or created from an import. Templates.
- Attachments (files, photos) and voice notes on comments, synced through the server and shown inline.
- Integrations: a REST API with personal tokens, signed outgoing and incoming webhooks, a calendar feed link, and a Google Calendar connection (Settings, Calendar and integrations).

**R6 Sharing**
- Share a project with other people on the same server by invitation code, with roles owner, admin, member and viewer. Everyone sees its tasks, sections and comments; your Inbox, Today and other projects stay private.
- Assign tasks (`+name` in Quick Add, "Assigned to" on the task), the filters `assigned to:`, `assigned by:` and `shared`, comment reactions, and notifications for others' comments and for tasks assigned to you (they arrive with the next sync).
- Leaving or being removed: the project goes from your phone, and tasks assigned to you become unassigned.

Quick Add syntax: `Review paper tomorrow at 4pm p1 %reading #work /backlog {nov 30} !30 min before`

**Reminders run on Android and Windows.** Android has not yet been tried on a real phone; Windows was tried on a real PC (see below).

Not yet built: location reminders, workspaces and folders, attachments in the JSON backup, and hiding buttons a read-only member cannot use (the change is refused instead). The Google Calendar connection and voice notes have not been tried on a real account or phone, and the Todoist CSV layout was written from its documentation, not checked against a real export. Known simplifications in R3: manual order inside a filter is shared with the task's project order, and the built-in Today and Upcoming views are not yet implemented as filters. See section 7 of the SRS.

**Web (online only):** the sync server also serves ToDoz for the web at `/app`, a React app: Inbox, Today, Upcoming, projects with a list and a **board** layout, labels and completed tasks; **drag and drop** to move tasks between sections, reorder them, or drop one on a project in the sidebar; Quick Add with a live preview of what it understood; a task panel that saves as you type (date picker, priority, labels, sub-tasks, comments); a command palette (Ctrl+K) and keyboard shortcuts. It needs a connection and keeps nothing in the browser except the sign-in. It is a separate client from the Flutter app (source in `server/web/`), served with a strict content-security policy. Not in the web version yet: attachments, reminders, sharing and filters.

## Layout

| Path | What it holds |
| --- | --- |
| `packages/taskflow_core/` | Pure Dart with no Flutter or database imports, shared by the app and the server: date and time parser, recurrence engine, reminder rules, Quick Add parser, filter language, view grouping and sorting, backup and 1.0 import, sync rules and clocks. |
| `server/` | The sync server, its admin commands, tests and the deployment kit (`server/deploy/`, start with `DEPLOY.md`). |
| `lib/sync/` | The app side of sync: change capture (SQL triggers), the sync engine, server client, pairing service. |
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

## Icon

The icon is the ToDoz mark (a note with a check and a pen). `tool/make_icons.py` builds every size (Android adaptive, legacy and themed icons, and the Windows `.ico`) from a transparent PNG: `python tool/make_icons.py path/to/logo.png`. Without a file it draws a stand-in mark.

## Signing

`taskflow-signing.p12` (from 1.0) is deliberately **not** in git. Keep it private; an update can only install over an existing 1.0 or 2.0 install if it is signed with the same key. The Android signing setup for release builds is still to do.

## Reminders on a real device

Scheduling, the exact-alarm permission, reboot persistence, and the Complete and Snooze buttons on a notification depend on Android and need checking on a phone. Open Settings, Reminders, and grant both permissions. On Android 12 and newer the exact-alarm permission opens a system page. The app schedules the next 48 reminders and rebuilds them whenever tasks change or the app is opened.

### Reminders on Windows

Reminders, the daily digest and the notifications for shared projects appear as Windows notifications (scheduled toasts, so Windows shows them at the right time **even when ToDoz is closed**). A reminder has **Complete** and **Snooze 10 min** buttons; clicking the toast opens the task. Windows only shows notifications for a desktop app that has a Start Menu shortcut with its app id, so ToDoz makes one called "ToDoz" the first time it runs from a place (and again if you move it). The reminders are rebuilt whenever the app runs or tasks change, so a task that arrives by sync while the app is closed gets its reminder the next time ToDoz is opened. Windows cannot repeat a notification, so the daily digest is scheduled for the next week each time. Focus assist or Do not disturb can hide the toasts. The Complete and Snooze buttons on a Windows toast have unit tests but were not clicked on a real PC.