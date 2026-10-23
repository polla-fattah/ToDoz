// A minimal Model Context Protocol server over stdio: newline-delimited JSON-RPC 2.0.
// It speaks only what a tools-only server needs (initialize, ping, tools/list, tools/call), so the whole
// thing runs on plain Node with no packages to install.

import { createInterface } from 'node:readline';

export const SUPPORTED_VERSIONS = ['2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05'];

const PARSE_ERROR = -32700;
const INVALID_REQUEST = -32600;
const METHOD_NOT_FOUND = -32601;
const INVALID_PARAMS = -32602;
const INTERNAL_ERROR = -32603;

/** Checks `args` against a flat JSON schema (string/integer/boolean properties); returns an error text or null. */
export function validateArguments(schema, args) {
  const given = args ?? {};
  if (typeof given !== 'object' || Array.isArray(given)) return 'arguments must be an object';
  for (const name of schema.required ?? []) {
    if (given[name] === undefined || given[name] === null) return `missing required argument "${name}"`;
  }
  for (const [name, value] of Object.entries(given)) {
    const spec = schema.properties?.[name];
    if (!spec) return `unknown argument "${name}"`;
    if (value === undefined || value === null) continue;
    const ok =
      spec.type === 'string' ? typeof value === 'string' :
      spec.type === 'integer' ? Number.isInteger(value) :
      spec.type === 'boolean' ? typeof value === 'boolean' : true;
    if (!ok) return `argument "${name}" must be a ${spec.type}`;
  }
  return null;
}

/**
 * Handles one decoded JSON-RPC message; returns the response object, or null when none is due (notifications).
 * `tools` is a list of `{name, description, inputSchema, annotations, handler(args) -> string}`; a handler
 * that throws turns into a tool result with `isError`, which is how a model gets to read what went wrong.
 */
export async function handleMessage(msg, { info, instructions, tools }) {
  if (msg === null || typeof msg !== 'object' || Array.isArray(msg) || typeof msg.method !== 'string') {
    return { jsonrpc: '2.0', id: msg?.id ?? null, error: { code: INVALID_REQUEST, message: 'Invalid request' } };
  }
  const isNotification = msg.id === undefined || msg.id === null;
  const reply = (result) => (isNotification ? null : { jsonrpc: '2.0', id: msg.id, result });
  const fail = (code, message) => (isNotification ? null : { jsonrpc: '2.0', id: msg.id, error: { code, message } });

  switch (msg.method) {
    case 'initialize': {
      const wanted = msg.params?.protocolVersion;
      return reply({
        protocolVersion: SUPPORTED_VERSIONS.includes(wanted) ? wanted : SUPPORTED_VERSIONS[0],
        capabilities: { tools: { listChanged: false } },
        serverInfo: info,
        instructions,
      });
    }
    case 'ping':
      return reply({});
    case 'tools/list':
      return reply({
        tools: tools.map(({ name, description, inputSchema, annotations }) => ({ name, description, inputSchema, annotations })),
      });
    case 'tools/call': {
      const tool = tools.find((t) => t.name === msg.params?.name);
      if (!tool) return fail(INVALID_PARAMS, `Unknown tool: ${msg.params?.name}`);
      const problem = validateArguments(tool.inputSchema, msg.params?.arguments);
      if (problem) return reply({ content: [{ type: 'text', text: `Invalid arguments: ${problem}` }], isError: true });
      try {
        const text = await tool.handler(msg.params?.arguments ?? {});
        return reply({ content: [{ type: 'text', text }] });
      } catch (e) {
        return reply({ content: [{ type: 'text', text: e instanceof Error ? e.message : String(e) }], isError: true });
      }
    }
    default:
      return isNotification ? null : fail(METHOD_NOT_FOUND, `Method not found: ${msg.method}`);
  }
}

/** Reads messages from `input` and writes responses to `output` until `input` ends. Resolves when all are answered. */
export function serveStdio({ input, output, ...server }) {
  const pending = new Set();
  const send = (obj) => output.write(JSON.stringify(obj) + '\n');

  const handleLine = async (line) => {
    let parsed;
    try {
      parsed = JSON.parse(line);
    } catch {
      send({ jsonrpc: '2.0', id: null, error: { code: PARSE_ERROR, message: 'Parse error' } });
      return;
    }
    try {
      if (Array.isArray(parsed)) {
        const replies = (await Promise.all(parsed.map((m) => handleMessage(m, server)))).filter(Boolean);
        if (replies.length) send(replies);
      } else {
        const response = await handleMessage(parsed, server);
        if (response) send(response);
      }
    } catch (e) {
      send({ jsonrpc: '2.0', id: parsed?.id ?? null, error: { code: INTERNAL_ERROR, message: e instanceof Error ? e.message : 'Internal error' } });
    }
  };

  const lines = createInterface({ input, crlfDelay: Infinity });
  lines.on('line', (line) => {
    if (!line.trim()) return;
    const job = handleLine(line).finally(() => pending.delete(job));
    pending.add(job);
  });
  return new Promise((resolve) => lines.on('close', () => Promise.all(pending).then(resolve)));
}
