// Runs server.mjs as a real child process and talks JSON-RPC to it over stdio, the way an MCP client does.

import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';
import { READ_ONLY_TOKEN, TOKEN, startFakeTodoz } from './fake_todoz.mjs';

const serverPath = fileURLToPath(new URL('../server.mjs', import.meta.url));
let fake;
before(async () => { fake = await startFakeTodoz(); });
after(() => fake.close());

function startServer(env) {
  const child = spawn(process.execPath, [serverPath], {
    env: { PATH: process.env.PATH, SystemRoot: process.env.SystemRoot, ...env },
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  const waiting = new Map();
  let stderr = '';
  let id = 0;
  child.stderr.on('data', (d) => (stderr += d));
  createInterface({ input: child.stdout }).on('line', (line) => {
    const msg = JSON.parse(line); // every stdout line must be JSON, or an MCP client would choke
    waiting.get(msg.id)?.(msg);
  });
  const write = (obj) => child.stdin.write(JSON.stringify(obj) + '\n');
  const rpc = (method, params) => new Promise((resolve) => {
    const myId = ++id;
    waiting.set(myId, resolve);
    write({ jsonrpc: '2.0', id: myId, method, params });
  });
  return {
    stderr: () => stderr,
    notify: (method) => write({ jsonrpc: '2.0', method }),
    raw: (text) => child.stdin.write(text + '\n'),
    nullIdReply: () => new Promise((resolve) => waiting.set(null, resolve)),
    rpc,
    call: (name, args) => rpc('tools/call', { name, arguments: args }),
    stop: () => new Promise((resolve) => { child.on('close', resolve); child.stdin.end(); }),
  };
}

const textOf = (msg) => msg.result.content[0].text;

test('handshake, tool list and a full add / list / complete round trip', async () => {
  const s = startServer({ TODOZ_URL: fake.url, TODOZ_TOKEN: TOKEN });
  try {
    const init = await s.rpc('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'test', version: '0' } });
    assert.equal(init.result.protocolVersion, '2025-06-18');
    assert.equal(init.result.serverInfo.name, 'todoz');
    assert.ok(init.result.capabilities.tools);
    s.notify('notifications/initialized'); // no reply expected

    const listed = await s.rpc('tools/list');
    assert.deepEqual(listed.result.tools.map((t) => t.name).sort(), ['add_task', 'complete_task', 'list_projects', 'list_tasks', 'parse_preview']);
    for (const t of listed.result.tools) {
      assert.equal(t.inputSchema.type, 'object');
      assert.ok(t.description.length > 20);
    }

    const added = await s.call('add_task', { text: 'Stdio task p2' });
    assert.ok(!added.result.isError);
    const { created } = JSON.parse(textOf(added));

    const done = await s.call('complete_task', { task_id: created.id });
    assert.equal(JSON.parse(textOf(done)).completed.id, created.id);
    assert.deepEqual((await s.rpc('ping')).result, {});
  } finally {
    await s.stop();
  }
});

test('an unknown protocol version is answered with one the server supports', async () => {
  const s = startServer({ TODOZ_URL: fake.url, TODOZ_TOKEN: TOKEN });
  try {
    const init = await s.rpc('initialize', { protocolVersion: '1999-01-01' });
    assert.match(init.result.protocolVersion, /^\d{4}-\d{2}-\d{2}$/);
    assert.notEqual(init.result.protocolVersion, '1999-01-01');
  } finally {
    await s.stop();
  }
});

test('bad calls get protocol errors or tool errors, and the server keeps going', async () => {
  const s = startServer({ TODOZ_URL: fake.url, TODOZ_TOKEN: TOKEN });
  try {
    assert.equal((await s.rpc('nope')).error.code, -32601);
    assert.equal((await s.call('no_such_tool', {})).error.code, -32602);
    const missing = await s.call('add_task', {});
    assert.equal(missing.result.isError, true);
    assert.match(textOf(missing), /missing required argument "text"/);
    const wrongType = await s.call('complete_task', { task_id: 5 });
    assert.match(textOf(wrongType), /must be a string/);
    assert.ok((await s.rpc('ping')).result);
  } finally {
    await s.stop();
  }
});

test('a read-only token: reads work, writes come back as a clear tool error', async () => {
  const s = startServer({ TODOZ_URL: fake.url, TODOZ_TOKEN: READ_ONLY_TOKEN });
  try {
    assert.ok(!(await s.call('list_tasks', {})).result.isError);
    const write = await s.call('add_task', { text: 'Should fail' });
    assert.equal(write.result.isError, true);
    assert.match(textOf(write), /read-only/);
  } finally {
    await s.stop();
  }
});

test('without configuration the server still starts and tools explain what to set; the token is never printed', async () => {
  const s = startServer({});
  try {
    assert.ok((await s.rpc('tools/list')).result.tools.length === 5);
    const out = await s.call('list_projects', {});
    assert.equal(out.result.isError, true);
    assert.match(textOf(out), /TODOZ_URL is not set/);
  } finally {
    await s.stop();
  }
  const bad = startServer({ TODOZ_URL: fake.url, TODOZ_TOKEN: 'tf_secret-short' });
  try {
    await bad.rpc('tools/list');
    for (let i = 0; i < 50 && !bad.stderr(); i++) await new Promise((r) => setTimeout(r, 20)); // stderr is a separate pipe
    assert.match(bad.stderr(), /does not look like a ToDoz API token/);
    assert.ok(!bad.stderr().includes('tf_secret'));
  } finally {
    await bad.stop();
  }
});

test('a line that is not JSON gets a parse error with a null id', async () => {
  const s = startServer({ TODOZ_URL: fake.url, TODOZ_TOKEN: TOKEN });
  try {
    const reply = s.nullIdReply();
    s.raw('this is not json');
    assert.equal((await reply).error.code, -32700);
    assert.ok((await s.rpc('ping')).result);
  } finally {
    await s.stop();
  }
});
