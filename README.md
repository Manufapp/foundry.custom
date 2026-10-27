# foundry.custom — on-prem / customer server deployment

Docker Compose config for running the Manufapp ERP stack (pulled pre-built images,
never built locally) on an on-prem or customer-owned server. PostgreSQL is **not**
containerized — it's expected to already be running on the host's bare metal.

## Stack

| Service | Image | Notes |
|---|---|---|
| `nginx` | `nginx:alpine` | Single entry point on `:80`. Routes `/api/*` and `/ws/*` to django, everything else to react — see [Why nginx](#why-nginx) below. |
| `react` | `foundry.react` (ECR) | Next.js frontend, `npm start`, port `3000` (also exposed directly for debugging). |
| `django` | `foundry.django` (ECR) | ASGI via `uvicorn` (needed for Django Channels websockets — gunicorn would silently drop them), port `8000` (also exposed directly). Runs `manage.py migrate` before starting. |
| `celery` | `foundry.django` (ECR) | Worker, waits for `django` to be healthy (migrations applied) before starting. |
| `celery-beat` | `foundry.django` (ECR) | Scheduler (`django_celery_beat.schedulers:DatabaseScheduler`), same wait. |
| `redis` | `redis:7-alpine` | Celery broker/result backend. |

## Getting the code onto a server

This repo is public, so no `git`/credentials are needed on the target server — a single
command downloads and extracts it, then you're straight into setup:

```bash
curl -fsSL https://raw.githubusercontent.com/Manufapp/foundry.custom/dev/install.sh | bash
cd foundry.custom
cp .env.server.example .env.server   # fill in real values
./manufapp.sh setup
IMAGE_TAG_FE=<fe_tag> IMAGE_TAG_BE=<be_tag> ./manufapp.sh start
```

The first line runs `install.sh` (in this repo), which pulls a tarball of the `dev`
branch and extracts it into `./foundry.custom`. Override the branch/tag or target
directory with `REF`/`DEST` env vars, e.g. `REF=v1.2.0 DEST=/opt/foundry.custom curl
... | bash`.

If you'd rather use `git` (e.g. to `git pull` updates later instead of re-running
`install.sh`), that works too:

```bash
git clone https://github.com/Manufapp/foundry.custom.git
```

## Prerequisites

1. **Docker + Docker Compose** on the target host.
2. **AWS CLI configured** with ECR pull access (`aws sts get-caller-identity` should work) — needed to `docker login` to ECR before pulling images.
3. **PostgreSQL already running on the host**, reachable from containers via
   `host.docker.internal` (wired up via `extra_hosts: host-gateway` in the compose
   file — no extra config needed on modern Docker), with the `DB_NAME`/`DB_USER`
   role+database created, `pg_trgm` enabled, and listening on the Docker bridge
   network (not just `localhost`).

On a fresh Ubuntu server missing any of the above, `./manufapp.sh setup` handles all
of it — skips anything already installed/configured, uses `sudo` automatically
unless already running as root:

```bash
./manufapp.sh setup
```

Specifically, `setup`:
- Installs Docker Engine + the Compose plugin, and AWS CLI v2, if missing.
- Runs `aws configure` (interactive) if `aws sts get-caller-identity` doesn't
  already succeed — skipped if credentials are already set up.
- Installs PostgreSQL, if missing (`psql` not already on `PATH`).
- Creates the `DB_USER` role and `DB_NAME` database (reading both from
  `.env.server` if it already exists, else defaulting to `caretaker`/`manufapp` —
  the same defaults `docker-compose.server.yml` itself falls back to), and sets
  `DB_USER`'s password to `DB_PASSWORD` (or `caretaker` if unset).
- Enables the `pg_trgm` extension on that database — needed for a GIN trigram
  index (`core.0002_auto_20260625_0555`); without it, `migrate` fails with
  `operator class "gin_trgm_ops" does not exist`.
