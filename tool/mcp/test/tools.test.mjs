import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { createClient, createTools, loadConfig, localNow } from '../lib/todoz.mjs';
import { LIMITED_TOKEN, READ_ONLY_TOKEN, TOKEN, startFakeTodoz } from './fake_todoz.mjs';

let fake;
before(async () => { fake = await startFakeTodoz(); });
after(() => fake.close());

const fixedNow = () => new Date(2026, 9, 23, 14, 5); // 23 Oct 2026, 14:05 local
const toolsFor = (token) => {
  const client = createClient(loadConfig({ TODOZ_URL: fake.url, TODOZ_TOKEN: token }));
  const tools = createTools(() => client, fixedNow);
  return Object.fromEntries(tools.map((t) => [t.name, t.handler]));
};
const lastRequest = () => fake.requests.at(-1);

test('exposes the five tools', () => {
  const names = createTools(() => { throw new Error('unused'); }).map((t) => t.name).sort();
  assert.deepEqual(names, ['add_task', 'complete_task', 'list_projects', 'list_tasks', 'parse_preview']);
});

test('localNow formats the local date and time', () => {
  assert.equal(localNow(fixedNow()), '2026-10-23T14:05');
});

test('add_task sends the line, the user\'s local time and the bearer token', async () => {
  const out = JSON.parse(await toolsFor(TOKEN).add_task({ text: 'Pay rent tomorrow p1' }));
  const req = lastRequest();
  assert.equal(req.method, 'POST');
  assert.equal(req.path, '/api/v1/quick-add');
  assert.equal(req.auth, `Bearer ${TOKEN}`);
  assert.deepEqual(req.body, { text: 'Pay rent tomorrow p1', today: '2026-10-23T14:05' });
  assert.equal(out.created.title, 'Pay rent tomorrow p1');
  assert.ok(out.created.id);
});

test('add_task resolves a project by name, ignoring case, and by id', async () => {
  await toolsFor(TOKEN).add_task({ text: 'Fix tap', project: 'home' });
  assert.equal(lastRequest().body.project_id, 'p-home');
  await toolsFor(TOKEN).add_task({ text: 'Fix door', project: 'p-home' });
  assert.equal(lastRequest().body.project_id, 'p-home');
});

test('add_task explains an unknown or ambiguous project and does not create anything', async () => {
  const before = fake.requests.length;
  await assert.rejects(toolsFor(TOKEN).add_task({ text: 'x', project: 'Nope' }), /No project called "Nope".*Home/);
  await assert.rejects(toolsFor(TOKEN).add_task({ text: 'x', project: 'Work' }), /More than one project/);
  await assert.rejects(toolsFor(TOKEN).add_task({ text: 'x', project: 'Old stuff' }), /No project called/); // archived
  assert.ok(fake.requests.slice(before).every((r) => r.method === 'GET'));
});

