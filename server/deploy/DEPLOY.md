# Deploying TaskFlow's sync server

The server is one small program with a SQLite database. It holds each person's tasks and merges edits from their phones and PCs. This page takes you from an empty Linux machine to a paired phone, and explains how to keep it **private**.

> **Honest status.** The server code and its security rules are covered by automated tests, and the app's sync was tested against the compiled server on Windows and from an Android emulator. The **Docker files, the install script, the systemd unit and the Caddy configuration in this folder have not yet been run on a real Linux host.** Treat the first run as a test: read the output, and tell me (or fix) anything that does not behave.

## 1. Choose how it is reached

| | **Private** (recommended for just you) | **Public** |
| --- | --- | --- |
| Who can even connect | Only your own devices, through [Tailscale](https://tailscale.com) (free for personal use) | Anyone on the internet can reach the login page; they still need a one-time code |
| Needs | A machine, Tailscale on it and on each device | A machine, a domain name, ports 80 and 443 open |
| HTTPS | Tailscale provides a real certificate (`https://machine.tailnet.ts.net`) | Caddy gets and renews one for your domain |
| Google Calendar connection | Probably not (see section 5) | Yes |
| Calendar feed (iCal link) used by Google Calendar or Outlook on the web | No (their servers cannot reach you); works from apps on your own devices | Yes |
| Attack surface | Almost none: nothing is open to the internet | Small, but it exists: keep it updated |

If you only want your own tasks synced between your own phone and PC, choose **private**. Choose public if you want sharing with people who will not install Tailscale, or Google Calendar.

## 2. What you need

- A Linux machine that stays on: a small VPS, a Raspberry Pi, a home server or an old PC. 1 GB of RAM is plenty. Debian or Ubuntu is assumed.
- Docker with the compose plugin (<https://docs.docker.com/engine/install/>), or the no-Docker route in section 6.
- This repository on that machine (`git clone` it, or copy the folder).
- Private mode: a free Tailscale account. Public mode: a domain name whose DNS `A` record points at the machine.

## 3. Private deployment (Tailscale)

1. **Install Tailscale on the server** and sign in: `curl -fsSL https://tailscale.com/install.sh | sh`, then `sudo tailscale up`.
2. In the Tailscale admin console (<https://login.tailscale.com/admin/dns>) turn on **MagicDNS** and **HTTPS Certificates**.
3. **Install Tailscale on your phone and PC** with the same account and switch it on.
4. **Start the server** (inside the `server/deploy` folder):

   ```sh
   ./deploy.sh private
   sudo tailscale serve --bg 8080
   ```

   The first command builds and starts the server so that it listens **only on the machine itself** (`127.0.0.1:8080`). The second makes it available to your tailnet over HTTPS and prints the address, like `https://myserver.tail1234.ts.net`.
5. **Create yourself and get a pairing code:**

   ```sh
   ./deploy.sh invite Alice
   ```
6. **In the app:** Settings, Sync, enter the `https://...ts.net` address, the code, and a name for the device. Repeat `./deploy.sh invite Alice` for each extra device (a code works once and expires in 10 minutes). For another person, use their own name: they get a separate account.
7. **Close the door:** open no ports in the firewall for TaskFlow. On Ubuntu: `sudo ufw default deny incoming && sudo ufw allow OpenSSH && sudo ufw enable`. (Tailscale needs no inbound port.)

Notes: your phone must have Tailscale connected to sync (set it to "always on" in the Android VPN settings). If the phone is offline or Tailscale is off, nothing is lost; changes queue and go when it is back. If you prefer not to use `tailscale serve`, the app also accepts `http://100.x.y.z:8080` (a Tailscale address) and `http://machine.tailnet.ts.net:8080`, but then you must make the server listen on the Tailscale address yourself, and the traffic is encrypted only by Tailscale itself.

## 4. Public deployment

1. Point a DNS name (for example `sync.example.com`) at the machine and open ports 80 and 443.
2. Start it:

   ```sh
   ./deploy.sh public sync.example.com
   ./deploy.sh invite Alice
   ```
3. In the app: Settings, Sync, `https://sync.example.com` (or just the name), the code, a device name. Caddy fetches the certificate on the first visit; give it a minute.

## 5. Google Calendar (optional)

The app can keep your dated tasks in a dedicated "TaskFlow" calendar in your Google account, and pick up changes you make to those events. It asks Google for one narrow permission (`calendar.app.created`: only calendars this app created). To switch it on you create your own Google "OAuth client" (about 10 minutes, free):

1. Open <https://console.cloud.google.com/>, create a project (name it TaskFlow).
2. APIs and Services, Library: enable **Google Calendar API**.
3. APIs and Services, OAuth consent screen: user type **External**, fill the app name and your email. Add yourself under **Test users**.
4. Credentials, Create credentials, **OAuth client ID**, type **Web application**. Under **Authorized redirect URIs** add exactly `https://sync.example.com/google/callback` (your own domain). Copy the client ID and secret.
5. Put them in `server/deploy/.env`:

   ```text
   TASKFLOW_PUBLIC_URL=https://sync.example.com
   GOOGLE_CLIENT_ID=...
   GOOGLE_CLIENT_SECRET=...
   ```

   Then run `./deploy.sh public sync.example.com` again to apply them. The server log says "Google Calendar connection is on".
6. In the app: Settings, Calendar and integrations, Google Calendar, Connect. Google shows an "unverified app" warning for your own client; choose Advanced, then continue.

Things to know:

- While the consent screen is in **Testing** status, Google expires the sign-in after about 7 days and you must connect again. To avoid that, set the publishing status to **In production** (you do not need to submit it for verification for personal use).
- Google redirects the phone's browser to `/google/callback`, so the address must be reachable from the phone. In private mode, Google may refuse a `*.ts.net` redirect address; I have not tested this. Use public mode if you need Google Calendar.
- The two-way sync logic was tested only against a fake Google. **It has not been run against the real Google Calendar yet.** Try it with a throwaway task first.

## 6. Without Docker

On Debian or Ubuntu, with [Dart](https://dart.dev/get-dart) installed (it is only used to build):

```sh
sudo TASKFLOW_DOMAIN=sync.example.com bash server/deploy/install.sh      # public, with Caddy
sudo TASKFLOW_MODE=private bash server/deploy/install.sh                  # private (then: sudo tailscale serve --bg 8080)
```

It creates a locked-down systemd service, a nightly backup (14 kept) and `/etc/taskflow/taskflow.env` for the settings in section 5. Commands afterwards:

```sh
TF="sudo -u taskflow TASKFLOW_DB=/var/lib/taskflow/taskflow.sqlite /opt/taskflow/bin/taskflow_server"
$TF user add Alice
$TF invite Alice
journalctl -u taskflow-server -f      # logs
sudo bash server/deploy/update.sh      # update after git pull
```

## 7. Keeping it safe

- **Not end-to-end encrypted.** Whoever controls the machine can read the tasks. Keep the machine yours and the disk encrypted (SEC-10): for a VPS choose full-disk encryption at install, or put the data folder on an encrypted volume; at home turn on LUKS.
- **Updates at least monthly** (SEC-15): `./deploy.sh update` (Docker) or `sudo bash server/deploy/update.sh`. Also keep the operating system patched: `sudo apt install unattended-upgrades`.
- **Firewall:** private mode opens nothing; public opens 80 and 443 (and SSH for you, preferably by key only, no password logins).
- **Backups (SEC-13):** `./deploy.sh backup` writes the database to `server/deploy/backups/` and the attachment files to `backups/blobs/` (the non-Docker install does this nightly to `/var/backups/taskflow`). Copy them off the machine regularly, encrypted, for example `age -r <your-key> -o backup.age file`. Also use the app's own backup (Settings, Backup) from time to time.
- **Restoring:** stop the server, copy the backed-up `.sqlite` over the database (Docker: into the `taskflow-data` volume as `taskflow.sqlite`) and the `blobs` folder next to it, start it, then each device syncs again.
- **Lost phone:** Settings, Sync on another device lists devices; revoke the lost one, or run `./deploy.sh cli revoke Alice <id>`.
- **Admin commands:** `./deploy.sh cli user list` shows people and how much each stores; `cli user delete <name> --yes` removes an account and its data.

## 8. Check that it works

```sh
./deploy.sh status                 # both containers "running"
./deploy.sh logs                   # no errors
curl https://sync.example.com/health     # public: {"ok":true}   (private: curl https://myserver.tail1234.ts.net/health from a tailnet device)
```

Then pair the phone and add a task; a second device paired to the same account should show it within about 30 seconds (usually a few seconds).

## 9. Files in this folder

| File | What it is |
| --- | --- |
| `deploy.sh` | One command for the Docker route: `public`, `private`, `invite`, `update`, `backup`, `status`, `logs`, `stop`, `cli` |
| `compose.yaml` | The containers: the server, plus Caddy (public profile) or a loopback forwarder (private profile) |
| `.env.example` | The settings (domain, public address, Google client). `deploy.sh` copies it to `.env` |
| `Caddyfile`, `Caddyfile.host` | HTTPS configuration for Docker and for the no-Docker install; attachment uploads up to 110 MB, everything else 2 MB |
| `install.sh`, `update.sh`, `backup.sh`, `taskflow-server.service` | The no-Docker route |
