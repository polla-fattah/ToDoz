// A fake ToDoz server for the tests: the same routes, status codes and error bodies as server/lib/rest.dart,
// with a few fixed projects and tasks. It records every request so tests can check what was sent.

import { createServer } from 'node:http';

export const TOKEN = 'tf_' + 'a'.repeat(32);
export const READ_ONLY_TOKEN = 'tf_' + 'r'.repeat(32);
export const LIMITED_TOKEN = 'tf_' + 'l'.repeat(32);

const projects = [
  { id: 'inbox', name: 'Inbox', is_inbox: true, is_archived: false, parent_id: null },
  { id: 'p-home', name: 'Home', is_inbox: false, is_archived: false, parent_id: null },
  { id: 'p-old', name: 'Old stuff', is_inbox: false, is_archived: true, parent_id: null },
  { id: 'p-work1', name: 'Work', is_inbox: false, is_archived: false, parent_id: null },
  { id: 'p-work2', name: 'work', is_inbox: false, is_archived: false, parent_id: null },
];

const task = (id, title, extra = {}) => ({
  id, title, content: title, description: '', project_id: 'inbox', section_id: null, parent_id: null, priority: 4,
  labels: [], due: null, deadline: null, is_completed: false, ...extra,
});

export async function startFakeTodoz() {
  const requests = [];
  let nextId = 1;
  const tasks = [
    task('t1', 'Buy milk', { project_id: 'p-home', due: { date: '2026-10-23', time: null, recurrence: null }, labels: ['errands'] }),
    task('t2', 'Write report', { project_id: 'p-work1', priority: 1 }),
  ];

  const send = (res, status, body, headers = {}) => {
    res.writeHead(status, { 'content-type': 'application/json', ...headers });
    res.end(body === undefined ? '' : JSON.stringify(body));
  };

  const server = createServer(async (req, res) => {
    const url = new URL(req.url, 'http://x');
    const raw = await new Promise((resolve) => {
      let data = '';
      req.on('data', (c) => (data += c));
      req.on('end', () => resolve(data));
    });
    const body = raw ? JSON.parse(raw) : {};
    requests.push({ method: req.method, path: url.pathname, query: Object.fromEntries(url.searchParams), body, auth: req.headers.authorization });

    const bearer = (req.headers.authorization ?? '').replace(/^Bearer /, '');
    if (![TOKEN, READ_ONLY_TOKEN, LIMITED_TOKEN].includes(bearer)) return send(res, 401, { error: 'unauthorized', message: 'Send an API token: Authorization: Bearer tf_...' });
    if (bearer === LIMITED_TOKEN) return send(res, 429, { error: 'slow_down', message: 'Too many requests' }, { 'retry-after': '30' });
    const write = req.method !== 'GET' && url.pathname !== '/api/v1/quick-add/parse';
    if (write && bearer === READ_ONLY_TOKEN) return send(res, 403, { error: 'read_only', message: 'This token can only read' });

    const route = `${req.method} ${url.pathname}`;
    if (route === 'GET /api/v1/projects') return send(res, 200, { projects });
    if (route === 'GET /api/v1/tasks') {
      const q = url.searchParams;
      const list = tasks.filter((t) =>
        (!q.get('project_id') || t.project_id === q.get('project_id')) &&
        (!q.get('due_date') || t.due?.date === q.get('due_date')) &&
        (!q.get('label') || t.labels.includes(q.get('label'))));
      return send(res, 200, { tasks: list });
    }
    if (route === 'POST /api/v1/quick-add' || route === 'POST /api/v1/quick-add/parse') {
      if (typeof body.text !== 'string' || !body.text.trim()) return send(res, 400, { error: 'bad_request', message: 'Send {"text": "Buy milk tomorrow p1"}' });
      if (body.project_id && !projects.some((p) => p.id === body.project_id)) return send(res, 404, { error: 'not_found', message: 'The project does not exist' });
      if (route.endsWith('/parse')) {
        return send(res, 200, { title: body.text, priority: null, due: null, labels: [], project: { id: body.project_id ?? 'inbox', name: 'Inbox', typed: null, known: true }, tokens: [{ kind: 'priority', start: 0, end: 2 }] });
      }
      const created = task(`n${nextId++}`, body.text, { project_id: body.project_id ?? 'inbox' });
      tasks.push(created);
      return send(res, 201, created);
    }
    const close = /^\/api\/v1\/tasks\/([^/]+)\/close$/.exec(url.pathname);
    if (req.method === 'POST' && close) {
      const t = tasks.find((x) => x.id === decodeURIComponent(close[1]));
      if (!t) return send(res, 404, { error: 'not_found', message: 'No such task' });
      t.is_completed = true;
      return send(res, 200, t);
    }
    return send(res, 404, { error: 'not_found', message: 'No such route' });
  });

  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  return {
    url: `http://127.0.0.1:${server.address().port}`,
    requests,
    close: () => new Promise((resolve) => { server.closeAllConnections?.(); server.close(resolve); }),
  };
}
