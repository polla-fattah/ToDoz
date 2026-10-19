import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:url_launcher/url_launcher.dart';

import '../sync/sync_engine.dart';
import '../sync/transport.dart';
import 'catalog.dart';
import 'common.dart';

/// Calendar, Google Calendar and tools for scripts. All of it goes through the sync
/// server, so it needs a paired device (FR-X8, FR-I3..I6).
class IntegrationsScreen extends StatelessWidget {
  const IntegrationsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final sync = AppScope.of(context).sync;
    return Scaffold(
      appBar: AppBar(title: const Text('Calendar and integrations')),
      body: sync == null || !sync.paired
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text('These connect through your sync server. Set up sync first (Settings, Sync), then come back here.', textAlign: TextAlign.center),
              ),
            )
          : ListenableBuilder(
              listenable: sync,
              builder: (context, _) {
                final api = sync.api;
                if (api == null) return const SizedBox.shrink();
                return ListView(padding: const EdgeInsets.all(16), children: [
                  _GoogleSection(api: api),
                  const Divider(height: 40),
                  _FeedSection(api: api),
                  const Divider(height: 40),
                  _TokensSection(api: api),
                  const Divider(height: 40),
                  _WebhooksSection(api: api),
                  const SizedBox(height: 24),
                ]);
              },
            ),
    );
  }
}

String _problem(Object e) => e is SyncTransportException ? e.message : 'Something went wrong: ${e.toString().split('\n').first}';

/// Shows a value that will not be shown again, with a copy button.
Future<void> showSecret(BuildContext context, {required String title, required String body, required String secret, String? extra}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(body),
          const SizedBox(height: 12),
          SelectableText(secret, style: const TextStyle(fontFamily: 'monospace', fontSize: 13)),
          if (extra != null) ...[const SizedBox(height: 12), Text(extra)],
        ]),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: secret));
            if (ctx.mounted) showMessage(ctx, 'Copied');
          },
          child: const Text('Copy'),
        ),
        FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Done')),
      ],
    ),
  );
}

// -----------------------------------------------------------------------------
// Google Calendar
// -----------------------------------------------------------------------------

class _GoogleSection extends StatefulWidget {
  const _GoogleSection({required this.api});
  final ServerApi api;

  @override
  State<_GoogleSection> createState() => _GoogleSectionState();
}

class _GoogleSectionState extends State<_GoogleSection> {
  late Future<GoogleStatus> _status = widget.api.googleStatus();
  Timer? _poll;
  bool _waiting = false;
  bool _busy = false;
  String? _message;

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  void _reload() => setState(() {
        _status = widget.api.googleStatus();
      });

