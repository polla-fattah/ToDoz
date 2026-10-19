import 'dart:io';

import 'package:flutter/material.dart';
import 'package:taskflow_core/sync.dart';

import '../sync/background_sync.dart' show lastRunKey;
import '../sync/sync_engine.dart';
import '../sync/sync_service.dart';
import '../sync/transport.dart';
import 'catalog.dart';
import 'common.dart';

/// Pair this device with the sync server, see its status, and manage devices (R4).
class SyncScreen extends StatelessWidget {
  const SyncScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final sync = AppScope.of(context).sync;
    return Scaffold(
      appBar: AppBar(title: const Text('Sync')),
      body: sync == null
          ? const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('Sync is not available in this build.')))
          : ListenableBuilder(
              listenable: sync,
              builder: (context, _) => sync.paired ? _Paired(sync: sync) : _Pairing(sync: sync),
            ),
    );
  }
}

const _privacyNote = 'Your tasks are stored on the sync server in readable form: they are not end-to-end encrypted, '
    'so whoever runs the server can read them. Over the internet everything travels over HTTPS.';

// -----------------------------------------------------------------------------
// Not paired
// -----------------------------------------------------------------------------

class _Pairing extends StatefulWidget {
  const _Pairing({required this.sync});
  final SyncService sync;

  @override
  State<_Pairing> createState() => _PairingState();
}

class _PairingState extends State<_Pairing> {
  final _url = TextEditingController(text: 'https://todoz.polla.dev');
  final _code = TextEditingController();
  final _device = TextEditingController(
    text: Platform.isAndroid ? 'Android phone' : (Platform.isWindows ? 'Windows PC' : 'My device'),
  );
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    _code.dispose();
    _device.dispose();
    super.dispose();
  }

  bool get _ready => _url.text.trim().isNotEmpty && isValidPairingCode(_code.text) && !_busy;

  Future<void> _pair() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.sync.pair(_url.text, _code.text, _device.text);
      if (mounted) showMessage(context, 'Paired. Syncing now.');
    } on SyncTransportException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not pair: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text('Keep your devices in step', style: Theme.of(context).textTheme.titleLarge),
      const SizedBox(height: 8),
      const Text(
        'Sync copies your tasks between your phone and computer through a ToDoz server you run. '
        'The app works fully without it. To pair this device, ask the person who runs the server for a pairing code '
        '(on the server: taskflow_server invite <name>).',
      ),
      const SizedBox(height: 20),
      TextField(
        controller: _url,
        keyboardType: TextInputType.url,
        autocorrect: false,
        decoration: const InputDecoration(labelText: 'Server address', hintText: 'https://todoz.polla.dev'),
        onChanged: (_) => setState(() {}),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _code,
        textCapitalization: TextCapitalization.characters,
        autocorrect: false,
        style: const TextStyle(fontFamily: 'monospace', letterSpacing: 2),
        decoration: const InputDecoration(labelText: 'Pairing code', hintText: 'ABCD-2345'),
        onChanged: (_) => setState(() {}),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _device,
        maxLength: 60,
        decoration: const InputDecoration(labelText: 'Name of this device', counterText: ''),
      ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(_error!, style: TextStyle(color: cs.error)),
        ),
      const SizedBox(height: 16),
      FilledButton.icon(
        onPressed: _ready ? _pair : null,
        icon: _busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.link),
        label: const Text('Pair this device'),
      ),
      const SizedBox(height: 24),
      Text(_privacyNote, style: TextStyle(color: cs.outline, fontSize: 12)),
    ]);
  }
}

// -----------------------------------------------------------------------------
// Paired
// -----------------------------------------------------------------------------

class _Paired extends StatefulWidget {
  const _Paired({required this.sync});
  final SyncService sync;

  @override
  State<_Paired> createState() => _PairedState();
}

class _PairedState extends State<_Paired> {
  late Future<MeInfo> _me = _load();
  late Future<String?> _lastBackground = widget.sync.repo.getSetting(lastRunKey);

  Future<MeInfo> _load() => widget.sync.loadMe();

