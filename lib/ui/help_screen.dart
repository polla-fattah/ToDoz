import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:taskflow_core/filter.dart';

/// The Quick Add, repeat, filter, calendar sync and self-hosting syntax in one place (FR-U5).
class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final mono = const TextStyle(fontFamily: 'monospace', fontSize: 13);
    final cs = Theme.of(context).colorScheme;

    Widget heading(String t) => Padding(
          padding: const EdgeInsets.fromLTRB(0, 24, 0, 8),
          child: Text(t, style: Theme.of(context).textTheme.titleMedium?.copyWith(color: cs.primary)),
        );

    Widget row(String code, String what) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 170, child: SelectableText(code, style: mono)),
            Expanded(child: Text(what)),
          ]),
        );

    Widget sectionTitle(String title, IconData icon) => Padding(
          padding: const EdgeInsets.only(top: 28, bottom: 4),
          child: Row(children: [
            Icon(icon, size: 22, color: cs.primary),
            const SizedBox(width: 8),
            Text(title, style: Theme.of(context).textTheme.titleLarge),
          ]),
        );

    return Scaffold(
      appBar: AppBar(title: const Text('Help & Documentation')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        sectionTitle('Quick Add', Icons.bolt),
        const Text('Type one line; recognised words are highlighted and removed from the title.'),
        heading('Dates and times'),
        row('tomorrow, next week', 'Dates. "next week" is the start of next week.'),
        row('mon, next fri', 'The next Monday; Friday of next week.'),
        row('in 3 days, 2 weeks from now', 'Relative dates.'),
        row('jan 5, 5 jan, end of month', 'Calendar dates.'),
        row('at 4pm, 16:30, noon', 'A time of day.'),
        heading('Repeats'),
        row('every day, every weekday', 'Daily, Monday to Friday.'),
        row('every other week', 'Every 2 weeks. Also: every 3 days, every 2 months, every quarter.'),
        row('every mon, fri at 8pm', 'Several weekdays, one time.'),
        row('every 2, 15, 27', 'Days of the month.'),
        row('every 1st wed, every last fri', 'A weekday of the month.'),
        row('every last workday', 'Also: every 15th workday.'),
        row('every 12 hours starting at 9pm', 'Hourly repeats.'),
        row('every day until oct 30', 'Also: for 3 weeks, starting aug 3, from may 10 until may 20.'),
        row('every! 2 months, after 10 days', 'Counted from the day you finish it.'),
        heading('Everything else'),
        row('p1 p2 p3 p4', 'Priority (p1 is urgent).'),
        row('%label  @label', 'A label.'),
        row('#project  #"Two words"', 'A project. Then /section for a section.'),
        row('{march 30}', 'A deadline, separate from the due date.'),
        row('!30 min before, !14:00', 'A reminder.'),

        sectionTitle('Filters', Icons.filter_list),
        const Text('Save a query as its own view (Browse, Filters). Combine conditions with operators.'),
        heading('Operators'),
        row('today & p1', 'and'),
        row('today | overdue', 'or'),
        row('!subtask', 'not'),
        row('(today | overdue) & #Work', 'brackets'),
        row('p1 & overdue, p4 & today', 'a comma starts a separate list in the same view'),
        row(r'#Shopping\ list  or  #"Shopping list"', 'names with spaces'),
        row('%home*', '* matches any characters'),
        heading('Where'),
        row('#Project', 'In a project.'),
        row('##Project', 'In a project or its sub-projects.'),
        row('%label  @label', 'With a label.'),
        row('/Section   /*', 'In a section; in no section.'),
        heading('When'),
        row('today, tomorrow, overdue', 'Due then. Overdue counts a time that has passed.'),
        row('7 days, next 7 days', 'Due in the next 7 days, plus overdue.'),
        row('no date, no time', 'Nothing planned.'),
        row('recurring', 'Repeating tasks.'),
        row('due before: next monday', 'Also: due after:, date before:, date after:.'),
        row('created: today', 'Also: created before:, created after:, "3 days ago".'),
        row('no deadline', 'Also: deadline before:, deadline after:.'),
        heading('About the task'),
        row('p1 ... p4, no priority', 'Priority.'),
        row('subtask', 'A sub-task.'),
        row('no labels', 'Has no label.'),
        row('search: invoice', 'Words in the title, description, label, project or section.'),
        row('view all', 'Every open task.'),
        heading('Examples'),
        for (final (q, what) in filterExamples) row(q, what),

        sectionTitle('Google Calendar Sync', Icons.calendar_month),
        const Text('Synchronise your dated tasks with Google Calendar in two ways:'),
        heading('Method 1: Live iCal Feed (Instant)'),
        const Text('1. Go to Settings > Calendar and integrations > Calendar feed (iCal).\n'
            '2. Turn it on and copy your private link (https://todoz.polla.dev/ical/...ics).\n'
            '3. Open Google Calendar on the web > Other calendars (+) > From URL.\n'
            '4. Paste the URL and click Add calendar. All your dated tasks show up on phone and web.'),
        heading('Method 2: Two-Way Google OAuth Sync'),
        const Text('1. In your self-hosted server, configure GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET in server/deploy/.env.\n'
            '2. Set redirect URI in Google Cloud Console to https://yourdomain.com/google/callback.\n'
            '3. In ToDoz: Settings > Calendar and integrations > Google Calendar > Connect.\n'
            '4. A dedicated "ToDoz" calendar is created in your Google account and syncs changes two-way.'),

        sectionTitle('Self-Hosting Your Server', Icons.dns),
        const Text('ToDoz is sovereign and offline-first. To host your own synchronization server:'),
        heading('Docker Setup'),
        SelectableText(
          'git clone https://github.com/polla-fattah/ToDoz.git /opt/todoz\n'
          'cd /opt/todoz/server/deploy\n'
          '# Set TASKFLOW_DOMAIN=yourdomain.com in .env\n'
          'docker compose --profile public up -d --build\n\n'
          '# Add a user and generate a 1-time pairing code:\n'
          'docker compose exec taskflow taskflow_server user add "YourName"\n'
          'docker compose exec taskflow taskflow_server invite "YourName"',
          style: mono,
        ),
        const SizedBox(height: 12),
        const Text('Then in ToDoz: Settings > Sync > enter your server address and the 1-time code.'),

        const SizedBox(height: 28),
        Card(
          color: cs.surfaceContainerHighest,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Online User Guide & Community', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              const Text('Read full tutorials, deployment architecture, and updates on the official website:'),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text('Open Online Manual (todoz.polla.dev/help)'),
                onPressed: () => launchUrl(Uri.parse('https://todoz.polla.dev/help'), mode: LaunchMode.externalApplication),
              ),
            ]),
          ),
        ),
        const SizedBox(height: 24),
      ]),
    );
  }
}

