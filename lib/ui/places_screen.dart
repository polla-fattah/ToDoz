import 'package:flutter/material.dart';
import 'package:taskflow_geofence/taskflow_geofence.dart';

import '../data/database.dart';
import '../platform/geofence_service.dart';
import 'catalog.dart';
import 'common.dart';
import 'place_editor.dart';

/// The saved places that location reminders refer to ("Work", "Home"), and whether the phone is set up to
/// tell you when you get there.
class PlacesScreen extends StatelessWidget {
  const PlacesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final repo = AppScope.repoOf(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Places')),
      floatingActionButton: FloatingActionButton.extended(
        heroTag: null,
        onPressed: () => showPlaceEditor(context),
        icon: const Icon(Icons.add_location_alt_outlined),
        label: const Text('Add place'),
      ),
      body: Live<List<Place>>(
        create: repo.watchPlaces,
        builder: (context, places) => Live<Map<String, int>>(
          create: repo.watchPlaceUsage,
          builder: (context, usage) {
            final list = places ?? const <Place>[];
            return ListView(padding: const EdgeInsets.only(bottom: 96), children: [
              const _SetupTile(),
              if (list.isEmpty)
                const Padding(
                  padding: EdgeInsets.fromLTRB(24, 32, 24, 0),
                  child: Text(
                    'No places yet. Add a place such as Work or Home, then give a task a location reminder: '
                    '"when I arrive at Work, talk to Sam".',
                    textAlign: TextAlign.center,
                  ),
                ),
              for (final p in list)
                ListTile(
                  leading: const Icon(Icons.place_outlined),
                  title: Text(p.name),
                  subtitle: Text('${p.radiusMeters} m · ${_uses(usage?[p.id] ?? 0)}'),
                  onTap: () => showPlaceEditor(context, place: p),
                  trailing: PopupMenuButton<String>(
                    tooltip: 'More',
                    onSelected: (v) async {
                      if (v == 'edit') {
                        await showPlaceEditor(context, place: p);
                      } else if (v == 'test') {
                        await _test(context, p);
                      } else if (v == 'delete') {
                        await _delete(context, p, usage?[p.id] ?? 0);
                      }
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(value: 'edit', child: Text('Edit')),
                      if (GeofenceService.supported) const PopupMenuItem(value: 'test', child: Text('Send a test reminder')),
                      const PopupMenuItem(value: 'delete', child: Text('Delete')),
                    ],
                  ),
                ),
            ]);
          },
        ),
      ),
    );
  }

  /// Shows the notification you would get on arriving at the place, to check notifications work.
  Future<void> _test(BuildContext context, Place p) async {
    final service = AppScope.of(context).geofence;
    if (service == null) return;
    final shown = await service.testReminder(p.id, 'arrive');
    if (!context.mounted) return;
    showMessage(
        context,
        shown > 0
            ? 'Sent. Look at your notifications: this is what you will see when you arrive at ${p.name}.'
            : 'Nothing to show: no open task has an "arrive" reminder at ${p.name} (or notifications are off).');
  }

  static String _uses(int n) => n == 0 ? 'no open tasks' : '$n open task${n == 1 ? '' : 's'}';

  Future<void> _delete(BuildContext context, Place p, int uses) async {
    final repo = AppScope.repoOf(context);
    final body = uses == 0
        ? 'The place is removed.'
        : '$uses open task${uses == 1 ? '' : 's'} will keep ${uses == 1 ? 'its' : 'their'} other details but lose the reminder at this place.';
    if (!await confirm(context, 'Delete "${p.name}"?', body)) return;
    if (!context.mounted) return;
    await guarded(context, () => repo.deletePlace(p.id));
  }
}

/// Says whether location reminders can work on this device and, on Android, asks for what is missing.
class _SetupTile extends StatefulWidget {
  const _SetupTile();

  @override
  State<_SetupTile> createState() => _SetupTileState();
}

class _SetupTileState extends State<_SetupTile> with WidgetsBindingObserver {
  GeofenceStatus? _status;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh(); // back from the phone's settings page
  }

  Future<void> _refresh() async {
    final s = await TaskflowGeofence.status();
    if (mounted) setState(() => _status = s);
  }

  @override
  Widget build(BuildContext context) {
    if (!GeofenceService.supported) {
      return const ListTile(
        leading: Icon(Icons.info_outline),
        title: Text('Location reminders fire on your Android phone'),
        subtitle: Text('You can still save places and give tasks location reminders here; they sync to your phone.'),
      );
    }
    final s = _status;
    if (s == null) return const ListTile(leading: Icon(Icons.hourglass_empty), title: Text('Checking…'));
    final problem = geofenceProblem(s);
    final ok = problem == null;
    return ListTile(
      leading: Icon(ok ? Icons.check_circle_outline : Icons.warning_amber_rounded, color: ok ? Colors.green : Colors.orange),
      title: Text(ok ? 'Location reminders are ready' : 'Location reminders need permission'),
      subtitle: Text(ok ? 'Watching ${s.watching} place${s.watching == 1 ? '' : 's'}. They work while ToDoz is closed.' : problem),
      trailing: ok || !s.playServices ? null : const Icon(Icons.chevron_right),
      onTap: ok || !s.playServices
          ? null
          : () async {
              final service = AppScope.of(context).geofence;
              if (service != null) await service.requestPermissions();
              await _refresh();
            },
    );
  }
}
