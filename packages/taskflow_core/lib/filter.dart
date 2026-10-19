/// The filter query language (FR-F2 to FR-F4), modelled on Todoist's.
///
///   today | overdue            either
///   today & p1                 both
///   !subtask                   not
///   (today | overdue) & #Work  grouping
///   p1 & overdue, p4 & today   a comma starts a separate list in the same view
///   #Shopping\ list            a backslash makes the next character ordinary
///   #"Shopping list"           so does quoting
///   %home*                     * matches any characters
///
/// Prefixes: #project  ##project (and its sub-projects)  %label (or @label)
/// /section  /* (no section).
///
/// Keywords: today, tomorrow, overdue, no date, no time, recurring, 7 days,
/// next 7 days, date before: X, date after: X, due before: X, due after: X,
/// created: X, created before: X, created after: X, no deadline,
/// deadline before: X, deadline after: X, p1-p4, no priority, subtask,
/// no labels, search: text, view all, and for shared projects: assigned,
/// assigned to: me / others / a name, assigned by: me / a name, shared.
///
/// Pure Dart. Errors carry the span of the offending text so the editor can
/// underline it.
library;

import 'date_parser.dart';
import 'quick_add.dart' show normaliseName;
import 'reminder.dart' show isOverdue;

class FilterException implements Exception {
  FilterException(this.message, this.start, this.end);
  final String message;

  /// The offending span in the query text (end exclusive).
  final int start;
  final int end;

  @override
  String toString() => message;
}

/// What a filter needs to know about a task. Built from the database by the caller.
class FilterTask {
  const FilterTask({
    required this.id,
    required this.title,
    required this.projectId,
    this.description = '',
    this.sectionId,
    this.parentId,
    this.priority = 4,
    this.dueDate,
    this.dueTime,
    this.recurrence,
    this.deadline,
    this.labels = const [],
    required this.createdAt,
    this.assigneeId,
    this.assignedById,
  });
  final String id;
  final String title;
  final String description;
  final String projectId;
  final String? sectionId;
  final String? parentId;
  final int priority;
  final String? dueDate;
  final String? dueTime;
  final String? recurrence;
  final String? deadline;
  final List<String> labels; // lower-case names
  final DateTime createdAt;

  /// Who the task is assigned to and who assigned it (user ids), in a shared project.
  final String? assigneeId;
  final String? assignedById;
}

class FilterProject {
  const FilterProject(this.id, this.name, {this.parentId});
  final String id;
  final String name;
  final String? parentId;
}

class FilterSectionInfo {
  const FilterSectionInfo(this.id, this.projectId, this.name);
  final String id;
  final String projectId;
  final String name;
}

/// The names a query can refer to, and "now".
class FilterEnv {
  const FilterEnv({
    required this.now,
    this.projects = const [],
    this.sections = const [],
    this.weekStart = 1,
    this.currentUserId,
    this.memberNames = const {},
    this.sharedProjectIds = const {},
  });
  final DateTime now;

  /// This person's user id, and the names of everyone they share projects with (id to name).
  final String? currentUserId;
  final Map<String, String> memberNames;

  /// The projects that are shared.
  final Set<String> sharedProjectIds;
  final List<FilterProject> projects;
  final List<FilterSectionInfo> sections;
  final int weekStart;
}

typedef TaskTest = bool Function(FilterTask t);

/// One comma-separated list in a query.
class FilterBranch {
  const FilterBranch(this.text, this._test);

  /// The query text of this list, used as its heading.
  final String text;
  final TaskTest _test;

  bool matches(FilterTask t) => _test(t);
}

class CompiledFilter {
  const CompiledFilter(this.branches);
  final List<FilterBranch> branches;

  bool get isSingle => branches.length == 1;

  /// True if any list matches.
  bool matches(FilterTask t) => branches.any((b) => b.matches(t));
}

// -----------------------------------------------------------------------------
// Tokens
// -----------------------------------------------------------------------------

enum _T { and, or, not, lparen, rparen, comma, atom }

class _Tok {
  const _Tok(this.type, this.text, this.start, this.end);
  final _T type;
  final String text; // for atoms: the unescaped text
  final int start;
  final int end;
}

