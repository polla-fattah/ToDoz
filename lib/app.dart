import 'package:flutter/material.dart';

import 'ui/catalog.dart';
import 'ui/home.dart';
import 'ui/lock_screen.dart';
import 'ui/progress_screen.dart';

class TaskFlowApp extends StatelessWidget {
  const TaskFlowApp({super.key, required this.catalog, this.navigatorKey});
  final Catalog catalog;

  /// Lets a tapped notification open a task from outside the widget tree.
  final GlobalKey<NavigatorState>? navigatorKey;

  static const _seed = Color(0xFF007AFF); // ToDoz electric blue

  ThemeData _theme(Brightness b) => ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: _seed, brightness: b),
      );

  @override
  Widget build(BuildContext context) => AppScope(
        catalog: catalog,
        child: Builder(
          builder: (context) {
            final c = AppScope.of(context);
            return MaterialApp(
              navigatorKey: navigatorKey,
              title: 'ToDoz',
              debugShowCheckedModeBanner: false,
              theme: _theme(Brightness.light),
              darkTheme: _theme(Brightness.dark),
              themeMode: c.themeMode,
              home: const HomeShell(),
              builder: (context, child) => CelebrationHost(
                catalog: c,
                child: LockGate(lock: c.lock, child: child ?? const SizedBox()),
              ),
            );
          },
        ),
      );
}
