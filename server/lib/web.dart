/// NoteDo for the web: a React page the server itself serves at `/app`. It is an online-only client of the REST
/// API (`/api/v1/...`): nothing but the sign-in token is kept in the browser, and every change is written to the
/// server at once. Sign-in swaps a one-time pairing code for an API token (`POST /web/login`).
///
/// The page is built from `web/` and embedded by `tool/embed_web.py` (see web_assets.dart), so the compiled
/// server has no files to ship alongside it.
library;

import 'dart:convert';

import 'package:shelf/shelf.dart';

import 'web_assets.dart';

/// Only this site's own files may run or load; no framing. (The page puts nothing from your tasks in as HTML.)
const webContentSecurityPolicy =
    "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; font-src 'self'; img-src 'self' data:; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'";

final _decoded = <String, List<int>>{};

List<int> _bytes(String path) => _decoded.putIfAbsent(path, () => base64.decode(webAssets[path]!.data));

/// The page itself: `/app`.
Response webIndexResponse() => Response.ok(
      _bytes('index.html'),
      headers: {
        'content-type': webAssets['index.html']!.type,
        'cache-control': 'no-store',
        'content-security-policy': webContentSecurityPolicy,
        'x-frame-options': 'DENY',
      },
    );

/// A file of the page: `/app/assets/<name>`. Their names carry a hash of their content, so they can be kept forever.
Response webAssetResponse(String name) {
  final path = 'assets/$name';
  if (!webAssets.containsKey(path)) return Response.notFound('Not found');
  return Response.ok(
    _bytes(path),
    headers: {
      'content-type': webAssets[path]!.type,
      'cache-control': 'public, max-age=31536000, immutable',
      'content-security-policy': webContentSecurityPolicy,
    },
  );
}
