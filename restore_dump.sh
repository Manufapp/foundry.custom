#!/usr/bin/env bash
# restore_dump.sh - replace this on-prem server's database with a company dump made by
# foundry.django's company_dump.sh, fetched from Google Drive (or a local file).
#
# Usage:
#   ./restore_dump.sh <google-drive-link | drive-file-id | /path/to/dump.sql[.gz|.zip]> [options]
#   ./restore_dump.sh --rollback backups/pre_restore_<db>_<timestamp>.dump [--yes]
#
# Options:
#   --yes, -y      don't ask for confirmation (scripted runs)
#   --no-backup    skip the pg_dump of the current database taken before anything is dropped
#   --keep-files   keep the downloaded / prepared dump in restore-work/ after a successful run
#   --rollback F   put back a backup this script took (backups/pre_restore_*.dump)
#
# Env:
#   IMAGE_TAG_BE   BE image tag to run migrations with. Default: the tag the stack's
#                  django container currently runs. Must be the tag you deploy with.
#   RESTORE_DB_HOST, RESTORE_DB_PORT  host/port this script's own psql uses to reach Postgres. Default:
#                  127.0.0.1 when DB_HOST in .env.server is host.docker.internal/localhost,
#                  else DB_HOST itself.
#
# Google Drive: upload the dump (plain .sql, or .sql.gz / .zip to make it smaller), then
# Share -> General access -> "Anyone with the link" (Viewer), and pass the share link.
# Turn link sharing off again once the restore is done - the dump holds customer data.
#
# What it does (DB credentials come from .env.server, same as the app):
#   1. Downloads + unpacks the dump, checks it is a complete company_dump.sh file
#   2. Shows what will be replaced and asks you to type 'yes'
#   3. Backs up the current DB to backups/ (pg_dump -Fc)
#   4. Stops django/celery/celery-beat
#   5. Drops the public schema, recreates it (+ pg_trgm), runs `manage.py migrate`
#      with the BE image, reads model field defaults from it
#   6. Filters the dump to the migrated schema (restore/prepare_dump.py), loads it
#      with psql, then checks every table's row count against the dump
#   7. Starts django/celery/celery-beat again and restarts nginx
#
# Examples (the full sequence - steps 1-2 on a machine with DB access to the source,
# step 3+ on the on-prem server, from this foundry.custom folder):
#
#   # 1. Dump company 2 from the source DB (foundry.django/company_dump.sh; through an
#   #    SSH tunnel on localhost:2345 here - RDS needs PGSSLMODE=require):
#   PGSSLMODE=require DB_HOST=localhost DB_PORT=2345 DB_USER=caretaker DB_NAME=manufapp \
#     DB_PASSWORD='<source db password>' ENV_NAME=prod ./company_dump.sh 2
#   #    -> company_2_dump_20261104_151156.sql   (several companies: ./company_dump.sh 2,303)
#
#   # 2. Compress it, upload it to Google Drive, share "Anyone with the link" (Viewer):
#   gzip -9 company_2_dump_20261104_151156.sql
#
#   # 3. Restore on the server - the BE image tag is taken from the running django container:
#   ./restore_dump.sh 'https://drive.google.com/file/d/1AbCdEfGhIjKlMnOpQrStUvWxYz012345/view?usp=sharing'
#
#   #    ...or pin the BE image (must be the tag you deploy with, e.g. the source env's):
#   IMAGE_TAG_BE=v1.46.0.4 ./restore_dump.sh 'https://drive.google.com/file/d/1AbCdEfGhIjKlMnOpQrStUvWxYz012345/view'
#
#   #    ...or from a file already on the server, without prompting:
#   ./restore_dump.sh ~/company_2_dump_20261104_151156.sql.gz --yes
#
#   # 4. Undo it - put back the backup step 3 took:
#   ./restore_dump.sh --rollback backups/pre_restore_manufapp_20261104_153012.dump
#
#   # Same thing through the wrapper:
#   ./manufapp.sh restore 'https://drive.google.com/file/d/1AbCdEfGhIjKlMnOpQrStUvWxYz012345/view'

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"
HERE=$(pwd)
ENV_FILE=.env.server
COMPOSE_FILE=docker-compose.server.yml
WORK_DIR="$HERE/restore-work"
BACKUP_DIR="$HERE/backups"
TS=$(date +%Y%m%d_%H%M%S)
APP_SERVICES=(django celery celery-beat)

