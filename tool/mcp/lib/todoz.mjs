// The ToDoz REST API (server/lib/rest.dart) and the MCP tools built on it.
// Configuration comes only from the environment: TODOZ_URL and TODOZ_TOKEN. The token is sent in the
// Authorization header and nowhere else: never logged, never stored, never put in an error message.

const TOKEN_PATTERN = /^tf_[A-Za-z0-9_-]{20,100}$/;
const TOKEN_HELP = 'Create one in the ToDoz app under Settings > Calendar and integrations > API access.';
const REQUEST_TIMEOUT_MS = 15000;
const MAX_TASKS = 100;

/** A problem the user can fix; its message is written to be shown to them (and to the assistant). */
export class TodozError extends Error {}

/** Reads TODOZ_URL and TODOZ_TOKEN from `env`; throws a TodozError saying what to fix. */
export function loadConfig(env) {
  const rawUrl = (env.TODOZ_URL ?? '').trim();
  const token = (env.TODOZ_TOKEN ?? '').trim();
  if (!rawUrl) throw new TodozError('TODOZ_URL is not set. Set it to the address of your ToDoz server, like https://todoz.example.com');
  if (!token) throw new TodozError(`TODOZ_TOKEN is not set. Set it to an API token that starts with tf_. ${TOKEN_HELP}`);
  if (!TOKEN_PATTERN.test(token)) throw new TodozError(`TODOZ_TOKEN does not look like a ToDoz API token (it starts with tf_ and has no spaces). ${TOKEN_HELP}`);
  let url;
  try {
    url = new URL(rawUrl);
  } catch {
    throw new TodozError('TODOZ_URL is not a valid address. Use something like https://todoz.example.com');
  }
  const local = ['localhost', '127.0.0.1', '[::1]'].includes(url.hostname);
  if (url.protocol !== 'https:' && !(url.protocol === 'http:' && local)) {
    throw new TodozError('TODOZ_URL must start with https:// (plain http:// is only allowed for localhost), so the token is never sent unencrypted.');
  }
  return { origin: url.origin + url.pathname.replace(/\/+$/, ''), token };
}

/** A small client for /api/v1. `fetchImpl` and the clock are parameters so tests can replace them. */
export function createClient(config, fetchImpl = globalThis.fetch) {
  const scrub = (text) => String(text).split(config.token).join('tf_***');

  async function request(method, path, { query, body } = {}) {
    const url = new URL(config.origin + '/api/v1' + path);
    for (const [k, v] of Object.entries(query ?? {})) if (v !== undefined && v !== null && v !== '') url.searchParams.set(k, v);
    let res;
    try {
      res = await fetchImpl(url, {
        method,
        headers: {
          Authorization: `Bearer ${config.token}`,
          Accept: 'application/json',
          ...(body === undefined ? {} : { 'Content-Type': 'application/json' }),
        },
        body: body === undefined ? undefined : JSON.stringify(body),
        redirect: 'error',
        signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
      });
    } catch (e) {
      const why = e?.name === 'TimeoutError' ? 'it did not answer in time' : (e?.cause?.code ?? e?.cause?.message ?? e?.message ?? 'unknown error');
      throw new TodozError(scrub(`Could not reach ToDoz at ${new URL(config.origin).origin}: ${why}. Check TODOZ_URL and your network.`));
    }
    const text = await res.text();
    let data = null;
    try {
      data = text ? JSON.parse(text) : null;
    } catch {
      /* not JSON: handled below */
    }
    if (res.ok) return data;
    throw new TodozError(scrub(describeFailure(res, data)));
  }

  return { request };
}

function describeFailure(res, data) {
  const code = data?.error;
  const message = data?.message;
  if (res.status === 401) return `ToDoz did not accept the API token (it may be mistyped or revoked). ${TOKEN_HELP}`;
  if (res.status === 403 && code === 'read_only') {
    return 'This API token is read-only, so it can look at tasks but not add or change them. For writes, create a token without "read only" under Settings > Calendar and integrations > API access, and put it in TODOZ_TOKEN.';
  }
  if (res.status === 429) {
    const wait = res.headers.get('retry-after');
    return `ToDoz is rate limiting this token. Try again${wait ? ` in about ${wait} seconds` : ' in a minute'}.`;
  }
  if (message) return `ToDoz said: ${message} (HTTP ${res.status})`;
  return `ToDoz answered HTTP ${res.status}${res.status === 404 ? ' (is TODOZ_URL the right address?)' : ''}.`;
}

// --- helpers --------------------------------------------------------------------------------------

const pad = (n) => String(n).padStart(2, '0');

