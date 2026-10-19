import 'package:flutter/material.dart';

import 'package:taskflow_core/backup.dart' show inboxId;
import 'browse_screen.dart';
import 'calendar_view.dart';
import 'catalog.dart';
import 'sidebar.dart';
import 'views.dart';

/// The top-level layout. On a phone: Inbox, Today, Upcoming and Browse in a
/// bottom bar (FR-V1). On a tablet or desktop width: a permanent sidebar with
/// the content beside it (FR-V12).
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 1; // open on Today, as 1.0 did

  Catalog? _catalog;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final c = AppScope.of(context);
    if (_catalog != c) {
      _catalog?.navRequest.removeListener(_onNavRequest);
      _catalog = c..navRequest.addListener(_onNavRequest);
    }
  }

  @override
  void dispose() {
    _catalog?.navRequest.removeListener(_onNavRequest);
    super.dispose();
  }

  void _onNavRequest() {
    final r = _catalog?.navRequest.value;
    if (r == null) return;
    _catalog!.navRequest.value = null;
    if (r == 'today') {
      if (MediaQuery.of(context).size.width >= 840) {
        _navigate('today', (_) => const TodayScreen());
      } else {
        setState(() => _index = 1);
      }
    }
  }

  final _contentKey = GlobalKey<NavigatorState>();
  String _selected = 'today';

  static const _destinations = [
    (Icons.inbox_outlined, Icons.inbox, 'Inbox'),
    (Icons.today_outlined, Icons.today, 'Today'),
    (Icons.calendar_month_outlined, Icons.calendar_month, 'Upcoming'),
    (Icons.calendar_view_week_outlined, Icons.calendar_view_week, 'Calendar'),
    (Icons.grid_view_outlined, Icons.grid_view, 'Browse'),
  ];

  void _navigate(String key, WidgetBuilder builder) {
    setState(() => _selected = key);
    _contentKey.currentState?.pushAndRemoveUntil(MaterialPageRoute<void>(builder: builder), (route) => false);
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width >= 840;
    if (wide) {
      return Scaffold(
        body: Row(children: [
          SizedBox(width: 280, child: Sidebar(selectedKey: _selected, onNavigate: _navigate)),
          const VerticalDivider(width: 1),
          Expanded(
            child: Navigator(
              key: _contentKey,
              onGenerateInitialRoutes: (_, _) => [MaterialPageRoute<void>(builder: (_) => const TodayScreen())],
            ),
          ),
        ]),
      );
    }
    final pages = IndexedStack(index: _index, children: const [
      ProjectScreen(projectId: inboxId, isTab: true),
      TodayScreen(),
      UpcomingScreen(),
      CalendarScreen(),
      BrowseScreen(),
    ]);
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