log()  { echo "[$(date +%T)] $*"; }
warn() { echo "[$(date +%T)] WARN: $*" >&2; }
die()  { echo "[$(date +%T)] ERROR: $*" >&2; exit 1; }

usage() {
  sed -n '2,/^$/{s/^# \{0,1\}//;p}' "${BASH_SOURCE[0]}" | sed '/^set -euo/,$d'
  exit "${1:-1}"
}

# ── Args ──────────────────────────────────────────────────────────────────────
SOURCE=""; ROLLBACK=""; ASSUME_YES=0; DO_BACKUP=1; KEEP_FILES=0
while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes)     ASSUME_YES=1 ;;
    --no-backup)  DO_BACKUP=0 ;;
    --keep-files) KEEP_FILES=1 ;;
    --rollback)   [ $# -ge 2 ] || die "--rollback needs a backup file"; ROLLBACK="$2"; shift ;;
    -h|--help)    usage 0 ;;
    -*)           die "unknown option: $1 (see --help)" ;;
    *)            [ -z "$SOURCE" ] || die "only one dump source allowed, got '$SOURCE' and '$1'"; SOURCE="$1" ;;
  esac
  shift
done
[ -n "$SOURCE" ] || [ -n "$ROLLBACK" ] || usage 1
[ -z "$SOURCE" ] || [ -z "$ROLLBACK" ] || die "give either a dump source or --rollback, not both"

# ── Config (.env.server, same file the stack runs with) ───────────────────────
[ -f "$ENV_FILE" ] || die "missing $ENV_FILE - copy .env.server.example to $ENV_FILE and fill it in first"

get_env() {
  local key="$1" default="$2" val=""
  val=$(grep -E "^${key}=" "$ENV_FILE" | tail -1 | cut -d= -f2- || true)
  val="${val%$'\r'}"
  if [[ "$val" =~ ^\"(.*)\"$ ]] || [[ "$val" =~ ^\'(.*)\'$ ]]; then val="${BASH_REMATCH[1]}"; fi
  echo "${val:-$default}"
}

DB_HOST=$(get_env DB_HOST host.docker.internal)
DB_NAME=$(get_env DB_NAME manufapp)
DB_USER=$(get_env DB_USER caretaker)
DB_PASSWORD=$(get_env DB_PASSWORD "")
DB_PORT=$(get_env DB_PORT 5432)
AWS_REGION=$(get_env AWS_REGION ap-south-1)
AWS_ACCOUNT_ID=$(get_env AWS_ACCOUNT_ID 002429227764)
[ -n "$DB_PASSWORD" ] || die "DB_PASSWORD is empty in $ENV_FILE"

# The app reaches the host's Postgres as host.docker.internal; this script runs on the
# host itself, where that name doesn't resolve.
case "$DB_HOST" in
  host.docker.internal|localhost|127.0.0.1) DB_IS_LOCAL=1; PG_HOST=127.0.0.1 ;;
  *)                                        DB_IS_LOCAL=0; PG_HOST="$DB_HOST" ;;
esac
PG_HOST="${RESTORE_DB_HOST:-$PG_HOST}"
PG_PORT="${RESTORE_DB_PORT:-$DB_PORT}"
export PGPASSWORD="$DB_PASSWORD"
PG_CONN=(-h "$PG_HOST" -p "$PG_PORT" -U "$DB_USER" -d "$DB_NAME")
PSQL=(psql "${PG_CONN[@]}" -X -v ON_ERROR_STOP=1)