  Future<void> _connect() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      String zone = 'UTC';
      try {
        zone = (await FlutterTimezone.getLocalTimezone()).identifier;
      } catch (_) {}
      final url = await widget.api.googleConnectUrl(zone);
      final opened = await launchUrl(url, mode: LaunchMode.externalApplication);
      if (!opened) {
        setState(() => _message = 'Could not open the browser.');
        return;
      }
      setState(() => _waiting = true);
      var tries = 0;
      _poll?.cancel();
      _poll = Timer.periodic(const Duration(seconds: 3), (t) async {
        tries++;
        try {
          final s = await widget.api.googleStatus();
          if (s.connected && !s.needsReconnect) {
            t.cancel();
            if (mounted) {
              setState(() {
                _waiting = false;
                _status = Future.value(s);
              });
            }
          }
        } catch (_) {}
        if (tries >= 60) {
          t.cancel();
          if (mounted) setState(() => _waiting = false);
        }
      });
    } catch (e) {
      setState(() => _message = _problem(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _syncNow() async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final m = await widget.api.googleSyncNow();
      setState(() => _message = m);
      _reload();
    } catch (e) {
      setState(() => _message = _problem(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect() async {
    var deleteCalendar = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: const Text('Disconnect Google Calendar?'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('TaskFlow stops updating your calendar and forgets its access to Google.'),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: deleteCalendar,
              onChanged: (v) => set(() => deleteCalendar = v ?? false),
              title: const Text('Also delete the "TaskFlow" calendar from Google'),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Disconnect')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    try {
      await widget.api.googleDisconnect(deleteCalendar: deleteCalendar);
      _reload();
    } catch (e) {
      setState(() => _message = _problem(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return FutureBuilder<GoogleStatus>(
      future: _status,
      builder: (context, snap) {
        final s = snap.data;
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Google Calendar', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 4),
          const Text(
            'Tasks with a date appear as events in a calendar called "TaskFlow", and drag-and-drop of an event in Google moves the task. '
            'Only that calendar is touched: TaskFlow cannot see or change your other calendars.',
          ),
          const SizedBox(height: 12),
          if (snap.hasError)
            Text(_problem(snap.error!), style: TextStyle(color: cs.error))
          else if (s == null)
            const LinearProgressIndicator()
          else if (!s.configured)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  'Your server is not set up for Google yet. The person who runs it needs a Google "OAuth client" and to start the server with its id and secret. The steps are in the server README, under Google Calendar.',
                  style: TextStyle(color: cs.onSurfaceVariant),
                ),
              ),
            )
          else if (!s.connected)
            FilledButton.icon(
              onPressed: _busy || _waiting ? null : _connect,
              icon: _waiting ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.event_available_outlined),
              label: Text(_waiting ? 'Waiting for Google…' : 'Connect Google Calendar'),
            )
          else ...[
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(s.needsReconnect ? Icons.link_off : Icons.check_circle_outline, color: s.needsReconnect ? cs.error : Colors.green),
              title: Text(s.needsReconnect ? 'Google needs you to sign in again' : 'Connected'),
              subtitle: Text(s.lastSync == null ? 'Not synced yet' : 'Last synced ${s.lastSync!.toLocal().toString().substring(0, 16)} · time zone ${s.timeZone ?? ''}'),
            ),
            if (s.lastError != null && !s.needsReconnect) Text(s.lastError!, style: TextStyle(color: cs.error)),
            Wrap(spacing: 8, runSpacing: 8, children: [
              if (s.needsReconnect)
                FilledButton.icon(onPressed: _busy || _waiting ? null : _connect, icon: const Icon(Icons.refresh), label: const Text('Connect again'))
              else
                FilledButton.icon(onPressed: _busy ? null : _syncNow, icon: const Icon(Icons.sync), label: const Text('Sync now')),
              OutlinedButton(onPressed: _disconnect, child: const Text('Disconnect')),
            ]),
          ],
          if (_message != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_message!)),
        ]);
      },
    );
  }
}

// -----------------------------------------------------------------------------
// Calendar feed (a secret address any calendar app can subscribe to)
// -----------------------------------------------------------------------------

class _FeedSection extends StatefulWidget {
  const _FeedSection({required this.api});
  final ServerApi api;

  @override
  State<_FeedSection> createState() => _FeedSectionState();
}

class _FeedSectionState extends State<_FeedSection> {
  late Future<bool> _enabled = widget.api.calendarFeedEnabled();

