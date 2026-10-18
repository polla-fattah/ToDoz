import 'package:flutter/material.dart';

import 'ui/catalog.dart';
import 'ui/home.dart';

class TaskFlowApp extends StatelessWidget {
  const TaskFlowApp({super.key, required this.catalog, this.navigatorKey});
  final Catalog catalog;

  /// Lets a tapped notification open a task from outside the widget tree.
  final GlobalKey<NavigatorState>? navigatorKey;

  static const _seed = Color(0xFFCF5147); // 1.0's red

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
              title: 'TaskFlow',
              debugShowCheckedModeBanner: false,
              theme: _theme(Brightness.light),
              darkTheme: _theme(Brightness.dark),
              themeMode: c.themeMode,
              home: const HomeShell(),
            );
          },
        ),
      );
}