COMPOSE=(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE")

need() { command -v "$1" >/dev/null 2>&1 || die "'$1' not found - $2"; }
need docker   "install Docker first (./manufapp.sh setup)"
need psql     "install the PostgreSQL client (apt install postgresql-client)"
need python3  "install python3"
need curl     "install curl"

"${PSQL[@]}" -Atc "SELECT 1" >/dev/null 2>"$HERE/.restore_conn.err" || {
  cat "$HERE/.restore_conn.err" >&2; rm -f "$HERE/.restore_conn.err"
  die "cannot connect to Postgres as $DB_USER@$PG_HOST:$PG_PORT/$DB_NAME (credentials from $ENV_FILE)"
}
rm -f "$HERE/.restore_conn.err"

mkdir -p "$WORK_DIR" "$BACKUP_DIR"
chmod 700 "$WORK_DIR" "$BACKUP_DIR"

# ── BE image: the one the stack runs, so migrate builds exactly its schema ────
DJANGO_CID=$("${COMPOSE[@]}" ps -a -q django 2>/dev/null | head -1 || true)
WAS_RUNNING=0
if [ -n "$DJANGO_CID" ] && [ "$(docker inspect -f '{{.State.Running}}' "$DJANGO_CID" 2>/dev/null)" = "true" ]; then
  WAS_RUNNING=1
fi
if [ -z "${IMAGE_TAG_BE:-}" ] && [ -n "$DJANGO_CID" ]; then
  current_image=$(docker inspect -f '{{.Config.Image}}' "$DJANGO_CID")
  IMAGE_TAG_BE="${current_image##*:}"
fi
# Rollback never runs the image (and only restarts a stack that was running, whose tag
# we just read), so only a restore needs one.
[ -n "${IMAGE_TAG_BE:-}" ] || [ -n "$ROLLBACK" ] \
  || die "no django container found - set IMAGE_TAG_BE=<be tag> (the tag you start the stack with)"
IMAGE_TAG_BE="${IMAGE_TAG_BE:-}"
export IMAGE_TAG_BE
BE_IMAGE="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/foundry.django:${IMAGE_TAG_BE}"

ensure_be_image() {
  docker image inspect "$BE_IMAGE" >/dev/null 2>&1 && return 0
  log "Pulling $BE_IMAGE ..."
  need aws "install AWS CLI v2 (./manufapp.sh setup) to pull from ECR"
  aws ecr get-login-password --region "$AWS_REGION" \
    | docker login --username AWS --password-stdin "${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com" >/dev/null
  "${COMPOSE[@]}" pull django
}

# Runs a one-off command in the django service (same env/network/volumes as the app).
run_be() { "${COMPOSE[@]}" run --rm -T -e DISABLE_IO=true django "$@"; }

confirm() {
  [ "$ASSUME_YES" = 1 ] && return 0
  local reply=""
  read -r -p "$1 [type 'yes' to continue]: " reply || true
  [ "$reply" = "yes" ]
}

# ── Failure reporting ─────────────────────────────────────────────────────────
DB_TOUCHED=0; APP_STOPPED=0; BACKUP=""
CLEANUP=()   # files this run created that hold customer data (dump copies)
on_exit() {
  local rc=$?
  [ $rc -eq 0 ] && return
  # A failed or aborted run re-downloads next time - don't leave customer data behind.
  [ "$KEEP_FILES" = 1 ] || rm -f "${CLEANUP[@]}"
  [ "$DB_TOUCHED" = 1 ] || [ "$APP_STOPPED" = 1 ] || return
  echo >&2
  echo "────────────────────────────────────────────────────────────────" >&2
  echo "FAILED (exit $rc). Logs: $WORK_DIR/" >&2
  if [ "$DB_TOUCHED" = 1 ]; then
    echo "The database '$DB_NAME' was already modified." >&2
    if [ -n "$BACKUP" ] && [ -f "$BACKUP" ]; then
      echo "Put the previous data back with:" >&2
      echo "  ./restore_dump.sh --rollback $BACKUP" >&2
    fi
  fi
  if [ "$APP_STOPPED" = 1 ]; then
    echo "django/celery/celery-beat are stopped. Start them with:" >&2
    echo "  IMAGE_TAG_BE=$IMAGE_TAG_BE docker compose --env-file $ENV_FILE -f $COMPOSE_FILE up -d ${APP_SERVICES[*]}" >&2
  fi
}
trap on_exit EXIT

stop_app() {
  log "Stopping ${APP_SERVICES[*]} ..."
  "${COMPOSE[@]}" stop "${APP_SERVICES[@]}" >/dev/null 2>&1 || true
  APP_STOPPED=$WAS_RUNNING
}

start_app() {
  if [ "$WAS_RUNNING" != 1 ]; then
    APP_STOPPED=0
    log "The stack wasn't running before, leaving it stopped. Start it with:"
    log "  IMAGE_TAG_FE=<fe_tag> IMAGE_TAG_BE=$IMAGE_TAG_BE ./manufapp.sh start"
    return
  fi
  log "Starting ${APP_SERVICES[*]} (django re-checks migrations, then celery waits for it) ..."
  "${COMPOSE[@]}" up -d "${APP_SERVICES[@]}"
  APP_STOPPED=0
  # nginx caches the old container IPs and 502s until it restarts.
  if [ -n "$("${COMPOSE[@]}" ps -q nginx 2>/dev/null)" ]; then
    "${COMPOSE[@]}" restart nginx >/dev/null
    log "Restarted nginx."
  fi
}

# Empty the public schema. Tables are dropped one statement at a time first: a single
# DROP SCHEMA CASCADE takes a lock per table/index/sequence in one transaction and can
# overflow a small server's lock table ("out of shared memory").
reset_schema() {
  log "Dropping every table in '$DB_NAME' ..."
  DB_TOUCHED=1
  "${PSQL[@]}" -At -c "SELECT format('DROP TABLE IF EXISTS public.%I CASCADE;', tablename) FROM pg_tables WHERE schemaname = 'public'" \
    | PGOPTIONS='-c client_min_messages=warning' "${PSQL[@]}" -q

  log "Recreating the public schema + pg_trgm ..."
  # Works as the DB owner on PG15+ (public is owned by pg_database_owner, pg_trgm is a
  # trusted extension). Older/odd setups fall back to the postgres superuser.
  if ! PGOPTIONS='-c client_min_messages=warning' "${PSQL[@]}" -q -c \
      "DROP SCHEMA public CASCADE; CREATE SCHEMA public; GRANT ALL ON SCHEMA public TO \"$DB_USER\"; GRANT ALL ON SCHEMA public TO public; CREATE EXTENSION IF NOT EXISTS pg_trgm;" \
      2>"$WORK_DIR/reset_schema.err"; then
    [ "$DB_IS_LOCAL" = 1 ] && command -v sudo >/dev/null 2>&1 \
      || { cat "$WORK_DIR/reset_schema.err" >&2; die "could not recreate the public schema as $DB_USER"; }
    log "  ($DB_USER can't do that - retrying as the postgres superuser via sudo)"
    sudo -u postgres env PGOPTIONS='-c client_min_messages=warning' psql -X -q -v ON_ERROR_STOP=1 -d "$DB_NAME" -c \
      "DROP SCHEMA public CASCADE; CREATE SCHEMA public AUTHORIZATION \"$DB_USER\"; GRANT ALL ON SCHEMA public TO public; CREATE EXTENSION IF NOT EXISTS pg_trgm;"
  fi
}

backup_db() {
  if [ "$DO_BACKUP" != 1 ]; then
    warn "--no-backup: the current database will NOT be recoverable"
    return
  fi
  need pg_dump "install the PostgreSQL client, or rerun with --no-backup"
  BACKUP="$BACKUP_DIR/pre_restore_${DB_NAME}_${TS}.dump"
  log "Backing up current '$DB_NAME' -> $BACKUP ..."
  if ! pg_dump "${PG_CONN[@]}" -Fc -f "$BACKUP" 2>"$WORK_DIR/backup.err"; then
    cat "$WORK_DIR/backup.err" >&2
    rm -f "$BACKUP"; BACKUP=""
    die "backup failed (a pg_dump older than the server can't dump it - install postgresql-client-<server version>), or rerun with --no-backup"
  fi
  chmod 600 "$BACKUP"
  log "Backup done ($(du -h "$BACKUP" | cut -f1))."
}

current_db_summary() {
  local companies
  companies=$("${PSQL[@]}" -At -c "SELECT string_agg('[' || id || '] ' || name, ', ' ORDER BY id) FROM (SELECT id, name FROM companies ORDER BY id LIMIT 15) c" 2>/dev/null || true)
  echo "${companies:-(no companies table - empty or fresh database)}"
}

# ══════════════════════════════════════════════════════════════════════════════
# Rollback mode
# ══════════════════════════════════════════════════════════════════════════════
if [ -n "$ROLLBACK" ]; then
  [ -f "$ROLLBACK" ] || die "backup not found: $ROLLBACK"
  need pg_restore "install the PostgreSQL client"
  pg_restore -l "$ROLLBACK" >/dev/null 2>&1 || die "$ROLLBACK is not a pg_dump custom-format (-Fc) file"
  echo
  echo "  Target DB : $DB_NAME @ $PG_HOST:$PG_PORT (user $DB_USER)"
  echo "  Now holds : $(current_db_summary)"
  echo "  Restore   : $ROLLBACK"
  echo
  confirm "This REPLACES everything in '$DB_NAME' with that backup." || die "Aborted."
  DO_BACKUP=0
  stop_app
  reset_schema
  log "Restoring $ROLLBACK ..."
  # Expected, harmless errors: CREATE/COMMENT ON EXTENSION entries a non-superuser can't
  # replay on the already-present pg_trgm, and settings a newer pg_dump writes that an
  # older server doesn't know (e.g. pg_dump 17's transaction_timeout on PG 16).
  pg_restore "${PG_CONN[@]}" --no-owner --no-acl -j 4 "$ROLLBACK" 2>"$WORK_DIR/rollback_errors.log" || true
  harmless='extension|unrecognized configuration parameter'
  real_errors=$(grep -E 'error:' "$WORK_DIR/rollback_errors.log" | grep -vEc "$harmless" || true)
  if [ "${real_errors:-0}" -gt 0 ]; then
    grep -E 'error:' "$WORK_DIR/rollback_errors.log" | grep -vE "$harmless" | head -20 >&2
    die "pg_restore reported $real_errors error(s) - see $WORK_DIR/rollback_errors.log"
  fi
  DB_TOUCHED=0
  log "Database now holds: $(current_db_summary)"
  start_app
  log "Rollback done."
  exit 0
fi

# ══════════════════════════════════════════════════════════════════════════════
# Restore mode
# ══════════════════════════════════════════════════════════════════════════════

# Accepts https://drive.google.com/file/d/<id>/view?..., .../open?id=<id>, uc?id=<id>,
# drive.usercontent.google.com/download?id=<id>, or a bare file id.
drive_file_id() {
  local s="$1"
  if   [[ "$s" =~ /file/d/([A-Za-z0-9_-]{20,}) ]]; then echo "${BASH_REMATCH[1]}"
  elif [[ "$s" =~ [?\&]id=([A-Za-z0-9_-]{20,}) ]]; then echo "${BASH_REMATCH[1]}"
  elif [[ "$s" =~ ^[A-Za-z0-9_-]{20,}$ ]];          then echo "$s"
  else return 1
  fi
}

# ── 1. Fetch ──────────────────────────────────────────────────────────────────
if [ -f "$SOURCE" ]; then
  RAW="$SOURCE"
  log "Using local file $RAW ($(du -h "$RAW" | cut -f1))"
else
  FILE_ID=$(drive_file_id "$SOURCE") || die "'$SOURCE' is neither an existing file nor a Google Drive link / file id"
  RAW="$WORK_DIR/drive_${FILE_ID}_${TS}.download"
  CLEANUP+=("$RAW")
  log "Downloading Google Drive file $FILE_ID ..."
  # confirm=t skips Drive's "can't scan this file for viruses" page on files >100 MB.
  curl -fL --retry 3 --progress-bar -o "$RAW" \
    "https://drive.usercontent.google.com/download?id=${FILE_ID}&export=download&confirm=t" \
    || die "download failed - check the link, and that the file is shared as 'Anyone with the link'"
  # A file that isn't shared publicly comes back as a Google sign-in / error web page.
  head_bytes=$(head -c 1024 "$RAW" | tr -d '\0' | tr '[:upper:]' '[:lower:]')
  if [[ "$head_bytes" == *"<html"* ]] || [[ "$head_bytes" == *"<!doctype html"* ]]; then
    die "Google Drive returned a web page instead of the file - set the file's sharing to 'Anyone with the link' (Viewer) and check the link"
  fi
  log "Downloaded $(du -h "$RAW" | cut -f1)."
fi

# ── Unpack (.gz / .zip, detected by content, not by name) ─────────────────────
DUMP="$RAW"
magic=$(od -An -tx1 -N4 "$RAW" | tr -d ' \n')
case "$magic" in
  1f8b*)
    need gunzip "install gzip"
    DUMP="$WORK_DIR/dump_${TS}.sql"; CLEANUP+=("$DUMP")
    log "Decompressing (gzip) ..."
    gunzip -c "$RAW" > "$DUMP"
    ;;
  504b0304)
    need unzip "install unzip (apt install unzip)"
    mapfile -t sql_entries < <(unzip -Z1 "$RAW" | grep -E '\.sql$' || true)
    [ "${#sql_entries[@]}" -eq 1 ] || die "zip must contain exactly one .sql file, found ${#sql_entries[@]}: ${sql_entries[*]:-none}"
    DUMP="$WORK_DIR/dump_${TS}.sql"; CLEANUP+=("$DUMP")
    log "Extracting ${sql_entries[0]} from zip ..."
    unzip -p "$RAW" "${sql_entries[0]}" > "$DUMP"
    ;;