List<_Tok> _tokenize(String q) {
  final out = <_Tok>[];
  var i = 0;
  while (i < q.length) {
    final c = q[i];
    if (c == ' ' || c == '\t' || c == '\n') {
      i++;
      continue;
    }
    switch (c) {
      case '&':
        out.add(_Tok(_T.and, c, i, i + 1));
        i++;
        continue;
      case '|':
        out.add(_Tok(_T.or, c, i, i + 1));
        i++;
        continue;
      case '!':
        out.add(_Tok(_T.not, c, i, i + 1));
        i++;
        continue;
      case '(':
        out.add(_Tok(_T.lparen, c, i, i + 1));
        i++;
        continue;
      case ')':
        out.add(_Tok(_T.rparen, c, i, i + 1));
        i++;
        continue;
      case ',':
        out.add(_Tok(_T.comma, c, i, i + 1));
        i++;
        continue;
    }
    // An atom: runs to the next operator. A backslash or a quote makes
    // characters ordinary. "search:" text runs to the next & | , or ).
    final start = i;
    final buf = StringBuffer();
    var searchMode = false;
    while (i < q.length) {
      final ch = q[i];
      if (ch == '\\' && i + 1 < q.length) {
        buf.write(q[i + 1]);
        i += 2;
        continue;
      }
      if (ch == '"') {
        final close = q.indexOf('"', i + 1);
        if (close == -1) throw FilterException('A quote is not closed.', i, q.length);
        buf.write(q.substring(i + 1, close));
        i = close + 1;
        continue;
      }
      if (!searchMode && buf.toString().trimLeft().toLowerCase().startsWith('search:')) searchMode = true;
      final isOp = searchMode ? (ch == '&' || ch == '|' || ch == ',' || ch == ')') : '&|!(),'.contains(ch);
      if (isOp) break;
      buf.write(ch);
      i++;
    }
    var text = buf.toString().trim();
    // Trim trailing space from the span too.
    var end = i;
    while (end > start && q[end - 1] == ' ') {
      end--;
    }
    if (text.isNotEmpty) out.add(_Tok(_T.atom, text, start, end));
  }
  return out;
}

// -----------------------------------------------------------------------------
// Parser
// -----------------------------------------------------------------------------

/// Compiles [query]. Throws [FilterException] with the span of the problem.
CompiledFilter parseFilter(String query, FilterEnv env) {
  final tokens = _tokenize(query);
  if (tokens.isEmpty) throw FilterException('Type a query, for example "today & p1".', 0, 0);
  final p = _Parser(query, tokens, env);
  return p.parseAll();
}

class _Parser {
  _Parser(this.q, this.toks, this.env);
  final String q;
  final List<_Tok> toks;
  final FilterEnv env;
  var pos = 0;
  var depth = 0;

  _Tok? get peek => pos < toks.length ? toks[pos] : null;

  CompiledFilter parseAll() {
    final branches = <FilterBranch>[];
    var startTok = pos;
    while (true) {
      final node = parseOr();
      final first = toks[startTok];
      final last = toks[pos - 1];
      branches.add(FilterBranch(q.substring(first.start, last.end).trim(), node));
      final t = peek;
      if (t == null) break;
      if (t.type == _T.comma) {
        pos++;
        startTok = pos;
        if (peek == null) throw FilterException('Add a query after the comma.', t.start, t.end);
        continue;
      }
      if (t.type == _T.rparen) throw FilterException('There is a ")" without a matching "(".', t.start, t.end);
      throw FilterException('Use & or | between conditions.', t.start, t.end);
    }
    return CompiledFilter(branches);
  }

  TaskTest parseOr() {
    var left = parseAnd();
    while (peek?.type == _T.or) {
      pos++;
      final l = left;
      final r = parseAnd();
      left = (t) => l(t) || r(t);
    }
    return left;
  }

  TaskTest parseAnd() {
    var left = parseNot();
    while (peek?.type == _T.and) {
      pos++;
      final l = left;
      final r = parseNot();
      left = (t) => l(t) && r(t);
    }
    return left;
  }

  TaskTest parseNot() {
    final t = peek;
    if (t != null && t.type == _T.not) {
      pos++;
      if (peek == null) throw FilterException('"!" needs a condition after it.', t.start, t.end);
      final inner = parseNot();
      return (x) => !inner(x);
    }
    return parsePrimary();
  }

  TaskTest parsePrimary() {
    final t = peek;
    if (t == null) {
      final prev = toks.last;
      throw FilterException('The query ends too soon; add a condition.', prev.start, prev.end);
    }
    switch (t.type) {
      case _T.lparen:
        pos++;
        depth++;
        final inner = parseOr();
        final close = peek;
        if (close == null || close.type != _T.rparen) {
          if (close != null && close.type == _T.comma) {
            throw FilterException('A comma starts a new list; it cannot go inside brackets.', close.start, close.end);
          }
          throw FilterException('Missing ")" to close this bracket.', t.start, t.end);
        }
        pos++;
        depth--;
        return inner;
      case _T.atom:
        pos++;
        return _atom(t);
      case _T.rparen:
        throw FilterException('Nothing between the brackets.', t.start, t.end);
      default:
        throw FilterException('Expected a condition here.', t.start, t.end);
    }
  }

  // --- atoms --------------------------------------------------------------