/** The caller's local date and time like 2026-10-19T14:30, so "tomorrow" means the user's tomorrow, not the server's. */
export function localNow(date = new Date()) {
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}`;
}

function summariseTask(t) {
  const out = { id: t.id, title: t.title, project_id: t.project_id, priority: t.priority };
  if (t.due) out.due = t.due;
  if (t.deadline) out.deadline = t.deadline;
  if (t.labels?.length) out.labels = t.labels;
  if (t.description) out.description = t.description;
  if (t.section_id) out.section_id = t.section_id;
  if (t.parent_id) out.parent_id = t.parent_id;
  if (t.is_completed) out.is_completed = true;
  return out;
}

const json = (value) => JSON.stringify(value);

// --- tools ----------------------------------------------------------------------------------------

/** The MCP tools. `getClient` is called per request so a missing or wrong configuration is reported as a tool error. */
export function createTools(getClient, now = () => new Date()) {
  async function resolveProject(client, ref) {
    if (ref === undefined || ref === null || String(ref).trim() === '') return undefined;
    const wanted = String(ref).trim();
    const { projects } = await client.request('GET', '/projects');
    const byId = projects.find((p) => p.id === wanted);
    if (byId) return byId.id;
    const named = projects.filter((p) => !p.is_archived && (p.name ?? '').toLowerCase() === wanted.toLowerCase());
    if (named.length === 1) return named[0].id;
    if (named.length > 1) throw new TodozError(`More than one project is called "${wanted}". Use list_projects and pass the project id.`);
    const names = projects.filter((p) => !p.is_archived).map((p) => p.name).join(', ');
    throw new TodozError(`No project called "${wanted}". Projects: ${names}.`);
  }

  const projectProp = {
    type: 'string',
    description: 'Project name or id (see list_projects). Leave out for the Inbox. A #Project written in the text takes priority.',
  };

  return [
    {
      name: 'add_task',
      description:
        'Add a task to ToDoz from a Quick Add line. The line is understood the way the ToDoz apps understand it: ' +
        'dates and times ("tomorrow 5pm", "every monday"), priority (p1 is most urgent, p4 least), #Project, @label or %label, and /Section. ' +
        'Example: "Submit revisions tomorrow 4pm p1 #Research %writing". Returns the task that was created.',
      inputSchema: {
        type: 'object',
        properties: {
          text: { type: 'string', description: 'The Quick Add line, e.g. "Buy milk tomorrow 5pm p2 #Home".' },
          project: projectProp,
        },
        required: ['text'],
      },
      annotations: { title: 'Add a task', readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
      async handler({ text, project }) {
        const client = getClient();
        const projectId = await resolveProject(client, project);
        const task = await client.request('POST', '/quick-add', { body: { text, project_id: projectId, today: localNow(now()) } });
        return json({ created: summariseTask(task) });
      },
    },
    {
      name: 'parse_preview',
      description:
        'Show what a Quick Add line would become (title, due date and time, priority, labels, project) without saving anything. ' +
        'Use it to check a date or project before add_task when unsure. Works with a read-only token.',
      inputSchema: {
        type: 'object',
        properties: { text: { type: 'string', description: 'The Quick Add line to interpret.' }, project: projectProp },
        required: ['text'],
      },
      annotations: { title: 'Preview a Quick Add line', readOnlyHint: true, openWorldHint: false },
      async handler({ text, project }) {
        const client = getClient();
        const projectId = await resolveProject(client, project);
        const { tokens, ...preview } = await client.request('POST', '/quick-add/parse', { body: { text, project_id: projectId, today: localNow(now()) } });
        return json(preview);
      },
    },
    {
      name: 'list_projects',
      description: 'List the ToDoz projects with their ids (the Inbox is included). Use the ids or names with add_task and list_tasks.',
      inputSchema: { type: 'object', properties: {} },
      annotations: { title: 'List projects', readOnlyHint: true, openWorldHint: false },
      async handler() {
        const { projects } = await getClient().request('GET', '/projects');
        return json({
          projects: projects.filter((p) => !p.is_archived).map((p) => ({ id: p.id, name: p.name, ...(p.is_inbox ? { is_inbox: true } : {}), ...(p.parent_id ? { parent_id: p.parent_id } : {}) })),
        });
      },
    },
    {
      name: 'list_tasks',
      description: 'List open tasks, optionally only those in one project, due on one date, or carrying one label.',
      inputSchema: {
        type: 'object',
        properties: {
          project_id: { type: 'string', description: 'Only tasks in this project (an id from list_projects; a project name also works).' },
          due_date: { type: 'string', description: 'Only tasks due on this date, as YYYY-MM-DD.' },
          label: { type: 'string', description: 'Only tasks with this label (without the % or @).' },
        },
      },
      annotations: { title: 'List tasks', readOnlyHint: true, openWorldHint: false },
      async handler({ project_id, due_date, label }) {
        if (due_date !== undefined && !/^\d{4}-\d{2}-\d{2}$/.test(due_date)) throw new TodozError('due_date must look like 2026-10-23');
        const client = getClient();
        const projectId = await resolveProject(client, project_id);
        const { tasks } = await client.request('GET', '/tasks', { query: { project_id: projectId, due_date, label } });
        const shown = tasks.slice(0, MAX_TASKS).map(summariseTask);
        return json({ count: tasks.length, ...(tasks.length > MAX_TASKS ? { note: `Showing the first ${MAX_TASKS}; narrow it with project_id, due_date or label.` } : {}), tasks: shown });
      },
    },
    {
      name: 'complete_task',
      description: 'Mark a task as done. Repeating tasks move on to their next date. Get the task id from list_tasks.',
      inputSchema: {
        type: 'object',
        properties: {
          task_id: { type: 'string', description: 'The id of the task, from list_tasks or add_task.' },
          with_subtasks: { type: 'boolean', description: 'Also complete the task\'s subtasks.' },
        },
        required: ['task_id'],
      },
      annotations: { title: 'Complete a task', readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false },
      async handler({ task_id, with_subtasks }) {
        const task = await getClient().request('POST', `/tasks/${encodeURIComponent(task_id)}/close`, {
          body: with_subtasks ? { with_subtasks: true } : undefined,
        });
        return json({ completed: summariseTask(task) });
      },
    },
  ];
}
