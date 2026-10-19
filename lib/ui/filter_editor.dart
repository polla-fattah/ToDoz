import 'package:flutter/material.dart';

import 'package:taskflow_core/filter.dart';
import '../data/database.dart';
import 'catalog.dart';
import 'common.dart';

/// A query field that underlines the part the filter parser rejected (FR-F5).
class QueryController extends TextEditingController {
  QueryController({super.text});

  FilterException? error;

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    final e = error;
    if (e == null || text.isEmpty) return super.buildTextSpan(context: context, style: style, withComposing: withComposing);
    final start = e.start.clamp(0, text.length);
    final end = (e.end <= start ? start + 1 : e.end).clamp(start, text.length);
    if (start >= end) return TextSpan(style: style, text: text);
    final red = Theme.of(context).colorScheme.error;
    return TextSpan(style: style, children: [
      TextSpan(text: text.substring(0, start)),
      TextSpan(
        text: text.substring(start, end),
        style: TextStyle(color: red, decoration: TextDecoration.underline, decorationStyle: TextDecorationStyle.wavy, decorationColor: red),
      ),
      TextSpan(text: text.substring(end)),
    ]);
  }
}

/// Create or edit a saved filter: name, colour, and a query that is checked as you type.
class FilterEditorPage extends StatefulWidget {
  const FilterEditorPage({super.key, this.filterId, this.initialQuery = ''});
  final String? filterId;
  final String initialQuery;

  @override
  State<FilterEditorPage> createState() => _FilterEditorPageState();
}

class _FilterEditorPageState extends State<FilterEditorPage> {
  final _name = TextEditingController();
  final _query = QueryController();
  int _color = 0xFF4180FF;
  bool _loaded = false;
  bool _saving = false;
  CompiledFilter? _compiled;
  String? _problem;

  @override
  void dispose() {
    _name.dispose();
    _query.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    final catalog = AppScope.of(context);
    final f = widget.filterId == null ? null : catalog.filter(widget.filterId!);
    if (f != null) {
      _name.text = f.name;
      _query.text = f.query;
      _color = f.color;
    } else {
      _query.text = widget.initialQuery;
    }
    _check(catalog);
  }

  void _check(Catalog catalog) {
    final text = _query.text;
    if (text.trim().isEmpty) {
      _compiled = null;
      _problem = null;
      _query.error = null;
      return;
    }
    try {
      _compiled = parseFilter(text, catalog.filterEnv);
      _problem = null;
      _query.error = null;
    } on FilterException catch (e) {
      _compiled = null;
      _problem = e.message;
      _query.error = e;
    }
  }

  Future<void> _save() async {
    final catalog = AppScope.of(context);
    final repo = catalog.repo;
    setState(() => _saving = true);
    var ok = true;
    await guarded(context, () async {
      try {
        if (widget.filterId == null) {
          await repo.createFilter(name: _name.text, query: _query.text, color: _color);
        } else {
          await repo.updateFilter(widget.filterId!, name: _name.text, query: _query.text, color: _color);
        }
      } catch (_) {
        ok = false;
        rethrow;
      }
    });
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
    } else {
      setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final catalog = AppScope.of(context);
    final repo = catalog.repo;
    final cs = Theme.of(context).colorScheme;
    final canSave = !_saving && _name.text.trim().isNotEmpty && _compiled != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.filterId == null ? 'New filter' : 'Edit filter'),
        actions: [
          TextButton(onPressed: canSave ? _save : null, child: const Text('Save')),
        ],
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        TextField(
          controller: _name,
          maxLength: 100,
          decoration: const InputDecoration(labelText: 'Name', counterText: ''),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _query,
          maxLines: null,
          autofocus: widget.filterId == null,
          style: const TextStyle(fontFamily: 'monospace'),
          decoration: InputDecoration(
            labelText: 'Query',
            hintText: 'today | overdue',
            errorText: _problem,
            errorMaxLines: 3,
            helperText: _compiled != null ? 'Looks good' : null,
          ),
          onChanged: (_) => setState(() => _check(catalog)),
        ),
        const SizedBox(height: 8),
        if (_compiled != null)
          Live<List<Task>>(
            create: repo.watchAllOpen,
            builder: (context, data) {
              final all = data ?? const <Task>[];
              final c = _compiled;
              if (c == null) return const SizedBox.shrink();
              final n = all.where((t) => c.matches(catalog.filterTask(t))).length;
              return Text('$n open task${n == 1 ? '' : 's'} match${n == 1 ? 'es' : ''} right now.', style: TextStyle(color: cs.primary));
            },
          ),
        const SizedBox(height: 16),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final c in projectPalette)
            InkResponse(
              onTap: () => setState(() => _color = c),
              child: CircleAvatar(
                radius: 14,
                backgroundColor: Color(c),
                child: c == _color ? const Icon(Icons.check, size: 16, color: Colors.white) : null,
              ),
            ),
        ]),
        const SizedBox(height: 24),
        Text('Examples (tap to use)', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        for (final (q, what) in filterExamples)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(q, style: const TextStyle(fontFamily: 'monospace')),
            subtitle: Text(what),
            onTap: () => setState(() {
              _query.text = q;
              _check(catalog);
            }),
          ),
        const SizedBox(height: 8),
        Text(
          '& means and, | means or, ! means not. A comma starts a separate list. '
          '#Project, ##Project (with sub-projects), %label, /section. See Help for every keyword.',
          style: TextStyle(color: cs.outline, fontSize: 12),
        ),
      ]),
    );
  }
}
