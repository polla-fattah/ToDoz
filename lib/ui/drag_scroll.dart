import 'dart:async';

import 'package:flutter/material.dart';

/// Whether a task is being dragged right now. Flutter does not scroll a list by itself while something
/// is dragged over it, so [DragEdgeScroll] watches this and scrolls when the finger nears an edge.
class TaskDrag {
  TaskDrag._();
  static final ValueNotifier<bool> active = ValueNotifier(false);
}

/// Scrolls [controller] while a task is being dragged close to the edge of this area (so a task can be
/// carried to a section or column that is off screen).
class DragEdgeScroll extends StatefulWidget {
  const DragEdgeScroll({super.key, required this.controller, required this.child, this.axis = Axis.vertical, this.edge = 72, this.speed = 9});

  final ScrollController controller;
  final Widget child;
  final Axis axis;

  /// How close to an edge (in logical pixels) the finger must be.
  final double edge;

  /// Pixels per tick (every 16 ms) at the very edge.
  final double speed;

  @override
  State<DragEdgeScroll> createState() => _DragEdgeScrollState();
}

class _DragEdgeScrollState extends State<DragEdgeScroll> {
  Timer? _timer;
  double _velocity = 0;

  @override
  void initState() {
    super.initState();
    TaskDrag.active.addListener(_onActive);
  }

  @override
  void dispose() {
    TaskDrag.active.removeListener(_onActive);
    _timer?.cancel();
    super.dispose();
  }

  void _onActive() {
    if (!TaskDrag.active.value) _stop();
  }

  void _stop() {
    _velocity = 0;
    _timer?.cancel();
    _timer = null;
  }

  void _move(PointerEvent e) {
    if (!TaskDrag.active.value) {
      if (_timer != null) _stop();
      return;
    }
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    final local = box.globalToLocal(e.position);
    final pos = widget.axis == Axis.vertical ? local.dy : local.dx;
    final size = widget.axis == Axis.vertical ? box.size.height : box.size.width;
    final edge = widget.edge.clamp(0, size / 3).toDouble();
    double v = 0;
    if (pos < edge) {
      v = -widget.speed * ((edge - pos) / edge).clamp(0.2, 1.5);
    } else if (pos > size - edge) {
      v = widget.speed * ((pos - (size - edge)) / edge).clamp(0.2, 1.5);
    }
    _velocity = v;
    if (v == 0) {
      _timer?.cancel();
      _timer = null;
    } else {
      _timer ??= Timer.periodic(const Duration(milliseconds: 16), (_) => _tick());
    }
  }

  void _tick() {
    final c = widget.controller;
    if (!c.hasClients || _velocity == 0 || !TaskDrag.active.value) {
      _stop();
      return;
    }
    final p = c.position;
    final next = (p.pixels + _velocity).clamp(p.minScrollExtent, p.maxScrollExtent).toDouble();
    if (next != p.pixels) p.jumpTo(next);
  }

  @override
  Widget build(BuildContext context) => Listener(
        behavior: HitTestBehavior.translucent,
        onPointerMove: _move,
        onPointerUp: (_) => _stop(),
        onPointerCancel: (_) => _stop(),
        child: widget.child,
      );
}