esac
chmod 600 "${CLEANUP[@]}" 2>/dev/null || true

# ── Validate: must be a complete company_dump.sh file ─────────────────────────
head -n 3 "$DUMP" | grep -q '^-- Company dump' \
  || die "not a company_dump.sh dump (no '-- Company dump' header in the first lines)"
DUMP_COMPANIES=$(head -n 200 "$DUMP" | sed -n '3,/^-- Generated/p' | { grep -E '^--   \[' || true; } | sed 's/^--   //' | paste -sd ',' - | sed 's/,/, /g')
DUMP_GENERATED=$(grep -m1 '^-- Generated:' "$DUMP" | sed 's/^-- Generated: *//' || true)
DUMP_SOURCE=$(grep -m1 '^-- Source DB:' "$DUMP" | sed 's/^-- Source DB: *//' || true)
COPY_BLOCKS=$(grep -c '^COPY "' "$DUMP" || true)
[ "${COPY_BLOCKS:-0}" -gt 0 ] || die "dump has no data (no COPY blocks)"
# company_dump.sh always ends with this line - missing means a truncated upload/download.
tail -n 5 "$DUMP" | grep -q "^SET session_replication_role = DEFAULT;" \
  || die "dump looks truncated (doesn't end with company_dump.sh's footer) - re-upload / re-download it"