test('add_task passes on the server\'s complaint about an empty line', async () => {
  await assert.rejects(toolsFor(TOKEN).add_task({ text: '   ' }), /ToDoz said: Send \{"text"/);
});

test('parse_preview calls the parse route and leaves out the highlight tokens', async () => {
  const out = JSON.parse(await toolsFor(TOKEN).parse_preview({ text: 'Call mum p1' }));
  assert.equal(lastRequest().path, '/api/v1/quick-add/parse');
  assert.equal(out.title, 'Call mum p1');
  assert.equal(out.tokens, undefined);
});

test('parse_preview works with a read-only token', async () => {
  const out = JSON.parse(await toolsFor(READ_ONLY_TOKEN).parse_preview({ text: 'Call mum' }));
  assert.equal(out.title, 'Call mum');
});

test('list_projects hides archived projects', async () => {
  const { projects } = JSON.parse(await toolsFor(TOKEN).list_projects({}));
  assert.deepEqual(projects.map((p) => p.id), ['inbox', 'p-home', 'p-work1', 'p-work2']);
  assert.equal(projects[0].is_inbox, true);
});

test('list_tasks sends only the filters given', async () => {
  const tools = toolsFor(TOKEN);
  let out = JSON.parse(await tools.list_tasks({}));
  assert.deepEqual(lastRequest().query, {});
  assert.ok(out.count >= 2);

  out = JSON.parse(await tools.list_tasks({ project_id: 'p-home', due_date: '2026-10-23', label: 'errands' }));
  assert.deepEqual(lastRequest().query, { project_id: 'p-home', due_date: '2026-10-23', label: 'errands' });
  assert.deepEqual(out.tasks.map((t) => t.id), ['t1']);
  assert.deepEqual(out.tasks[0].labels, ['errands']);

  out = JSON.parse(await tools.list_tasks({ project_id: 'Home' })); // by name
  assert.equal(lastRequest().query.project_id, 'p-home');
});

test('list_tasks rejects a badly formed date before calling the server', async () => {
  const before = fake.requests.length;
  await assert.rejects(toolsFor(TOKEN).list_tasks({ due_date: 'tomorrow' }), /due_date must look like/);
  assert.equal(fake.requests.length, before);
});

test('complete_task closes by id, encoding it, and reports a missing task', async () => {
  const out = JSON.parse(await toolsFor(TOKEN).complete_task({ task_id: 't2' }));
  assert.equal(lastRequest().path, '/api/v1/tasks/t2/close');
  assert.equal(out.completed.is_completed, true);

  await assert.rejects(toolsFor(TOKEN).complete_task({ task_id: 'a/b?c' }), /ToDoz said: No such task/);
  assert.equal(lastRequest().path, '/api/v1/tasks/a%2Fb%3Fc/close');
});

test('complete_task sends with_subtasks only when asked', async () => {
  await toolsFor(TOKEN).complete_task({ task_id: 't1', with_subtasks: true });
  assert.deepEqual(lastRequest().body, { with_subtasks: true });
});

test('a read-only token reads fine but gets a clear error on writes', async () => {
  const tools = toolsFor(READ_ONLY_TOKEN);
  await tools.list_tasks({});
  await assert.rejects(tools.add_task({ text: 'Nope' }), /read-only.*can look at tasks but not add or change/s);
  await assert.rejects(tools.complete_task({ task_id: 't1' }), /read-only/);
});

test('a rejected token gets a clear error that does not contain the token', async () => {
  const bad = 'tf_' + 'z'.repeat(32);
  const error = await toolsFor(bad).list_projects({}).catch((e) => e);
  assert.match(error.message, /did not accept the API token/);
  assert.ok(!error.message.includes(bad));
});

test('a rate limit error says how long to wait', async () => {
  await assert.rejects(toolsFor(LIMITED_TOKEN).list_projects({}), /rate limiting.*30 seconds/);
});

test('an unreachable server is explained, without the token', async () => {
  const client = createClient(loadConfig({ TODOZ_URL: 'http://127.0.0.1:1', TODOZ_TOKEN: TOKEN }));
  const error = await client.request('GET', '/projects').catch((e) => e);
  assert.match(error.message, /Could not reach ToDoz at http:\/\/127\.0\.0\.1:1/);
  assert.ok(!error.message.includes(TOKEN));
});

test('configuration errors say what to fix', () => {
  assert.throws(() => loadConfig({}), /TODOZ_URL is not set/);
  assert.throws(() => loadConfig({ TODOZ_URL: 'https://todoz.example.com' }), /TODOZ_TOKEN is not set.*API access/);
  assert.throws(() => loadConfig({ TODOZ_URL: 'https://todoz.example.com', TODOZ_TOKEN: 'abc' }), /does not look like a ToDoz API token/);
  assert.throws(() => loadConfig({ TODOZ_URL: 'not a url', TODOZ_TOKEN: TOKEN }), /not a valid address/);
  assert.throws(() => loadConfig({ TODOZ_URL: 'http://todoz.example.com', TODOZ_TOKEN: TOKEN }), /must start with https/);
  const ok = loadConfig({ TODOZ_URL: ' https://todoz.example.com/ ', TODOZ_TOKEN: TOKEN });
  assert.equal(ok.origin, 'https://todoz.example.com');
  assert.equal(loadConfig({ TODOZ_URL: 'http://localhost:8080', TODOZ_TOKEN: TOKEN }).origin, 'http://localhost:8080');
});
