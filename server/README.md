# TaskFlow sync server

One small Dart program on SQLite. It stores each person's tasks separately and merges edits from their devices. It does not serve a website, and it has no passwords: people are created by you on the server, and a device joins with a one-time pairing code.

## Deploying

The step-by-step guide, including how to keep the server **private** (reachable only from your own devices through Tailscale), is in [`deploy/DEPLOY.md`](deploy/DEPLOY.md). The short version, from `server/deploy`:

```sh
./deploy.sh private                      # or: ./deploy.sh public sync.example.com
sudo tailscale serve --bg 8080           # private mode only
./deploy.sh invite Alice                 # prints a one-time pairing code
```

Without Docker (Debian/Ubuntu): `sudo TASKFLOW_DOMAIN=sync.example.com bash server/deploy/install.sh`, or `sudo TASKFLOW_MODE=private bash server/deploy/install.sh`.

## Add people and pair devices

```text
taskflow_server user add <name>        create a person (no password)
taskflow_server invite <name>          print a pairing code: works once, expires in 10 minutes
taskflow_server user list              people and how much each stores
taskflow_server revoke <name> <id>     sign one device out at once (the app can do this too)
taskflow_server user delete <name> --yes
taskflow_server backup <file>          consistent copy, safe while the server runs
taskflow_server serve [--port 8080 --host 127.0.0.1 --trust-proxy]
      [--blobs <folder> --max-file-mb 100 --quota-mb 5120]                attachment files
      [--google-client-id .. --google-client-secret .. --public-url ..]   Google Calendar connection
      [--allow-private-webhooks]                                          webhooks may call addresses on your own network
```

The database path is `--db <file>` or the `TASKFLOW_DB` variable (default `data/taskflow.sqlite`).

In the app: Settings, Sync, enter `https://sync.example.com` (or just the name), the code, and a name for the device.

## What else the server does

- **Attachments** (`/v1/blobs`): content-addressed files, one copy per content, with a per-file limit and a per-person quota. They live in a `blobs` folder beside the database.
- **REST API** (`/v1/...`) with personal API tokens (`tf_...`, created in the app under Settings, Calendar and integrations) for scripts and automations.
- **Webhooks:** outgoing, signed with HMAC-SHA256, retried, and refused for private addresses unless you pass `--allow-private-webhooks`; one incoming signed webhook that creates tasks, with replay protection.
- **Calendar feed:** a secret `/ical/<token>.ics` address with a person's dated tasks, for any calendar app that can subscribe to a link.
- **Google Calendar** (two-way, optional): needs your own Google OAuth client; steps in `deploy/DEPLOY.md`. Tested against a fake Google only.
- **Sharing projects:** invitation codes, roles (owner, admin, member, viewer), assignment, comments and reactions. Shared rows are copied into each member's own space; personal fields (reminders, labels and the like) are not shared.

## Security notes

- The server is the only place your data is readable by someone else. It is **not end-to-end encrypted**: whoever controls the server can read the tasks. Keep the machine to yourself and keep its disk encrypted (SEC-10); if it is a shared host, do not use it.
- Always put HTTPS in front. The apps refuse plain `http://` except to addresses on your own network. The `--trust-proxy` flag makes the server believe `X-Forwarded-For`, so use it **only** behind your own proxy (the Docker and install scripts do).
- Device tokens are random 32-byte values and only a hash is stored, so a copy of the database cannot be used to sign in. Revoking a device takes effect on its next request.
- Pairing is rate limited (5 wrong codes from one address locks it for 15 minutes), sync is rate limited per device, and request bodies are capped.
- The access log records the time, route, status and address but never bodies or tokens.
- To keep it only on a private network (SEC-11) use `./deploy.sh private` with Tailscale (see `deploy/DEPLOY.md`): no port is open to the internet.
- Update at least monthly (SEC-15): `./deploy.sh update` (Docker) or `sudo bash server/deploy/update.sh`.

## Backups

The nightly script keeps 14 copies of the database in `/var/backups/taskflow` (without Docker), plus the attachment files in `blobs/`. With Docker run `./deploy.sh backup`. Copy backups off the machine, ideally encrypted (for example with `age`). Restoring is copying a backup over the database file while the server is stopped.

## Developing

```sh
dart pub get
dart test
dart run bin/taskflow_server.dart --db data/dev.sqlite serve --port 8080
```

## What has and has not been tested

The server and its security rules have automated tests (store, HTTP API, and the app's sync over real HTTP). The compiled server (`dart build cli`) was started and checked on Windows. Sharing, the REST API, webhooks, attachments and the iCal feed are covered by tests, including two simulated devices over real HTTP. The **Google connection has only been tested against a fake Google.** The **Docker files, `deploy.sh`, install script, systemd unit and Caddy configuration have not been run on a real Linux machine** (`deploy.sh` was only checked against a stubbed `docker`); treat their first run as a test and read the output.