grep -q '^-- Fix dangling user-FK references' "$DUMP" \
  || warn "dump has no fix-up footer (older company_dump.sh) - tags may show on the wrong records"

# ── 2. Confirm ────────────────────────────────────────────────────────────────
dump_bytes=$(stat -c %s "$DUMP")
free_bytes=$(( $(df -Pk "$WORK_DIR" | awk 'NR==2{print $4}') * 1024 ))
if [ "$free_bytes" -lt $(( dump_bytes * 3 )) ]; then
  warn "only $(( free_bytes / 1024 / 1024 )) MB free in $WORK_DIR - the restore needs roughly 3x the dump size ($(( dump_bytes * 3 / 1024 / 1024 )) MB)"
fi

echo
echo "  Dump        : $(du -h "$DUMP" | cut -f1), $COPY_BLOCKS table blocks, generated $DUMP_GENERATED"
echo "  Companies   : $DUMP_COMPANIES"
echo "  From        : $DUMP_SOURCE"
echo "  Target DB   : $DB_NAME @ $PG_HOST:$PG_PORT (user $DB_USER)"
echo "  Now holds   : $(current_db_summary)"
echo "  BE image    : $BE_IMAGE"
echo "  Backup      : $([ "$DO_BACKUP" = 1 ] && echo "yes -> $BACKUP_DIR/" || echo "NO (--no-backup)")"
echo
confirm "This DELETES everything in '$DB_NAME' and replaces it with the dump." || die "Aborted - nothing was changed."

