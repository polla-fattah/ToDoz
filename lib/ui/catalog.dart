import 'dart:async';

import 'package:flutter/material.dart';

import 'package:taskflow_core/time_grid.dart' show CalendarMode;
import 'package:taskflow_core/backup.dart' show inboxId;
import 'package:taskflow_core/date_parser.dart' show dateOnly, formatDate, parseClock;
import 'package:taskflow_core/progress.dart' show Goals;
import 'package:taskflow_core/sharing.dart';
import 'package:taskflow_core/filter.dart';
import 'package:taskflow_core/view_options.dart';
import '../data/database.dart';
import '../data/repository.dart';
import '../platform/attachment_store.dart';
import '../platform/auto_backup.dart';
import '../security/app_lock.dart';
import '../sync/sync_service.dart';
import 'notification_controls.dart';

/// Live copies of the small tables (projects, sections, labels, label links)
/// that every screen needs to show names and colors. One subscription each,
/// shared by the whole app.
class Catalog extends ChangeNotifier {
  Catalog(this.repo) {
    _subs = [
      repo.watchProjects().listen((v) => _set(() => projects = v)),
      repo.watchAllSections().listen((v) => _set(() => sections = v)),
      repo.watchLabels().listen((v) => _set(() => labels = v)),
      repo.watchLabelLinks().listen((v) => _set(() => links = v)),
      repo.watchSubtaskCounts().listen((v) => _set(() => subtaskCounts = v)),
      repo.watchFilters().listen((v) => _set(() => filters = v)),
      repo.watchSetting('themeMode').listen((v) => _set(() => themeMode = switch (v) {
            'dark' => ThemeMode.dark,
            'light' => ThemeMode.light,
            _ => ThemeMode.system,
          })),
      repo.watchSetting('dailyGoal').listen((v) => _set(() => dailyGoal = (int.tryParse(v ?? '') ?? 5).clamp(0, 100))),
      repo.watchSetting('weeklyGoal').listen((v) => _set(() => weeklyGoal = (int.tryParse(v ?? '') ?? 30).clamp(0, 700))),
      repo.watchSetting('daysOff').listen((v) => _set(() => daysOff = {
            for (final s in (v ?? '').split(','))
              if (int.tryParse(s) != null && int.parse(s) >= 1 && int.parse(s) <= 7) int.parse(s),
          })),
      repo.watchSetting('vacations').listen((v) => _set(() => vacations = Goals.parseVacations(v))),
      repo.watchSetting('karma.enabled').listen((v) => _set(() => karmaEnabled = v != 'false')),
      repo.watchSetting('karma.celebrate').listen((v) => _set(() => celebrate = v != 'false')),
      repo.watchCompletedOn(repo.now).listen(_doneTodayChanged),
      repo.watchSharedProjects().listen((v) => _set(() => shared = v)),
      repo.watchSetting('sync.userid').listen((v) => _set(() {
            me = v;
            repo.me = v;
          })),
      repo.watchSetting('use24h').listen((v) => _set(() => use24h = v != 'false')),
      repo.watchSetting('weekStart').listen((v) => _set(() => weekStart = (int.tryParse(v ?? '') ?? 1).clamp(1, 7))),
      repo.watchSetting('calendarMode').listen((v) => _set(() => calendarMode = CalendarMode.values.where((m) => m.name == v).firstOrNull ?? CalendarMode.threeDays)),
      repo.watchSetting('autoReminder').listen((v) => _set(() => autoReminderMinutes = v == 'off' ? null : (int.tryParse(v ?? '') ?? 30))),
      repo.watchSetting('digestTime').listen((v) => _set(() => digestMinutes = v == null || v == 'off' ? null : parseClock(v))),
    ];
  }

  final Repo repo;

  /// Set by the app on platforms that support reminders; null otherwise.
  NotificationControls? notifications;

  /// Pairing and background sync; null in tests that do not need it.
  SyncService? sync;

  /// The PIN and biometric lock; null in tests that do not need it.
  AppLock? lock;

  /// Daily automatic backups; null in tests that do not need it.
  AutoBackup? autoBackup;

  /// Attachment files on this device; null in tests that do not need it.
  AttachmentStore? attachments;

  /// A screen another part of the app (a shortcut) wants shown: `today`, ... The home screen reacts and clears it.
  final ValueNotifier<String?> navRequest = ValueNotifier(null);
  late final List<StreamSubscription<Object?>> _subs;
  bool _disposed = false;

  List<Project> projects = const [];
  List<Section> sections = const [];
  List<Label> labels = const [];
  List<TaskLabel> links = const [];
  Map<String, (int, int)> subtaskCounts = const {};
  List<Filter> filters = const [];
  ThemeMode themeMode = ThemeMode.system;
  int dailyGoal = 5;
  int weeklyGoal = 30;

  /// Weekdays (1 = Monday) that never break a streak, and vacation periods (FR-K2).
  Set<int> daysOff = const {};
  List<(String, String?)> vacations = const [];

  /// Karma, streaks and the goal bar can be switched off entirely (FR-K10).
  bool karmaEnabled = true;
  bool celebrate = true;

  /// This person's id on the sync server (null if not signed in), and the projects they share.
  String? me;
  List<SharedProject> shared = const [];

  SharedProject? sharedOf(String projectId) {
    for (final s in shared) {
      if (s.projectId == projectId) return s;
    }
    return null;
  }

  bool isShared(String projectId) => sharedOf(projectId) != null;

  /// My role in a shared project; null for one that is not shared.
  ShareRole? roleOf(String projectId) => sharedOf(projectId)?.role;

  /// Whether I may add and change tasks in the project (everything outside sharing is mine to change).
  bool canEdit(String projectId) => roleOf(projectId)?.canEditTasks ?? true;

