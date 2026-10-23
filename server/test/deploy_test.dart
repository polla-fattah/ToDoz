import 'dart:io';

import 'package:test/test.dart';

/// The Docker deployment puts Caddy in front of the server and sends only the paths it lists to the server; anything
/// else is answered by the landing page. A path the server answers but Caddy does not list silently breaks on the
/// live site (the web app's `/api/...` calls came back as "405 Method Not Allowed" once), so this keeps them in step.
void main() {
  test('every top-level path the server answers is passed on by the Docker Caddyfile', () {
    final routes = RegExp(r"router\.(?:get|post|put|delete)\('(/[A-Za-z0-9_-]+)");
    final served = <String>{};
    for (final file in ['lib/api.dart', 'lib/rest.dart', 'lib/mcp.dart']) {
      for (final m in routes.allMatches(File(file).readAsStringSync())) {
        served.add(m.group(1)!);
      }
    }
    expect(served, containsAll(['/api', '/app', '/v1', '/web', '/hooks', '/ical', '/google', '/health', '/mcp']), reason: 'the scan found the routes');

    final caddy = File('deploy/Caddyfile').readAsStringSync();
    final passed = {for (final m in RegExp(r'^\s*handle\s+(/[A-Za-z0-9_-]+)', multiLine: true).allMatches(caddy)) m.group(1)!};
    final missing = served.difference(passed);
    expect(missing, isEmpty, reason: 'add a `handle $missing/*` block that reverse_proxies to taskflow:8080 in deploy/Caddyfile');
  });

  test('the Caddyfile for the no-Docker install passes everything on', () {
    final caddy = File('deploy/Caddyfile.host').readAsStringSync();
    expect(RegExp(r'^\s*handle\s*\{', multiLine: true).hasMatch(caddy), isTrue, reason: 'a catch-all handle that proxies to the server');
  });
}