ensure_be_image

# The app container reaches Postgres differently from this script (host.docker.internal
# over the Docker bridge) - prove that path works before anything is dropped, or a
# firewall / pg_hba / listen_addresses problem only surfaces after the DB is gone.
log "Checking the BE container can reach the database ..."
if ! "${COMPOSE[@]}" run --rm -T -e DISABLE_IO=true -e PGCONNECT_TIMEOUT=15 django \
     python manage.py shell -c "from django.db import connection; connection.ensure_connection(); print('DB_REACHABLE')" \
     >"$WORK_DIR/preflight.log" 2>&1 \
   || ! grep -q '^DB_REACHABLE' "$WORK_DIR/preflight.log"; then
  tail -5 "$WORK_DIR/preflight.log" >&2
  die "the django container can't connect to $DB_HOST:$DB_PORT - fix that first (./manufapp.sh start sets up listen_addresses/pg_hba.conf). Nothing was changed."
fi

# ── 3-4. Backup, stop the app ─────────────────────────────────────────────────
backup_db
stop_app

# ── 5. Fresh schema from the BE image ─────────────────────────────────────────
reset_schema
log "Running migrations with foundry.django:$IMAGE_TAG_BE (fresh DB: can take 20-30 min) ..."
if ! run_be python manage.py migrate --noinput >"$WORK_DIR/migrate.log" 2>&1; then
  tail -30 "$WORK_DIR/migrate.log" >&2
  die "migrate failed - see $WORK_DIR/migrate.log"
