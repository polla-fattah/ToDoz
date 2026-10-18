import 'package:flutter/material.dart';

import '../core/date_parser.dart';
import 'catalog.dart';

/// Priority colours: p1 red, p2 orange, p3 blue, p4 grey (as Todoist).
/// Priority is also shown as text/flags wherever it is edited (NFR-13).
Color priorityColor(int p, ColorScheme cs) => switch (p) {
      1 => const Color(0xFFD1453B),
      2 => const Color(0xFFEB8909),
      3 => const Color(0xFF246FE0),
      _ => cs.outline,
    };

const projectPalette = <int>[
  0xFFB8255F, 0xFFDC4C3E, 0xFFC77100, 0xFFB29104, 0xFF949C31, 0xFF65A33A,
  0xFF369307, 0xFF42A393, 0xFF148FAD, 0xFF319DC0, 0xFF6988A4, 0xFF4180FF,
  0xFF692EC2, 0xFFCA3FEE, 0xFFA4698C, 0xFF6A6A6A,
];

/// "Today", "Tomorrow", "Mon 19 Oct", "19 Oct 2027".
String dueLabel(String iso, DateTime now) {
  final d = parseIsoDate(iso);
  if (d == null) return iso;
  final today = dateOnly(now);
  final diff = d.difference(today).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Tomorrow';
  if (diff == -1) return 'Yesterday';
  const wd = ['', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  const mo = ['', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  if (diff > 1 && diff < 7) return '${wd[d.weekday]} ${d.day} ${mo[d.month]}';
  final year = d.year == today.year ? '' : ' ${d.year}';
  return '${d.day} ${mo[d.month]}$year';
}

/// "Today 16:30", "Tomorrow", "Mon 19 Oct 08:00".
String dueText(String iso, String? hhmm, DateTime now, {bool use24h = true}) {
  final day = dueLabel(iso, now);
  final m = hhmm == null ? null : parseClock(hhmm);
  return m == null ? day : '$day ${formatTime(m, use24h: use24h)}';
}

String dayHeading(String iso, DateTime now) {
  final d = parseIsoDate(iso);
  if (d == null) return iso;
  const wd = ['', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
  const mo = ['', 'January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
  final rel = dueLabel(iso, now);
  final base = '${d.day} ${mo[d.month]} · ${wd[d.weekday]}';
  return (rel == 'Today' || rel == 'Tomorrow') ? '$base · $rel' : base;
}

void showUndo(BuildContext context, String message, VoidCallback onUndo) {
  final m = ScaffoldMessenger.of(context);
  m.hideCurrentSnackBar();
  m.showSnackBar(SnackBar(
    content: Text(message),
    duration: const Duration(seconds: 8), // FR-T8: at least 8 seconds
    // A snackbar with an action stays until dismissed unless told otherwise; an
    // old "Undo" left on screen is easy to hit by mistake (found on a device).
    persist: false,
    action: SnackBarAction(label: 'Undo', onPressed: onUndo),
  ));
}

void showMessage(BuildContext context, String message) {
  final m = ScaffoldMessenger.of(context);
  m.hideCurrentSnackBar();
  m.showSnackBar(SnackBar(content: Text(message)));
}

Future<T?> pickFromList<T>(BuildContext context, String title, List<(T, String)> items, {T? selected}) {
  return showDialog<T>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: Text(title),
      children: [
        for (final (value, label) in items)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, value),
            child: Row(children: [
              Expanded(child: Text(label)),
              if (value == selected) const Icon(Icons.check, size: 18),
            ]),
          ),
      ],
    ),
  );
}

Future<String?> promptText(BuildContext context, String title, {String initial = '', String hint = '', String action = 'Save'}) {
  final c = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: c,
        autofocus: true,
        decoration: InputDecoration(hintText: hint),
        onSubmitted: (v) => Navigator.pop(ctx, v),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: Text(action)),
      ],
    ),
  );
}

Future<bool> confirm(BuildContext context, String title, String body, {String action = 'Delete'}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(action)),
      ],
    ),
  );
  return r ?? false;
}

/// Runs [f], showing a rule violation (too deep, loop, duplicate) as a message.
Future<void> guarded(BuildContext context, Future<void> Function() f) async {
  try {
    await f();
  } on Exception catch (e) {
    if (context.mounted) showMessage(context, e.toString());
  }
}

extension CatalogColors on Catalog {
  Color colorOf(String projectId) => Color(project(projectId)?.color ?? 0xFF6A6A6A);
}

/// Listens to a database stream and rebuilds with its latest value.
///
/// The stream is created once, not on every build: creating it inside
/// `build()` would resubscribe on each rebuild, and each new subscription
/// emits again, which rebuilds again, forever. [id] identifies what is being
/// watched; when it changes (another project, a new day) the stream is
/// recreated.
class Live<T> extends StatefulWidget {
  const Live({super.key, required this.create, required this.builder, this.id});

  final Stream<T> Function() create;
  final Widget Function(BuildContext context, T? data) builder;
  final Object? id;

  @override
  State<Live<T>> createState() => _LiveState<T>();
}

class _LiveState<T> extends State<Live<T>> {
  late Stream<T> _stream = widget.create();

  @override
  void didUpdateWidget(Live<T> old) {
    super.didUpdateWidget(old);
    if (old.id != widget.id) _stream = widget.create();
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<T>(
        stream: _stream,
        builder: (context, snap) => widget.builder(context, snap.data),
      );
}
