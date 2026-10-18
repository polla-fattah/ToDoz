# TaskFlow 1.0

Independent, Todoist-inspired offline Android task manager. This is an installable first version, not the Todoist product or its service. It uses a native Android host with a bundled HTML/CSS/JavaScript interface, rather than Flutter. No server, login, internet connection, or third-party account is required.

## Install

Open TaskFlow.apk on an Android 8.0 or newer phone, allow installation from the app opening the file if Android asks, then install. Use an up-to-date Android System WebView. The app is signed with its own personal build certificate; it is not a Play Store release.

## Included

- Inbox, Today (including overdue), Upcoming, all tasks, and completed archive.
- Custom projects, project colors, and editable project sections.
- Add, edit, complete, reopen, and delete tasks; undo task deletion and completion.
- Descriptions, due dates, four priority levels, labels, subtasks, and dated comments.
- List and board views; sort by priority, due date, or title.
- Text search and simple filters: p1–p4, @label, #project, today view, overdue search.
- Quick entry for today, tomorrow, next week, p1–p4, @label, and #project-id. For example: Review paper tomorrow p1 @reading #work. A manually changed date takes precedence over quick-entry date parsing.
- Light and dark themes, daily completion goal, completion totals.
- Native Android file picker for exporting and restoring JSON backups.
- Durable private device storage; no internet permission, analytics, or ads.

Board view groups tasks by section within a project and by priority elsewhere. Change a task's section or priority in its editor; drag and drop is not included. Deleting a project moves its tasks to Inbox. Subtasks do not automatically complete their parent. Daily totals count currently completed tasks completed on that local calendar day.

## Limitations

This version does not include notification reminders, recurring tasks, cloud synchronization, shared projects, team permissions, attachments, calendar integration, or a full natural-language parser. Export backups before uninstalling, clearing app storage, or changing phones. Restoring a backup replaces current data after a confirmation screen; invalid backups are rejected.

## Build

Requirements: JDK 17, Android SDK platform 35, build-tools 35.0.0, bash, zip.

```sh
export ANDROID_SDK_ROOT=/absolute/path/to/android-sdk
./build.sh
```

The build creates `TaskFlow.apk`. Retain `taskflow-signing.p12` to sign future updates that can install over this version without uninstalling. The local signing password is `taskflow-local-build`, alias `taskflow`. This keystore is for your personal build, and is included so you can maintain the app.

There are no downloaded runtime dependencies. The build uses javac, d8, aapt, zipalign, and apksigner directly. Increase versionCode in the manifest for later releases.

## Validation

- APK compiled targeting API 35 with minimum API 26.
- APK signature schemes v2 and v3 verified successfully.
- Browser-based tests passed: creation, quick-entry parsing, reload persistence, completion/reopening, projects/sections, board view, search, invalid-backup rejection, valid restore, project deletion/task preservation, deletion undo, text escaping, and mobile viewport overflow.
- Light-mode list and dark-mode editor inspected at a 412 px viewport.
- Native Android launch, system file picker, lifecycle, keyboard/insets, and phone compatibility have not been tested on an emulator or physical device.

Optional browser smoke test, from this directory with Playwright installed:

```sh
mkdir -p build
node tests/smoke.cjs
# Or: CHROME_PATH=/absolute/path/to/chrome node tests/smoke.cjs
```