  String _ago(DateTime? t) {
    if (t == null) return 'never';
    final d = DateTime.now().difference(t);
    if (d.inSeconds < 60) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes} min ago';
    if (d.inHours < 24) return '${d.inHours} h ago';
    return '${d.inDays} days ago';
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.sync;
    final cs = Theme.of(context).colorScheme;
    final (icon, color, headline) = switch (s.state) {
      SyncState.syncing => (Icons.sync, cs.primary, 'Syncing…'),
      SyncState.idle => (Icons.cloud_done_outlined, const Color(0xFF058527), s.pendingChanges == 0 ? 'Up to date' : '${s.pendingChanges} changes waiting'),
      SyncState.error => (Icons.cloud_off_outlined, cs.error, 'Could not sync'),
      SyncState.signedOut => (Icons.block, cs.error, 'This device was signed out'),
      SyncState.unpaired => (Icons.link_off, cs.outline, 'Not paired'),
    };
    return ListView(padding: const EdgeInsets.all(16), children: [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(icon, color: color, size: 28),
              const SizedBox(width: 12),
              Expanded(child: Text(headline, style: Theme.of(context).textTheme.titleMedium)),
            ]),
            const SizedBox(height: 12),
            Text('Signed in as ${s.userName ?? ''} on ${s.deviceName ?? 'this device'}'),
            Text('Server: ${s.serverUrl?.host ?? ''}', style: TextStyle(color: cs.outline)),
            Text('Last sync: ${_ago(s.lastSyncAt)}', style: TextStyle(color: cs.outline)),
            if (s.lastError != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(s.lastError!, style: TextStyle(color: cs.error)),
              ),
            if (s.state == SyncState.signedOut)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('The server no longer accepts this device. Your tasks are still here. Unpair, then pair again with a new code.'),
              ),
          ]),
        ),
      ),
      const SizedBox(height: 12),
      Wrap(spacing: 8, runSpacing: 8, children: [
        FilledButton.icon(
          onPressed: s.state == SyncState.syncing || s.state == SyncState.signedOut ? null : s.syncNow,
          icon: const Icon(Icons.sync),
          label: const Text('Sync now'),
        ),
        OutlinedButton.icon(
          onPressed: s.state == SyncState.syncing || s.state == SyncState.signedOut
              ? null
              : () async {
                  final ok = await confirm(
                    context,
                    'Reset this device from the server?',
                    'This device\'s tasks are replaced by what is on the server. Changes not yet sent are lost.',
                    action: 'Reset',
                  );
                  if (!ok || !context.mounted) return;
                  try {
                    await s.resetFromServer();
                    if (context.mounted) showMessage(context, 'Reset from the server');
                  } on SyncTransportException catch (e) {
                    if (context.mounted) showMessage(context, e.message);
                  }
                },
          icon: const Icon(Icons.cloud_download_outlined),
          label: const Text('Reset from server'),
        ),
        OutlinedButton.icon(
          onPressed: () async {
            final ok = await confirm(
              context,
              'Unpair this device?',
              'Your tasks stay on this device, but they stop syncing. You can pair again later with a new code.',
              action: 'Unpair',
            );
            if (ok) await s.unpair();
          },
          icon: const Icon(Icons.link_off),
          label: const Text('Unpair'),
        ),
      ]),
      if (s.scheduler != null) ...[
        const SizedBox(height: 8),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Sync while the app is closed'),
          subtitle: FutureBuilder<String?>(
            future: _lastBackground,
            builder: (context, snap) {
              final at = int.tryParse(snap.data ?? '');
              final last = at == null ? 'not yet' : _ago(DateTime.fromMillisecondsSinceEpoch(at));
              return Text('About every 15 minutes when there is a connection, so changes from your other devices and notifications for shared projects arrive without opening ToDoz. Last time: $last.');
            },
          ),
          value: s.backgroundSync,
          onChanged: (on) async {
            await s.setBackgroundSync(on);
            if (mounted) setState(() => _lastBackground = s.repo.getSetting(lastRunKey));
          },
        ),
      ],
      const SizedBox(height: 24),
      Row(children: [
        Expanded(child: Text('Your devices', style: Theme.of(context).textTheme.titleMedium)),
        IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: () => setState(() {
          _me = _load();
          _lastBackground = s.repo.getSetting(lastRunKey);
        })),
      ]),
      FutureBuilder<MeInfo>(
        future: _me,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) return const Padding(padding: EdgeInsets.all(16), child: LinearProgressIndicator());
          if (snap.hasError) {
            return Text(snap.error is SyncTransportException ? (snap.error as SyncTransportException).message : 'Could not load devices.', style: TextStyle(color: cs.error));
          }
          final devices = snap.data!.devices.where((d) => !d.revoked).toList();
          return Column(children: [
            for (final d in devices)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(d.current ? Icons.smartphone : Icons.devices_other_outlined),
                title: Text(d.name + (d.current ? ' (this device)' : '')),
                subtitle: Text('Last seen ${_ago(d.lastSeen)}'),
                trailing: d.current
                    ? null
                    : IconButton(
                        tooltip: 'Sign this device out',
                        icon: const Icon(Icons.logout),
                        onPressed: () async {
                          final ok = await confirm(context, 'Sign out ${d.name}?', 'It will stop syncing at once. Its tasks stay on it.', action: 'Sign out');
                          if (!ok) return;
                          try {
                            await s.revokeDevice(d.id);
                            setState(() {
          _me = _load();
        });
                          } on SyncTransportException catch (e) {
                            if (context.mounted) showMessage(context, e.message);
                          }
                        },
                      ),
              ),
          ]);
        },
      ),
      const SizedBox(height: 24),
      Text('Your data on the server', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 4),
      Text(_privacyNote, style: TextStyle(color: cs.outline, fontSize: 12)),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        style: OutlinedButton.styleFrom(foregroundColor: cs.error),
        onPressed: () => _deleteServerData(context),
        icon: const Icon(Icons.delete_forever_outlined),
        label: const Text('Delete my data on the server'),
      ),
    ]);
  }

  Future<void> _deleteServerData(BuildContext context) async {
    final s = widget.sync;
    final c = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setInner) => AlertDialog(
          title: const Text('Delete everything on the server?'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Your account, your tasks on the server and every paired device are deleted. Tasks on your devices stay, but stop syncing.'),
            const SizedBox(height: 12),
            TextField(controller: c, decoration: const InputDecoration(labelText: 'Type DELETE MY DATA'), onChanged: (_) => setInner(() {})),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: c.text.trim() == 'DELETE MY DATA' ? () => Navigator.pop(ctx, true) : null, child: const Text('Delete')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    try {
      await s.deleteServerData();
      if (context.mounted) showMessage(context, 'Your data on the server was deleted');
    } on SyncTransportException catch (e) {
      if (context.mounted) showMessage(context, e.message);
    }
  }
}