  /// Everyone I share a project with, by user id (and myself).
  Map<String, String> get memberNames => {
        for (final s in shared)
          for (final m in s.members) m.userId: m.name,
      };

  /// How to show a person: "You" for me, else their name.
  String displayName(String? userId) {
    if (userId == null) return '';
    if (userId == me) return 'You';
    return memberNames[userId] ?? 'Someone';
  }

  /// Counts up each time the daily goal is reached, so the celebration can react.
  int celebrations = 0;
  int? _doneToday;
  String? _celebratedOn;

  bool get onVacation => vacations.any((r) => r.$2 == null);

  Goals get goals => Goals(daily: dailyGoal, weekly: weeklyGoal, daysOff: daysOff, vacations: vacations, weekStart: weekStart);

  void _doneTodayChanged(int n) {
    final before = _doneToday;
    _doneToday = n;
    final today = formatDate(dateOnly(repo.now));
    if (before != null && dailyGoal > 0 && before < dailyGoal && n >= dailyGoal && karmaEnabled && celebrate && _celebratedOn != today) {
      _celebratedOn = today;
      _set(() => celebrations++);
    }
  }

  /// 24-hour clock (FR-D5). The first day of the week, 1 = Monday ... 7 = Sunday.
  bool use24h = true;
  int weekStart = 1;

  /// The Calendar view last used (Day, 3 days, Week on wide windows, Month).
  CalendarMode calendarMode = CalendarMode.threeDays;

  Future<void> setCalendarMode(CalendarMode mode) => repo.setSetting('calendarMode', mode.name);

  /// Minutes before a due time for the automatic reminder; null = off (FR-N1).
  int? autoReminderMinutes = 30;

  /// Time of the daily digest notification in minutes after midnight; null = off (FR-N6).
  int? digestMinutes;

  void _set(void Function() f) {
    if (_disposed) return;
    f();
    notifyListeners();
  }

  Project? project(String id) {
    for (final p in projects) {
      if (p.id == id) return p;
    }
    return null;
  }

  Project get inbox => project(inboxId) ?? projects.first;

  Section? section(String? id) {
    if (id == null) return null;
    for (final s in sections) {
      if (s.id == id) return s;
    }
    return null;
  }

  List<Section> sectionsOf(String projectId) =>
      sections.where((s) => s.projectId == projectId && !s.isArchived).toList();

  Label? label(String id) {
    for (final l in labels) {
      if (l.id == id) return l;
    }
    return null;
  }

  List<Label> labelsFor(String taskId) => [
        for (final l in links.where((l) => l.taskId == taskId))
          if (label(l.labelId) != null) label(l.labelId)!,
      ];

  Filter? filter(String id) {
    for (final f in filters) {
      if (f.id == id) return f;
    }
    return null;
  }

  /// The names a filter query can refer to, with today's date.
  FilterEnv get filterEnv => FilterEnv(
        now: repo.now,
        weekStart: weekStart,
        projects: [for (final p in projects) FilterProject(p.id, p.name, parentId: p.parentId)],
        sections: [for (final s in sections) FilterSectionInfo(s.id, s.projectId, s.name)],
        currentUserId: me,
        memberNames: memberNames,
        sharedProjectIds: {for (final s in shared) s.projectId},
      );

  FilterTask filterTask(Task t) => FilterTask(
        id: t.id, title: t.title, description: t.description, projectId: t.projectId,
        sectionId: t.sectionId, parentId: t.parentId, priority: t.priority, dueDate: t.dueDate,
        dueTime: t.dueTime, recurrence: t.recurrence, deadline: t.deadline,
        labels: [for (final l in labelsFor(t.id)) l.name.toLowerCase()],
        createdAt: t.createdAt, assigneeId: t.assigneeId, assignedById: t.assignedBy,
      );

  TaskFacts facts(Task t) => TaskFacts(
        id: t.id, title: t.title, projectId: t.projectId, sectionId: t.sectionId, priority: t.priority,
        dueDate: t.dueDate, dueTime: t.dueTime,
        labelIds: [for (final l in links) if (l.taskId == t.id) l.labelId],
        createdAt: t.createdAt, sortOrder: t.sortOrder,
      );

  /// Projects (Inbox first, then tree order), sections and labels in display order.
  GroupLookups get lookups => GroupLookups(
        projects: [
          (id: inboxId, name: 'Inbox'),
          for (final (p, _) in projectTree()) (id: p.id, name: p.name),
        ],
        sections: [
          for (final (p, _) in [(inbox, 0), ...projectTree()])
            for (final s in sectionsOf(p.id)) (id: s.id, projectId: p.id, name: s.name),
        ],
        labels: [for (final l in labels) (id: l.id, name: l.name)],
      );

  ViewOptions projectViewOptions(String projectId) => ViewOptions.decode(project(projectId)?.viewOptions);

  List<Project> childrenOf(String? parentId) =>
      projects.where((p) => p.parentId == parentId && p.id != inboxId).toList();

  /// Projects in tree order with their indent level, skipping the Inbox.
  List<(Project, int)> projectTree() {
    final out = <(Project, int)>[];
    void walk(String? parent, int depth) {
      for (final p in childrenOf(parent)) {
        out.add((p, depth));
        walk(p.id, depth + 1);
      }
    }

    walk(null, 0);
    return out;
  }

  @override
  void dispose() {
    _disposed = true;
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }
}

/// Gives widgets the repository and catalog without a state-management package.
class AppScope extends InheritedNotifier<Catalog> {
  const AppScope({super.key, required Catalog catalog, required super.child}) : super(notifier: catalog);

  static Catalog of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()!.notifier!;

  static Repo repoOf(BuildContext context) => of(context).repo;
}