  Future<void> _make({required bool replace}) async {
    if (replace) {
      final ok = await confirm(context, 'Replace the calendar link?', 'The old link stops working. Calendar apps using it need the new one.', action: 'Replace');
      if (!ok) return;
    }
    try {
      final url = await widget.api.createCalendarFeed();
      if (!mounted) return;
      setState(() {
        _enabled = Future.value(true);
      });
      await showSecret(
        context,
        title: 'Your calendar link',
        body: 'Add this address to a calendar app as a subscription (in Google Calendar: Other calendars, From URL). Anyone who has it can read your dated tasks, so keep it private. It is shown only now.',
        secret: url.toString(),
        extra: 'Subscribed calendars refresh on their own schedule, often every few hours, and cannot change your tasks.',
      );
    } catch (e) {
      if (mounted) showMessage(context, _problem(e));
    }
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<bool>(
        future: _enabled,
        builder: (context, snap) {
          final on = snap.data ?? false;
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Calendar link', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            const Text('A read-only link that shows your dated tasks in any calendar app (Google, Apple, Outlook). It works one way: the calendar cannot change your tasks.'),
            const SizedBox(height: 12),
            if (snap.connectionState != ConnectionState.done)
              const LinearProgressIndicator()
            else if (!on)
              FilledButton.icon(onPressed: () => _make(replace: false), icon: const Icon(Icons.link), label: const Text('Create a calendar link'))
            else
              Wrap(spacing: 8, runSpacing: 8, children: [
                OutlinedButton.icon(onPressed: () => _make(replace: true), icon: const Icon(Icons.autorenew), label: const Text('Make a new link')),
                OutlinedButton(
                  onPressed: () async {
                    if (!await confirm(context, 'Turn off the calendar link?', 'Calendar apps using it stop updating.', action: 'Turn off')) return;
                    await widget.api.deleteCalendarFeed();
                    if (mounted) {
                      setState(() {
                        _enabled = Future.value(false);
                      });
                    }
                  },
                  child: const Text('Turn off'),
                ),
              ]),
          ]);
        },
      );
}

// -----------------------------------------------------------------------------
// API tokens, for the owner's own scripts
// -----------------------------------------------------------------------------

class _TokensSection extends StatefulWidget {
  const _TokensSection({required this.api});
  final ServerApi api;

  @override
  State<_TokensSection> createState() => _TokensSectionState();
}

class _TokensSectionState extends State<_TokensSection> {
  late Future<List<Map<String, Object?>>> _tokens = widget.api.listApiTokens();

  void _reload() => setState(() {
        _tokens = widget.api.listApiTokens();
      });

  Future<void> _create() async {
    final name = await promptText(context, 'New API token', hint: 'What is it for? (for example: backup script)', action: 'Create');
    if (name == null || name.trim().isEmpty || !mounted) return;
    final readOnly = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('What may it do?'),
        content: const Text('A read-only token can look at your tasks but not change anything.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Read only')),
          FilledButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Read and change')),
        ],
      ),
    );
    if (readOnly == null || !mounted) return;
    try {
      final token = await widget.api.createApiToken(name.trim(), readOnly: readOnly);
      _reload();
      if (!mounted) return;
      await showSecret(
        context,
        title: 'Your API token',
        body: 'Use it as "Authorization: Bearer <token>" on ${widget.api.baseUrl}/api/v1/tasks and the other API addresses. It is shown only now.',
        secret: token,
      );
    } catch (e) {
      if (mounted) showMessage(context, _problem(e));
    }
  }

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('API access', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        const Text('Tokens let your own scripts read and change your tasks through the server\'s REST API.'),
        FutureBuilder<List<Map<String, Object?>>>(
          future: _tokens,
          builder: (context, snap) {
            final list = (snap.data ?? const []).where((t) => t['revoked'] != true).toList();
            return Column(children: [
              if (snap.hasError) Text(_problem(snap.error!), style: TextStyle(color: Theme.of(context).colorScheme.error)),
              for (final t in list)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(t['readOnly'] == true ? Icons.visibility_outlined : Icons.edit_outlined),
                  title: Text('${t['name']}'),
                  subtitle: Text('${t['readOnly'] == true ? 'Read only' : 'Read and change'}${t['lastUsed'] == null ? ' · never used' : ''}'),
                  trailing: IconButton(
                    tooltip: 'Revoke',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () async {
                      if (!await confirm(context, 'Revoke "${t['name']}"?', 'Scripts using it stop working at once.', action: 'Revoke')) return;
                      await widget.api.revokeApiToken(t['id']! as String);
                      _reload();
                    },
                  ),
                ),
              Align(alignment: Alignment.centerLeft, child: TextButton.icon(onPressed: _create, icon: const Icon(Icons.add), label: const Text('New token'))),
            ]);
          },
        ),
      ]);
}

// -----------------------------------------------------------------------------
// Webhooks
// -----------------------------------------------------------------------------

class _WebhooksSection extends StatefulWidget {
  const _WebhooksSection({required this.api});
  final ServerApi api;