- Sets `listen_addresses = '*'` in `postgresql.conf` and adds a `pg_hba.conf`
  entry for `172.16.0.0/12` (Docker's default bridge allocation range) if not
  already present, then restarts Postgres (`listen_addresses` needs a full
  restart, not just a `reload`, to take effect).

Run `./manufapp.sh setup` again any time — every step is idempotent (checked and
skipped if already done).

## Setup

```bash
cp .env.server.example .env.server   # then fill in real values — never commit this file
```

Key variables in `.env.server`:

| Variable | Purpose |
|---|---|
| `AWS_ACCOUNT_ID`, `AWS_REGION` | ECR account/region images are pulled from. |
| `ENV_NAME` | `local` \| `dev` \| `production` — controls Django settings branching (`foundry/settings.py`). **This matters a lot here — see the warning below.** |
| `DJANGO_SECRET_KEY` | Must match what the image was built expecting. |
| `DB_HOST`/`DB_NAME`/`DB_USER`/`DB_PASSWORD`/`DB_PORT` | Bare-metal Postgres connection info. |
| `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_DEFAULT_REGION`/`AWS_PROFILE` | Only needed if this environment uses S3 (documents, audit logs, etc.). The compose file mounts the host's `~/.aws` read-only into `django`/`celery`/`celery-beat` and points `AWS_SHARED_CREDENTIALS_FILE`/`AWS_CONFIG_FILE` at it, so **the profile from `./manufapp.sh setup`'s `aws configure` step (or one you ran yourself) is used automatically** — leave the keys blank and, if needed, set only `AWS_PROFILE` (defaults to `default`) to pick a non-default named profile. Set `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` explicitly only if this container needs a *different* identity than the host's own profile — they take priority over the mounted one when set. |

> **`ENV_NAME=production` warning:** `foundry/settings.py` ties `SECURE_SSL_REDIRECT`
> (and `SESSION_COOKIE_SECURE`/`CSRF_COOKIE_SECURE`) directly to `DEBUG=False`, which
> is what `production` (or any value other than `local`/`dev`/`test`) sets. This
> stack's `nginx` does **not** terminate TLS — it's plain HTTP path-routing only. If
> you use `ENV_NAME=production` without a real TLS terminator in front (either
> extending `nginx/nginx.conf` with a cert, or an upstream load balancer that sets
> `X-Forwarded-Proto: https`), every request will 301-redirect to `https://` and
> nothing will serve it — the app becomes completely unreachable, and the `django`
> health check will never pass. Use `ENV_NAME=local` for testing on a box without TLS
> in front; only use `production` once real TLS termination exists somewhere upstream.

`IMAGE_TAG_FE`/`IMAGE_TAG_BE` are **not** set in `.env.server` — they're required
env vars passed on the command line to `./manufapp.sh start`/`restart`, e.g.:
```bash
IMAGE_TAG_FE=1.39.0 IMAGE_TAG_BE=v1.39.0 ./manufapp.sh start
```
so the image versions actually running are always an explicit, visible part of the
command rather than buried in a file. Note `IMAGE_TAG_BE` needs **any `v` prefix it
was actually pushed with** (e.g. `v1.39.0`) — the compose file uses the value as-is,
it does not add a prefix.

## Why nginx

`foundry.react` calls its API using a **same-origin relative path**
(`NEXT_PUBLIC_DRF=/api`, see `foundry.react/.env.production` and
`components/axios.js`) — it expects one origin to serve both the app and the API,
split by path. Next.js's own `rewrites()` only proxies `/feapi/*` back to its own
`/api/*` routes (small custom endpoints under `pages/api/`); it does **not** proxy
the real `/api/v2/...` REST calls to Django. Without a router in front, hitting the
app on react's own port (`:3000`) sends those API calls to Next.js itself, which
404s them.

`nginx/nginx.conf` is that router: it listens on `:80` and forwards `/api/*` and
`/ws/*` (Django Channels websocket routes — see `core/routing.py`) to `django:8000`,
and everything else to `react:3000`. **Access the app at `http://localhost` (or the
server's hostname), not `:3000` directly.** `./manufapp.sh start` prints the local
network IP (and, best-effort, this host's public IP) to hit at the end, so you don't
have to go look it up separately — the public one is only actually reachable if this
host's firewall/router forwards port `80` to it.

## Running it

Use `manufapp.sh`, or the raw `docker compose` commands it wraps.

### manufapp.sh

```bash
./manufapp.sh setup      # Ubuntu only - install/configure Docker, AWS CLI v2, Postgres

# start/restart need IMAGE_TAG_FE/IMAGE_TAG_BE as env vars - not read from .env.server
IMAGE_TAG_FE=1.39.0 IMAGE_TAG_BE=v1.39.0 ./manufapp.sh start     # aws ecr login, pull those image tags, up -d, then show status + access URL(s)
IMAGE_TAG_FE=1.39.0 IMAGE_TAG_BE=v1.39.0 ./manufapp.sh restart   # stop, then start with those tags

./manufapp.sh stop       # docker compose down
./manufapp.sh status     # docker compose ps
./manufapp.sh logs [service...]   # follow logs — all services, or just the ones named
                                   # e.g. ./manufapp.sh logs django celery
./manufapp.sh record-version   # record the running BE/FE versions (start does this itself)
./manufapp.sh remove     # undo setup - see "Removing it" below
```

`start` records the running BE/FE image versions and deploy time in Firestore
`platform_versions/<SERVER_NAME>`. That feeds the in-app App Versions drawer and the infra
"Deployed versions" page (`infra/server-control` in the foundry superproject), which lists every
server in one place. Set `SERVER_NAME` (e.g. `ambrane`) in `.env.server` once per box. If you
deploy with raw `docker compose ... up -d` instead of `start`, run `./manufapp.sh record-version`
afterwards.

### Removing it

`./manufapp.sh remove` undoes what `setup`/`start` provisioned, most destructive last:

1. Always: stops and removes this stack's containers, network, and volumes
   (`docker compose down -v --remove-orphans`) — safe, `redis`'s volume is just
   Celery broker/result state, nothing this app can't regenerate.
2. Asks for confirmation, then (if confirmed) drops the `DB_NAME` database and
   `DB_USER` role, and reverts the `listen_addresses`/`pg_hba.conf` changes made
   for Docker connectivity — **this destroys real application data**, skipped by
   default (including when run non-interactively, e.g. piped from `curl`, where
   it can't prompt at all).
3. Asks for confirmation, then (if confirmed) uninstalls Docker Engine, the
   PostgreSQL server package, and AWS CLI v2, and clears this user's `~/.aws` —
   skipped by default since these are host-wide and may be used by other things
   on the same box.

Each of steps 2 and 3 requires literally typing `yes` at its prompt — anything else
(including no input at all) is treated as "no."

### Equivalent raw docker compose commands

```bash
aws ecr get-login-password --region ${AWS_REGION:-ap-south-1} | \
  docker login --username AWS --password-stdin ${AWS_ACCOUNT_ID:-002429227764}.dkr.ecr.${AWS_REGION:-ap-south-1}.amazonaws.com

export IMAGE_TAG_FE=1.39.0 IMAGE_TAG_BE=v1.39.0   # required - not read from .env.server
docker compose --env-file .env.server -f docker-compose.server.yml pull
docker compose --env-file .env.server -f docker-compose.server.yml up -d
docker compose --env-file .env.server -f docker-compose.server.yml ps
docker compose --env-file .env.server -f docker-compose.server.yml logs -f [service...]
docker compose --env-file .env.server -f docker-compose.server.yml down
```

## Notes / gotchas

- **First boot is slow.** `django`'s startup (`migrate` + `uvicorn` import) can take
  several minutes the first time a container starts — the app instantiates several
  boto3 clients (S3, SQS) at import time. The health check (`retries: 60`,
  `interval: 5s` ≈ 5 minute budget) may time out on an unusually slow first boot,
  which stops `celery`/`celery-beat` from starting since they wait on
  `django: condition: service_healthy`. If that happens, just re-run
  `IMAGE_TAG_FE=... IMAGE_TAG_BE=... ./manufapp.sh start` (or `docker compose ... up -d`)
  once `django` shows healthy in `docker ps` — Compose will bring up the remaining
  services without re-pulling.
- **`celery-beat` catches up on missed schedules.** Any periodic task that was due
  while the stack was down fires immediately on the next `celery-beat` start. If any
  of those are `sendmail`/report tasks pointed at real recipients, expect a burst of
  emails after a restart that was down a while.
- Direct ports `:8000` (django) and `:3000` (react) are still exposed for debugging,
  but the app itself should be accessed through nginx on `:80`.
