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

## Prerequisites

1. **Docker + Docker Compose** on the target host.
2. **AWS CLI configured** with ECR pull access (`aws sts get-caller-identity` should work) — needed to `docker login` to ECR before pulling images.
3. **PostgreSQL already running on the host**, reachable from containers via
   `host.docker.internal` (wired up via `extra_hosts: host-gateway` in the compose
   file — no extra config needed on modern Docker).
   - The database and role referenced by `DB_NAME`/`DB_USER`/`DB_PASSWORD` must
     already exist.
   - **One-time extension**, before the first `migrate` — a fresh Postgres install
     doesn't have this, and migration `core.0002_auto_20260625_0555` needs it for a
     GIN trigram index (fails with `operator class "gin_trgm_ops" does not exist`
     otherwise):
     ```bash
     psql -U <DB_USER> -d <DB_NAME> -c "CREATE EXTENSION IF NOT EXISTS pg_trgm;"
     ```
   - **Postgres must accept connections from the Docker bridge network**, not just
     `localhost` — a default install only listens on `localhost` and only trusts
     `127.0.0.1` in `pg_hba.conf`. Set `listen_addresses = '*'` in `postgresql.conf`,
     add a `pg_hba.conf` entry allowing the Docker bridge subnet (`md5`/`scram`
     auth), then **restart** Postgres (`listen_addresses` needs a full restart, not
     just `reload`).

## Setup

```bash
cp .env.server.example .env.server   # then fill in real values — never commit this file
```

Key variables in `.env.server`:

| Variable | Purpose |
|---|---|
| `AWS_ACCOUNT_ID`, `AWS_REGION` | ECR account/region images are pulled from. |
| `IMAGE_TAG_FE` | `foundry.react` image tag (e.g. `1.39.0`). |
| `IMAGE_TAG_BE` | `foundry.django` image tag, **including any `v` prefix** it was actually pushed with (e.g. `v1.39.0`) — the compose file uses this value as-is, it does not add a prefix. |
| `ENV_NAME` | `local` \| `dev` \| `production` — controls Django settings branching (`foundry/settings.py`). **This matters a lot here — see the warning below.** |
| `DJANGO_SECRET_KEY` | Must match what the image was built expecting. |
| `DB_HOST`/`DB_NAME`/`DB_USER`/`DB_PASSWORD`/`DB_PORT` | Bare-metal Postgres connection info. |
| `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_DEFAULT_REGION` | Only needed if this environment uses S3 (documents, audit logs, etc.) — leave blank to skip. These are passed to the django container directly as env vars; **do not** also set `AWS_PROFILE` in the container's environment — there's no `~/.aws/credentials` mounted inside it, so boto3 will fail with `ProfileNotFound` even though the access key/secret alone are sufficient. (A host-level `AWS_PROFILE` in your own shell, used for the `aws ecr get-login-password` step, is unrelated and fine.) |

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
server's hostname), not `:3000` directly.**

## Running it

Use `manufapp.sh`, or the raw `docker compose` commands it wraps.

### manufapp.sh

```bash
./manufapp.sh start     # aws ecr login, pull latest images, up -d, then show status
./manufapp.sh stop      # docker compose down
./manufapp.sh restart   # stop, then start
./manufapp.sh status    # docker compose ps
./manufapp.sh logs [service...]   # follow logs — all services, or just the ones named
                                   # e.g. ./manufapp.sh logs django celery
```

### Equivalent raw docker compose commands

```bash
aws ecr get-login-password --region ${AWS_REGION:-ap-south-1} | \
  docker login --username AWS --password-stdin ${AWS_ACCOUNT_ID:-002429227764}.dkr.ecr.${AWS_REGION:-ap-south-1}.amazonaws.com

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
  `./manufapp.sh start` (or `docker compose ... up -d`) once `django` shows healthy
  in `docker ps` — Compose will bring up the remaining services without re-pulling.
- **`celery-beat` catches up on missed schedules.** Any periodic task that was due
  while the stack was down fires immediately on the next `celery-beat` start. If any
  of those are `sendmail`/report tasks pointed at real recipients, expect a burst of
  emails after a restart that was down a while.
- Direct ports `:8000` (django) and `:3000` (react) are still exposed for debugging,
  but the app itself should be accessed through nginx on `:80`.