  TaskTest _atom(_Tok tok) {
    final raw = tok.text;
    final s = raw.toLowerCase();
    final now = env.now;
    final today = formatDate(dateOnly(now));
    final tomorrow = formatDate(dateOnly(now).add(const Duration(days: 1)));

    FilterException bad(String msg) => FilterException(msg, tok.start, tok.end);

    // Projects, labels, sections.
    if (raw.startsWith('##')) {
      final name = raw.substring(2);
      final ids = _projectIds(name, withChildren: true);
      if (ids.isEmpty) throw bad('No project matches "$name".');
      return (t) => ids.contains(t.projectId);
    }
    if (raw.startsWith('#')) {
      final name = raw.substring(1);
      final ids = _projectIds(name, withChildren: false);
      if (ids.isEmpty) throw bad('No project matches "$name".');
      return (t) => ids.contains(t.projectId);
    }
    if (raw.startsWith('%') || raw.startsWith('@')) {
      final name = raw.substring(1).toLowerCase();
      if (name.isEmpty) throw bad('Type a label name after ${raw[0]}.');
      final re = _wildcard(name);
      return (t) => t.labels.any(re.hasMatch);
    }
    if (raw == '/*') return (t) => t.sectionId == null;
    if (raw.startsWith('/')) {
      final name = raw.substring(1);
      if (name.isEmpty) throw bad('Type a section name after /.');
      final re = _wildcard(name.toLowerCase());
      final ids = {
        for (final sec in env.sections)
          if (re.hasMatch(sec.name.toLowerCase()) || re.hasMatch(normaliseName(sec.name))) sec.id,
      };
      if (ids.isEmpty) throw bad('No section matches "$name".');
      return (t) => t.sectionId != null && ids.contains(t.sectionId);
    }

    // Priority.
    final pm = RegExp(r'^p([1-4])$').firstMatch(s);
    if (pm != null) {
      final n = int.parse(pm[1]!);
      return (t) => t.priority == n;
    }
    if (s == 'no priority') return (t) => t.priority == 4;

    // Dates.
    switch (s) {
      case 'today':
        return (t) => t.dueDate == today;
      case 'tomorrow':
        return (t) => t.dueDate == tomorrow;
      case 'overdue':
        return (t) => isOverdue(dueDate: t.dueDate, dueTime: t.dueTime, now: now);
      case 'no date':
        return (t) => t.dueDate == null;
      case 'no time':
        return (t) => t.dueTime == null;
      case 'recurring':
        return (t) => t.recurrence != null;
      case 'no deadline':
        return (t) => t.deadline == null;
      case 'subtask':
        return (t) => t.parentId != null;
      case 'no labels':
        return (t) => t.labels.isEmpty;
      case 'view all':
        return (t) => true;
      case 'assigned':
        return (t) => t.assigneeId != null;
      case 'shared':
        return (t) => env.sharedProjectIds.contains(t.projectId);
    }
    final asg = RegExp(r'^assigned\s+(to|by)\s*:\s*(.+)$').firstMatch(s);
    if (asg != null) {
      final by = asg[1] == 'by';
      final who = asg[2]!.trim();
      String? idOf(FilterTask t) => by ? t.assignedById : t.assigneeId;
      if (who == 'me') return (t) => idOf(t) != null && idOf(t) == env.currentUserId;
      if (who == 'others' && !by) return (t) => t.assigneeId != null && t.assigneeId != env.currentUserId;
      final re = _wildcard(who);
      final ids = {
        for (final e in env.memberNames.entries)
          if (re.hasMatch(e.value.toLowerCase())) e.key,
      };
      if (ids.isEmpty) throw bad('Nobody you share a project with matches "$who".');
      return (t) => idOf(t) != null && ids.contains(idOf(t));
    }
    final nd = RegExp(r'^(?:next )?(\d{1,3}) days?$').firstMatch(s);
    if (nd != null) {
      final n = int.parse(nd[1]!);
      final last = formatDate(dateOnly(now).add(Duration(days: n - 1)));
      // Overdue tasks are included, as in the Upcoming view.
      return (t) => t.dueDate != null && (isOverdue(dueDate: t.dueDate, dueTime: t.dueTime, now: now) || t.dueDate!.compareTo(last) <= 0);
    }
    final dm = RegExp(r'^(?:date|due)\s+(before|after)\s*:\s*(.+)$').firstMatch(s);
    if (dm != null) {
      final ref = _date(dm[2]!, tok);
      final before = dm[1] == 'before';
      return (t) => t.dueDate != null && (before ? t.dueDate!.compareTo(ref) < 0 : t.dueDate!.compareTo(ref) > 0);
    }
    final dl = RegExp(r'^deadline\s+(before|after)\s*:\s*(.+)$').firstMatch(s);
    if (dl != null) {
      final ref = _date(dl[2]!, tok);
      final before = dl[1] == 'before';
      return (t) => t.deadline != null && (before ? t.deadline!.compareTo(ref) < 0 : t.deadline!.compareTo(ref) > 0);
    }
    final cr = RegExp(r'^created(?:\s+(before|after))?\s*:\s*(.+)$').firstMatch(s);
    if (cr != null) {
      final ref = _date(cr[2]!, tok);
      final mode = cr[1];
      return (t) {
        final day = formatDate(dateOnly(t.createdAt));
        if (mode == 'before') return day.compareTo(ref) < 0;
        if (mode == 'after') return day.compareTo(ref) > 0;
        return day == ref;
      };
    }
    final sm = RegExp(r'^search\s*:\s*(.*)$', dotAll: true).firstMatch(raw.toLowerCase());
    if (sm != null) {
      final text = sm[1]!.trim();
      if (text.isEmpty) throw bad('Type what to search for after "search:".');
      final re = _wildcard(text, whole: false);
      return (t) {
        if (re.hasMatch(t.title.toLowerCase()) || re.hasMatch(t.description.toLowerCase())) return true;
        if (t.labels.any(re.hasMatch)) return true;
        final project = env.projects.where((p) => p.id == t.projectId).firstOrNull;
        if (project != null && re.hasMatch(project.name.toLowerCase())) return true;
        final section = env.sections.where((x) => x.id == t.sectionId).firstOrNull;
        return section != null && re.hasMatch(section.name.toLowerCase());
      };
    }

    throw bad(_suggest(s));
  }

