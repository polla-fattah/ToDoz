#!/usr/bin/env node
// ToDoz MCP server (stdio). Configuration: TODOZ_URL and TODOZ_TOKEN in the environment. See README.md.

import { readFileSync } from 'node:fs';
import { serveStdio } from './lib/mcp.mjs';
import { createClient, createTools, loadConfig } from './lib/todoz.mjs';

const { version } = JSON.parse(readFileSync(new URL('./package.json', import.meta.url), 'utf8'));

let client;
const getClient = () => (client ??= createClient(loadConfig(process.env)));

// A missing or bad setting is reported when a tool is used (so the assistant can tell the user), and once on stderr.
try {
  loadConfig(process.env);
} catch (e) {
  console.error(`todoz-mcp: ${e.message}`);
}

await serveStdio({
  input: process.stdin,
  output: process.stdout,
  info: { name: 'todoz', title: 'ToDoz', version },
  instructions:
    'Manage tasks in the user\'s ToDoz app. Use add_task with a Quick Add line (dates, priority p1-p4, #Project, %label are understood). ' +
    'Use parse_preview when unsure how a line will be read. Use list_tasks to find a task id before complete_task.',
  tools: createTools(getClient),
});
