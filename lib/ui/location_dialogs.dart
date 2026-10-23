import 'package:flutter/material.dart';
import 'package:taskflow_core/location.dart';

import '../data/database.dart';
import '../platform/geofence_service.dart';
import 'catalog.dart';
import 'common.dart';
import 'place_editor.dart';

/// Adds a location reminder to a task: choose "when I arrive" or "when I leave", then a place (or make a new one).
/// On Android it also asks for the location access the reminder needs, the first time.
Future<void> addLocationReminder(BuildContext context, String taskId) async {
  final repo = AppScope.repoOf(context);
  final catalog = AppScope.of(context);
  final choice = await showModalBottomSheet<({LocationTrigger trigger, String? placeId})>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _PlaceChooser(places: catalog.places),
  );
  if (choice == null || !context.mounted) return;
  var placeId = choice.placeId;
  placeId ??= await showPlaceEditor(context);
  if (placeId == null || !context.mounted) return;
  final id = placeId;
  await guarded(context, () => repo.addLocationReminder(taskId, id, choice.trigger));
  if (!context.mounted) return;

  // The reminder only fires if the phone is allowed to watch the place while the app is closed.
  final service = catalog.geofence;
  if (service == null) return;
  var status = await service.status();
  if (geofenceProblem(status) != null && status.playServices) status = await service.requestPermissions();
  final problem = geofenceProblem(status);
  if (problem != null && context.mounted) showMessage(context, problem);
}

class _PlaceChooser extends StatefulWidget {
  const _PlaceChooser({required this.places});
  final List<Place> places;

  @override
  State<_PlaceChooser> createState() => _PlaceChooserState();
}

class _PlaceChooserState extends State<_PlaceChooser> {
  LocationTrigger _trigger = LocationTrigger.arrive;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.7),
        child: ListView(shrinkWrap: true, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: SegmentedButton<LocationTrigger>(
              showSelectedIcon: false,
              segments: [for (final t in LocationTrigger.values) ButtonSegment(value: t, label: Text(t.label))],
              selected: {_trigger},
              onSelectionChanged: (s) => setState(() => _trigger = s.first),
            ),
          ),
          for (final p in widget.places)
            ListTile(
              leading: const Icon(Icons.place_outlined),
              title: Text(p.name),
              onTap: () => Navigator.of(context).pop((trigger: _trigger, placeId: p.id)),
            ),
          ListTile(
            leading: const Icon(Icons.add_location_alt_outlined),
            title: const Text('New place…'),
            onTap: () => Navigator.of(context).pop((trigger: _trigger, placeId: null)),
          ),
        ]),
      ),
    );
  }
}