fi
log "Migrations applied ($(grep -c '  Applying ' "$WORK_DIR/migrate.log" || true) migrations)."

log "Reading model field defaults from the image ..."
FIELD_DEFAULTS="$WORK_DIR/field_defaults.tsv"
run_be python manage.py shell <"$HERE/restore/field_defaults.py" 2>"$WORK_DIR/field_defaults.err" \
  | grep '^FIELD_DEFAULT' >"$FIELD_DEFAULTS" || true
n_defaults=$(wc -l <"$FIELD_DEFAULTS")
if [ "$n_defaults" -eq 0 ]; then
  warn "got no field defaults (see $WORK_DIR/field_defaults.err) - columns newer than the dump stay NULL and may reject rows"
else
  log "  $n_defaults model column defaults."
fi

# ── 6. Prepare + load ─────────────────────────────────────────────────────────
READY="$WORK_DIR/dump_ready_${TS}.sql"; CLEANUP+=("$READY")
EXPECTED="$WORK_DIR/expected_counts.tsv"
log "Preparing the dump for this schema ..."
if ! DB_HOST="$PG_HOST" DB_PORT="$PG_PORT" DB_USER="$DB_USER" DB_NAME="$DB_NAME" \
     FIELD_DEFAULTS="$FIELD_DEFAULTS" EXPECTED_COUNTS="$EXPECTED" \
     python3 -I "$HERE/restore/prepare_dump.py" <"$DUMP" >"$READY" 2>"$WORK_DIR/prepare.log"; then
  cat "$WORK_DIR/prepare.log" >&2
  die "prepare_dump.py failed"
