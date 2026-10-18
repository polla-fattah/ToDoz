import 'package:flutter/material.dart';

import '../core/backup.dart' show inboxId;
import 'browse_screen.dart';
import 'views.dart';

/// The four top-level destinations (FR-V1): Inbox, Today, Upcoming, Browse.
/// A bottom bar on phones, a side rail on wide windows.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 1; // open on Today, as 1.0 did

  static const _destinations = [
    (Icons.inbox_outlined, Icons.inbox, 'Inbox'),
    (Icons.today_outlined, Icons.today, 'Today'),
    (Icons.calendar_month_outlined, Icons.calendar_month, 'Upcoming'),
    (Icons.grid_view_outlined, Icons.grid_view, 'Browse'),
  ];

  @override
  Widget build(BuildContext context) {
    final pages = IndexedStack(index: _index, children: const [
      ProjectScreen(projectId: inboxId, isTab: true),
      TodayScreen(),
      UpcomingScreen(),
      BrowseScreen(),
    ]);
    final wide = MediaQuery.of(context).size.width >= 720;
    if (wide) {
      return Scaffold(
        body: Row(children: [
          NavigationRail(
            selectedIndex: _index,
            labelType: NavigationRailLabelType.all,
            onDestinationSelected: (i) => setState(() => _index = i),
            destinations: [
              for (final d in _destinations)
                NavigationRailDestination(icon: Icon(d.$1), selectedIcon: Icon(d.$2), label: Text(d.$3)),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: pages),
        ]),
      );
    }
    return Scaffold(
      body: pages,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          for (final d in _destinations) NavigationDestination(icon: Icon(d.$1), selectedIcon: Icon(d.$2), label: d.$3),
        ],
      ),
    );
  }
}