  @override
  State<_WebhooksSection> createState() => _WebhooksSectionState();
}

class _WebhooksSectionState extends State<_WebhooksSection> {
  late Future<List<List<Map<String, Object?>>>> _load = _fetch();

  Future<List<List<Map<String, Object?>>>> _fetch() async => [await widget.api.listWebhooks(), await widget.api.listInboundHooks()];

  void _reload() => setState(() {
        _load = _fetch();
      });

  Future<void> _addOutgoing() async {
    final url = await promptText(context, 'Webhook address', hint: 'https://example.com/taskflow-hook', action: 'Add');
    if (url == null || url.trim().isEmpty || !mounted) return;
    try {
      final secret = await widget.api.createWebhook(url.trim(), const ['*']);
      _reload();
      if (!mounted) return;
      await showSecret(
        context,
        title: 'Webhook added',
        body: 'TaskFlow will POST JSON to that address when tasks are added, changed, completed or deleted. Each call is signed with this secret (HMAC-SHA256 of "timestamp.body" in the X-TaskFlow-Signature header). It is shown only now.',
        secret: secret,
      );
    } catch (e) {
      if (mounted) showMessage(context, _problem(e));
    }
  }

  Future<void> _addIncoming() async {
    final name = await promptText(context, 'Incoming webhook', hint: 'What will call it? (for example: IFTTT)', action: 'Create');
    if (name == null || name.trim().isEmpty || !mounted) return;
    try {
      final h = await widget.api.createInboundHook(name.trim());
      _reload();
      if (!mounted) return;
      await showSecret(
        context,
        title: 'Incoming webhook',
        body: 'Another system can POST {"text": "Buy milk tomorrow p1"} to this address to add a task. Calls must be signed with the secret below (see the server README). It is shown only now.',
        secret: '${h.url}\n\nSecret: ${h.secret}',
      );
    } catch (e) {
      if (mounted) showMessage(context, _problem(e));
    }
  }

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Webhooks', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 4),
        const Text('Let other systems know when tasks change, or let them add tasks. Every call is signed.'),
        FutureBuilder<List<List<Map<String, Object?>>>>(
          future: _load,
          builder: (context, snap) {
            final data = snap.data;
            if (snap.hasError) return Text(_problem(snap.error!), style: TextStyle(color: Theme.of(context).colorScheme.error));
            if (data == null) return const Padding(padding: EdgeInsets.all(12), child: LinearProgressIndicator());
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (final w in data[0])
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(w['active'] == true ? Icons.webhook : Icons.pause_circle_outline),
                  title: Text('${w['url']}', maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(w['active'] == true ? 'Last result: ${w['lastStatus'] ?? 'none yet'}' : 'Switched off after repeated failures'),
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (w['active'] != true)
                      IconButton(tooltip: 'Turn on again', icon: const Icon(Icons.play_arrow), onPressed: () async {
                        await widget.api.reactivateWebhook(w['id']! as String);
                        _reload();
                      }),
                    IconButton(tooltip: 'Delete', icon: const Icon(Icons.delete_outline), onPressed: () async {
                      await widget.api.deleteWebhook(w['id']! as String);
                      _reload();
                    }),
                  ]),
                ),
              for (final h in data[1])
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.input),
                  title: Text('Incoming: ${h['name']}'),
                  subtitle: Text(h['lastUsed'] == null ? 'Never used' : 'Used'),
                  trailing: IconButton(tooltip: 'Delete', icon: const Icon(Icons.delete_outline), onPressed: () async {
                    await widget.api.deleteInboundHook(h['id']! as String);
                    _reload();
                  }),
                ),
              Wrap(spacing: 8, children: [
                TextButton.icon(onPressed: _addOutgoing, icon: const Icon(Icons.add), label: const Text('Send events to…')),
                TextButton.icon(onPressed: _addIncoming, icon: const Icon(Icons.add), label: const Text('Accept tasks from…')),
              ]),
            ]);
          },
        ),
      ]);
}