fi
chmod 600 "$READY"
n_skip=$(grep -c '^\[SKIP\]' "$WORK_DIR/prepare.log" || true)
n_filter=$(grep -c '^\[FILTER\]' "$WORK_DIR/prepare.log" || true)
n_fill=$(grep -c '^\[FILL\]' "$WORK_DIR/prepare.log" || true)
log "  tables not in this schema (skipped): $n_skip | dropped extra columns: $n_filter tables | filled new columns: $n_fill tables"
grep -E '^\[(SKIP|FILTER|WARN)\]' "$WORK_DIR/prepare.log" | sed 's/^/    /' | head -40 || true

log "Loading data ..."
# No ON_ERROR_STOP: each COPY commits on its own, so one bad table is reported below
# instead of aborting the whole restore.
PGOPTIONS='-c statement_timeout=0 -c client_min_messages=warning' \
  psql "${PG_CONN[@]}" -X -q -f "$READY" >"$WORK_DIR/import.log" 2>"$WORK_DIR/import_errors.log" || true
n_errors=$(grep -c 'ERROR:' "$WORK_DIR/import_errors.log" || true)
if [ "${n_errors:-0}" -gt 0 ]; then
  warn "psql reported $n_errors error(s) (first 20 below, all in $WORK_DIR/import_errors.log):"
  grep -E 'ERROR:|DETAIL:|CONTEXT:' "$WORK_DIR/import_errors.log" | cut -c1-300 | head -30 | sed 's/^/    /' >&2
fi
grep 'WARNING:' "$WORK_DIR/import_errors.log" | cut -c1-300 | head -10 | sed 's/^/    /' >&2 || true

# ── Verify every table's row count against what the dump carried ──────────────
log "Verifying row counts ..."
[ -s "$EXPECTED" ] || die "the prepared dump carried no rows at all - see $WORK_DIR/prepare.log"
count_sql=$(awk -F'\t' -v q="'" '{printf "%sSELECT %s%s%s, count(*) FROM \"%s\"", (NR>1?" UNION ALL ":""), q, $1, q, $1}' "$EXPECTED")
"${PSQL[@]}" -At -F $'\t' -c "$count_sql" >"$WORK_DIR/actual_counts.tsv"
mismatches=$(awk -F'\t' 'NR==FNR{want[$1]=$2; next} ($1 in want) && want[$1]!=$2 {printf "    %-45s dump=%s db=%s\n", $1, want[$1], $2}' \
  "$EXPECTED" "$WORK_DIR/actual_counts.tsv")
n_tables=$(wc -l <"$EXPECTED")
if [ -n "$mismatches" ]; then
  n_bad=$(printf '%s\n' "$mismatches" | wc -l)
  warn "$n_bad of $n_tables tables don't match the dump (a failed COPY loses that whole table):"
  printf '%s\n' "$mismatches" >&2
  RESULT="restored WITH $n_bad table mismatch(es) - check $WORK_DIR/import_errors.log"
else
  log "  $n_tables/$n_tables tables match the dump."
  RESULT="restored, $n_tables/$n_tables tables match"
fi
DB_TOUCHED=0   # data is in; from here a failure only needs the app restarted

# ── 7. Bring the app back ─────────────────────────────────────────────────────
start_app

if [ "$KEEP_FILES" != 1 ]; then
  rm -f "${CLEANUP[@]}"
fi

echo
echo "════════════════════════════════════════════════════════════════"
echo "  $RESULT"
echo "  Companies : $(current_db_summary)"
echo "  Users     : $("${PSQL[@]}" -At -c 'SELECT count(*) FROM users' 2>/dev/null || echo '?') (logins/passwords are now the source DB's)"
[ -n "$BACKUP" ] && echo "  Backup    : $BACKUP  (undo: ./restore_dump.sh --rollback $BACKUP)"
echo "  Logs      : $WORK_DIR/"
[ "$KEEP_FILES" = 1 ] && echo "  Dump files kept in $WORK_DIR/ (they hold customer data - delete when done)"
[ -f "$SOURCE" ] || echo "  Turn off link sharing on the Google Drive file now."
echo "════════════════════════════════════════════════════════════════"