  String _suggest(String s) {
    if (RegExp(r'^(date|due|deadline|created)\b').hasMatch(s) && !s.contains(':')) {
      return 'Add "before:" or "after:" and a date, for example "due before: tomorrow".';
    }
    if (s.startsWith('p') && RegExp(r'^p\d+$').hasMatch(s)) return 'Priorities are p1, p2, p3 and p4.';
    if (s.startsWith('assigned')) return 'Try "assigned to: me", "assigned to: others", "assigned by: me", "assigned" or "!assigned".';
    return 'I do not understand "$s". Try "today", "p1", "#Project", "%label" or "search: words".';
  }

  String _date(String text, _Tok tok) {
    final t = text.trim();
    final ago = RegExp(r'^(\d{1,4})\s*days?\s*ago$').firstMatch(t) ?? RegExp(r'^-\s*(\d{1,4})\s*days?$').firstMatch(t);
    if (ago != null) return formatDate(dateOnly(env.now).subtract(Duration(days: int.parse(ago[1]!))));
    if (t == 'yesterday') return formatDate(dateOnly(env.now).subtract(const Duration(days: 1)));
    final iso = parseIsoDate(t);
    if (iso != null) return formatDate(iso);
    final m = parseDate(t, env.now, weekStart: env.weekStart);
    if (m == null || m.start != 0 || m.end != t.length) {
      throw FilterException('I could not read the date "$t".', tok.start, tok.end);
    }
    return formatDate(m.date);
  }

  Set<String> _projectIds(String name, {required bool withChildren}) {
    final re = _wildcard(name.toLowerCase());
    final hit = <String>{
      for (final p in env.projects)
        if (re.hasMatch(p.name.toLowerCase()) || re.hasMatch(normaliseName(p.name))) p.id,
    };
    if (!withChildren) return hit;
    final out = {...hit};
    var grew = true;
    while (grew) {
      grew = false;
      for (final p in env.projects) {
        if (p.parentId != null && out.contains(p.parentId) && out.add(p.id)) grew = true;
      }
    }
    return out;
  }
}

/// A case-insensitive matcher where `*` stands for any characters.
RegExp _wildcard(String pattern, {bool whole = true}) {
  final parts = pattern.split('*').map(RegExp.escape);
  final body = parts.join('.*');
  return RegExp(whole ? '^$body\$' : body, caseSensitive: false, dotAll: true);
}

/// A quick check without needing the names: is [query] valid syntax? Used to
/// decide whether a search box entry is a filter or plain text.
bool looksLikeFilter(String query, FilterEnv env) {
  try {
    final f = parseFilter(query, env);
    return f.branches.isNotEmpty;
  } on FilterException {
    return false;
  }
}

/// Example queries shown in the filter editor and the help page.
const filterExamples = <(String, String)>[
  ('today | overdue', 'Due today or late'),
  ('(today | overdue) & p1', 'Urgent and due'),
  ('#Work & !subtask', 'Top-level tasks in Work'),
  ('##Home & %errands', 'In Home or its sub-projects, with the label errands'),
  ('no date & no labels', 'Nothing planned yet'),
  ('7 days & !recurring', 'Due this week, not repeating'),
  ('due before: next monday', 'Due before Monday'),
  ('search: invoice', 'Mentions "invoice"'),
  ('p1 & overdue, p4 & today', 'Two lists in one view'),
];
