# ToDoz MCP server

Lets an AI assistant (Claude Desktop, Claude Code, Gemini CLI, or any other [MCP](https://modelcontextprotocol.io) client) add and look at your ToDoz tasks. It is a small wrapper over the ToDoz REST API (`/api/v1`) and talks to the assistant over stdio.

> **On a phone or in a browser?** This wrapper is for assistants on your own computer. Claude on the web or phone, ChatGPT and the Gemini app connect to the ToDoz server's own remote endpoint instead, `https://your-server/mcp`; see the help page.

- **Nothing to install.** One Node.js (20 or newer) program with no packages; there is no `npm install`.
- **Configured only by two environment variables**, `TODOZ_URL` and `TODOZ_TOKEN`. The token is sent to your ToDoz server and nowhere else. It is never logged, stored or shown in an error message.
- **Safe by default.** `TODOZ_URL` must be `https://` (plain `http://` is accepted only for `localhost`), so the token is never sent unencrypted.

## 1. Get an API token

In the ToDoz app (or at `https://your-server/app`): **Settings → Calendar and integrations → API access**, make a token, and copy it (it starts with `tf_` and is shown once). Give each assistant its own token so you can revoke one without touching the others.

Tick **read only** if the assistant should only look: the tools that change things (`add_task`, `complete_task`) then answer with a clear "this token is read-only" message, and `list_projects`, `list_tasks` and `parse_preview` keep working.

Treat the token like a password. Revoke it on the same page whenever you like.

## 2. Tools

| Tool | What it does | REST call |
| :--- | :--- | :--- |
| `add_task` | Adds a task from a Quick Add line such as `Submit revisions tomorrow 4pm p1 #Research %writing`. Optional `project` (name or id). | `POST /api/v1/quick-add` |
| `parse_preview` | Shows how a line would be read (title, date, priority, labels, project) without saving. Works with a read-only token. | `POST /api/v1/quick-add/parse` |
| `list_projects` | Lists projects and their ids. | `GET /api/v1/projects` |
| `list_tasks` | Lists open tasks; optional `project_id`, `due_date` (`2026-10-23`), `label`. | `GET /api/v1/tasks` |
| `complete_task` | Completes a task by id (`with_subtasks` also completes its subtasks). | `POST /api/v1/tasks/{id}/close` |

"Tomorrow", "Friday" and similar are worked out from the clock of the computer running the assistant, so they mean *your* tomorrow, not the server's.

## 3. Add it to your assistant

Use the full path to `server.mjs` in this folder. Examples below use `C:\ToDoz\tool\mcp\server.mjs`; on macOS or Linux use a path like `/home/you/todoz/tool/mcp/server.mjs`. In JSON, write Windows backslashes doubled.

### Claude Desktop

Open **Settings → Developer → Edit Config** (this opens `claude_desktop_config.json`) and add:

```json
{
  "mcpServers": {
    "todoz": {
      "command": "node",
      "args": ["C:\\ToDoz\\tool\\mcp\\server.mjs"],
      "env": {
        "TODOZ_URL": "https://todoz.example.com",
        "TODOZ_TOKEN": "tf_your_token_here"
      }
    }
  }
}
```

Restart Claude Desktop. If it cannot find `node`, put the full path to `node.exe` in `command`.

### Claude Code

```bash
claude mcp add todoz --scope user --env TODOZ_URL=https://todoz.example.com --env TODOZ_TOKEN=tf_your_token_here -- node /path/to/tool/mcp/server.mjs
```

`--scope user` makes it available in every project; leave it out to keep it in the current project only. Check with `claude mcp list`, or `/mcp` inside Claude Code.

### Gemini CLI

Add this to `~/.gemini/settings.json` (on Windows `%USERPROFILE%\.gemini\settings.json`); use `.gemini/settings.json` inside a project to limit it to that project:

```json
{
  "mcpServers": {
    "todoz": {
      "command": "node",
      "args": ["/path/to/tool/mcp/server.mjs"],
      "env": {
        "TODOZ_URL": "https://todoz.example.com",
        "TODOZ_TOKEN": "tf_your_token_here"
      }
    }
  }
}
```

Run `/mcp` inside Gemini CLI to see that `todoz` is connected and lists its five tools.

### Then just ask

> "Add a task to call the dentist next Monday at 9, priority 2."
> "What's due today?" · "Mark the dentist task as done."

## 4. When something goes wrong

The tools answer with a plain message the assistant can show you:

| Message starts with | Meaning |
| :--- | :--- |
| `TODOZ_URL is not set` / `TODOZ_TOKEN is not set` | The `env` block is missing or misspelled. |
| `ToDoz did not accept the API token` | Mistyped or revoked token (HTTP 401). |
| `This API token is read-only` | The token was made read only (HTTP 403 `read_only`); make a new one for writes. |
| `ToDoz is rate limiting this token` | Too many calls in a minute (HTTP 429); wait as told. |
| `Could not reach ToDoz` | Wrong `TODOZ_URL`, no network, or the server is down. |
| `ToDoz said: …` | The server refused the request, e.g. "No such task" or a bad date. |

The server also writes a one-line note to stderr at start-up if its configuration is wrong (never the token).

## 5. Tests

```bash
cd tool/mcp
npm test        # or: node --test
```

`test/tools.test.mjs` runs every tool against a fake ToDoz HTTP server (`test/fake_todoz.mjs`, same routes and error bodies as `server/lib/rest.dart`), including read-only, bad token, rate limit and unreachable-server cases. `test/stdio.test.mjs` starts `server.mjs` as a child process and speaks JSON-RPC to it the way an MCP client does. No network access or real server is needed.

To try it against a real local server instead:

```bash
cd server
dart run bin/taskflow_server.dart user add me
dart run bin/taskflow_server.dart token me "mcp test"          # prints a tf_ token (add --read-only for a read-only one)
dart run bin/taskflow_server.dart serve --port 8080 --host 127.0.0.1
# then run server.mjs with TODOZ_URL=http://127.0.0.1:8080 and that token
```
