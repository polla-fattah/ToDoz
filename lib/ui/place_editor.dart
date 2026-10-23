import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:taskflow_core/location.dart';

import '../data/database.dart';
import 'catalog.dart';
import 'common.dart';

/// Opens the editor for a new place, or for [place]. Returns the saved place's id, or null when cancelled.
Future<String?> showPlaceEditor(BuildContext context, {Place? place}) =>
    Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => PlaceEditorPage(place: place)));

/// Where a place is and how close counts as being there: tap the map, use the current location, or type the
/// coordinates. The map is OpenStreetMap, loaded from the internet only while this page is open.
class PlaceEditorPage extends StatefulWidget {
  const PlaceEditorPage({super.key, this.place});

  final Place? place;

  /// Tests switch the map off (it needs the internet); the coordinate fields still work.
  static bool showMap = true;

  @override
  State<PlaceEditorPage> createState() => _PlaceEditorPageState();
}

class _PlaceEditorPageState extends State<PlaceEditorPage> {
  final _name = TextEditingController();
  final _lat = TextEditingController();
  final _lon = TextEditingController();
  final _map = MapController();
  LatLng? _point;
  double _radius = defaultRadiusMeters.toDouble();
  bool _locating = false;
  bool _mapReady = false;

  @override
  void initState() {
    super.initState();
    final p = widget.place;
    if (p != null) {
      _name.text = p.name;
      _radius = p.radiusMeters.toDouble().clamp(minRadiusMeters.toDouble(), 1000);
      _setPoint(LatLng(p.latitude, p.longitude), move: false, fields: true);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _lat.dispose();
    _lon.dispose();
    _map.dispose();
    super.dispose();
  }

  void _setPoint(LatLng point, {bool move = false, bool fields = true}) {
    setState(() {
      _point = point;
      if (fields) {
        _lat.text = point.latitude.toStringAsFixed(6);
        _lon.text = point.longitude.toStringAsFixed(6);
      }
    });
    if (move && _mapReady) _map.move(point, _map.camera.zoom < 15 ? 16 : _map.camera.zoom);
  }

  /// The typed coordinates, when they are a real point on the map.
  void _typed() {
    final lat = double.tryParse(_lat.text.trim().replaceAll(',', '.'));
    final lon = double.tryParse(_lon.text.trim().replaceAll(',', '.'));
    if (lat != null && lon != null && validCoordinates(lat, lon)) {
      setState(() => _point = LatLng(lat, lon));
      if (_mapReady) _map.move(LatLng(lat, lon), _map.camera.zoom < 15 ? 16 : _map.camera.zoom);
    }
  }

  Future<void> _useCurrent() async {
    setState(() => _locating = true);
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        if (mounted) showMessage(context, 'Turn on location on this device first.');
        return;
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        if (mounted) showMessage(context, 'Location access was not allowed. You can tap the map or type the coordinates instead.');
        return;
      }
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 20)),
      );
      _setPoint(LatLng(position.latitude, position.longitude), move: true);
    } catch (e) {
      if (mounted) showMessage(context, 'Could not find where you are. Tap the map or type the coordinates instead.');
    } finally {
      if (mounted) setState(() => _locating = false);
    }
  }

  Future<void> _save() async {
    final repo = AppScope.repoOf(context);
    final point = _point;
    if (point == null) {
      showMessage(context, 'Choose where the place is: tap the map, use your location, or type the coordinates.');
      return;
    }
    final existing = widget.place;
    String? id = existing?.id;
    var saved = false;
    await guarded(context, () async {
      if (existing == null) {
        id = await repo.createPlace(name: _name.text, latitude: point.latitude, longitude: point.longitude, radiusMeters: _radius.round());
      } else {
        await repo.updatePlace(existing.id, name: _name.text, latitude: point.latitude, longitude: point.longitude, radiusMeters: _radius.round());
      }
      saved = true; // a rule that refuses it (no name) throws before this, and guarded shows why
    });
    if (mounted && saved) Navigator.of(context).pop(id);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final editing = widget.place != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(editing ? 'Edit place' : 'New place'),
        actions: [TextButton(onPressed: _save, child: const Text('Save'))],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          TextField(
            controller: _name,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(labelText: 'Name', hintText: 'Work, Home, Supermarket'),
          ),
          const SizedBox(height: 16),
          if (PlaceEditorPage.showMap)
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                height: 320,
                child: FlutterMap(
                  mapController: _map,
                  options: MapOptions(
                    initialCenter: _point ?? const LatLng(30, 20),
                    initialZoom: _point == null ? 2.5 : 16,
                    interactionOptions: const InteractionOptions(flags: InteractiveFlag.all & ~InteractiveFlag.rotate),
                    onMapReady: () => _mapReady = true,
                    onTap: (_, p) => _setPoint(p),
                  ),
                  children: [
                    TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: 'com.taskflow.taskflow'),
                    if (_point != null)
                      CircleLayer(circles: [
                        CircleMarker(
                          point: _point!,
                          radius: _radius,
                          useRadiusInMeter: true,
                          color: cs.primary.withValues(alpha: 0.2),
                          borderColor: cs.primary,
                          borderStrokeWidth: 2,
                        ),
                      ]),
                    if (_point != null)
                      MarkerLayer(markers: [
                        Marker(point: _point!, width: 44, height: 44, alignment: Alignment.topCenter, child: Icon(Icons.location_on, size: 44, color: cs.primary)),
                      ]),
                    const SimpleAttributionWidget(source: Text('OpenStreetMap contributors')),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: _locating ? null : _useCurrent,
              icon: _locating ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.my_location),
              label: const Text('Use my current location'),
            ),
          ),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: TextField(
                controller: _lat,
                onChanged: (_) => _typed(),
                keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                decoration: const InputDecoration(labelText: 'Latitude'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _lon,
                onChanged: (_) => _typed(),
                keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
                decoration: const InputDecoration(labelText: 'Longitude'),
              ),
            ),
          ]),
          const SizedBox(height: 20),
          Text('How close counts as being there: ${_radius.round()} m', style: Theme.of(context).textTheme.titleSmall),
          Slider(
            min: minRadiusMeters.toDouble(),
            max: 1000,
            divisions: (1000 - minRadiusMeters) ~/ 50,
            value: _radius.clamp(minRadiusMeters.toDouble(), 1000),
            label: '${_radius.round()} m',
            onChanged: (v) => setState(() => _radius = v),
          ),
          Text(
            'Phones tell a place from its surroundings only roughly, so a radius under about 150 m can be missed. '
            'Pick the middle of the building or car park, not the street.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.outline),
          ),
        ],
      ),
    );
  }
}
