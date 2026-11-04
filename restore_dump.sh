#!/usr/bin/env bash
# restore_dump.sh - load a company dump (made by foundry.django's company_dump.sh) from
# Google Drive into the database of the on-prem server you are logged in to.
#
# The app must already be deployed and running: this script does not deploy, build or
# migrate anything. It replaces the DATA in the existing database with the dump's data,
# using the schema the running backend already created. Everything it needs is in this
# one file; DB credentials are read from the running django container.
#
# Usage:
#   ./restore_dump.sh                                   # uses DRIVE_LINK below
#   ./restore_dump.sh '<google-drive-link | drive-file-id | /path/to/dump.sql[.gz|.zip]>'
#   ./restore_dump.sh --rollback ~/manufapp-restore/backups/pre_restore_<db>_<time>.dump
#
# Options:
#   --yes, -y      don't ask for confirmation
#   --no-backup    skip the pg_dump backup of the current database
#   --keep-files   keep the downloaded / prepared dump in ~/manufapp-restore/work/
#   --rollback F   put back a backup this script took
#
# Env (all optional):
#   DRIVE_LINK        overrides the link set below
#   CONTAINER_PREFIX  container name prefix of the stack (default: manufapp ->
#                     manufapp-django, manufapp-celery, manufapp-celery-beat, manufapp-nginx)
#   RESTORE_HOME      where backups/ and work/ go (default: ~/manufapp-restore)
#   RESTORE_DB_HOST, RESTORE_DB_PORT  how this script's psql reaches Postgres (default: the
#                     container's DB_HOST/DB_PORT, with host.docker.internal -> 127.0.0.1)
#
# Google Drive: upload the dump (.sql, or .sql.gz / .zip to make it smaller), then
# Share -> General access -> "Anyone with the link" (Viewer). Turn sharing off afterwards:
# the dump holds customer data.
#
# What it does:
#   1. Downloads + unpacks the dump, checks it is a complete company_dump.sh file
#   2. Shows what will be replaced and asks you to type 'yes'
#   3. Backs up the current database (pg_dump -Fc) to ~/manufapp-restore/backups/
#   4. Reads model field defaults from the running backend (for columns newer than the dump)
#   5. Stops celery-beat, celery and django (about a minute, so nothing writes mid-load)
#   6. Empties the data tables and loads the dump, fitted to the deployed schema;
#      checks every table's row count against the dump
#   7. Starts django, celery and celery-beat again and restarts nginx
#
# Examples:
#   # on your laptop: dump company 2 from prod through an SSH tunnel on localhost:2345
#   PGSSLMODE=require DB_HOST=localhost DB_PORT=2345 DB_USER=caretaker DB_NAME=manufapp \
#     DB_PASSWORD='<source db password>' ENV_NAME=prod ./company_dump.sh 2
#   gzip -9 company_2_dump_20261104_151156.sql        # then upload + share on Drive
#
#   # on the server:
#   ./restore_dump.sh 'https://drive.google.com/file/d/1AbCdEfGhIjKlMnOpQrStUvWxYz012345/view?usp=sharing'
#   ./restore_dump.sh ~/company_2_dump_20261104_151156.sql.gz --yes
#   ./restore_dump.sh --rollback ~/manufapp-restore/backups/pre_restore_manufapp_20261104_153012.dump

# ── The dump to load when no link is given on the command line ────────────────
# Paste the Drive share link here on the server. Keep the placeholder in the
# repository: foundry.custom is public, and the link points at customer data.
DRIVE_LINK="${DRIVE_LINK:-https://drive.google.com/file/d/PASTE_FILE_ID_HERE/view?usp=sharing}"

set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
CONTAINER_PREFIX="${CONTAINER_PREFIX:-manufapp}"
DJANGO="${CONTAINER_PREFIX}-django"
APP_STOP_ORDER=("${CONTAINER_PREFIX}-celery-beat" "${CONTAINER_PREFIX}-celery" "$DJANGO")
APP_START_ORDER=("$DJANGO" "${CONTAINER_PREFIX}-celery" "${CONTAINER_PREFIX}-celery-beat")
NGINX="${CONTAINER_PREFIX}-nginx"
RESTORE_HOME="${RESTORE_HOME:-$HOME/manufapp-restore}"
WORK_DIR="$RESTORE_HOME/work"
BACKUP_DIR="$RESTORE_HOME/backups"
TS=$(date +%Y%m%d_%H%M%S)

log()  { echo "[$(date +%T)] $*"; }
warn() { echo "[$(date +%T)] WARN: $*" >&2; }
die()  { echo "[$(date +%T)] ERROR: $*" >&2; exit 1; }

usage() {
  sed -n '2,/^$/{s/^# \{0,1\}//;p}' "$SELF" | sed '/^── The dump/,$d'
  exit "${1:-1}"
}

# ── Args ──────────────────────────────────────────────────────────────────────
ORIG_ARGS=("$@")
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
[ -z "$SOURCE" ] || [ -z "$ROLLBACK" ] || die "give either a dump source or --rollback, not both"
if [ -z "$ROLLBACK" ] && [ -z "$SOURCE" ]; then
  SOURCE="$DRIVE_LINK"
  [[ "$SOURCE" != *PASTE_FILE_ID_HERE* ]] \
    || die "no dump given - pass a Drive link / file, or set DRIVE_LINK at the top of $SELF"
fi

need() { command -v "$1" >/dev/null 2>&1 || die "'$1' not found - $2"; }
need docker  "this script expects the Docker-deployed Manufapp stack"
need psql    "install the PostgreSQL client (apt install postgresql-client)"
need python3 "install python3"
need curl    "install curl"

# A session that predates the user's docker group membership can't reach the socket -
# re-run under the group (same as manufapp.sh's ensure_docker_access).
if ! docker info >/dev/null 2>&1; then
  if id -nG 2>/dev/null | tr ' ' '\n' | grep -qx docker && command -v sg >/dev/null 2>&1; then
    log "Re-launching under the docker group (no logout needed) ..."
    exec sg docker -c "$(printf '%q ' "$SELF" "${ORIG_ARGS[@]}")"
  elif command -v sudo >/dev/null 2>&1; then
    log "Re-launching via sudo to reach the Docker socket ..."
    exec sudo -E -g docker -- "$SELF" "${ORIG_ARGS[@]}"
  fi
  die "can't reach the Docker socket - run: sudo usermod -aG docker \$USER, then log out and back in"
fi

# ── The deployed backend: DB credentials + the schema we load into ────────────
running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = "true" ]; }
exists()  { docker inspect "$1" >/dev/null 2>&1; }
exists "$DJANGO" || die "container $DJANGO not found - deploy the app first (or set CONTAINER_PREFIX)"
if ! running "$DJANGO"; then
  [ -n "$ROLLBACK" ] || die "$DJANGO is not running - start the app first (it creates the schema this script loads into)"
fi

# Read from the container's config, so it works whether or not it is running.
denv() { docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$DJANGO" | sed -n "s/^$1=//p" | head -1; }
DB_HOST=$(denv DB_HOST); DB_PORT=$(denv DB_PORT); DB_NAME=$(denv DB_NAME)
DB_USER=$(denv DB_USER); DB_PASSWORD=$(denv DB_PASSWORD)
DB_PORT=${DB_PORT:-5432}
[ -n "$DB_NAME" ] && [ -n "$DB_USER" ] || die "couldn't read DB_NAME/DB_USER from $DJANGO's environment"
BE_IMAGE=$(docker inspect -f '{{.Config.Image}}' "$DJANGO")

# The container reaches the host's Postgres as host.docker.internal; this script runs
# on the host itself, where that name doesn't resolve.
case "$DB_HOST" in
  host.docker.internal|localhost|127.0.0.1|"") DB_IS_LOCAL=1; PG_HOST=127.0.0.1 ;;
  *)                                            DB_IS_LOCAL=0; PG_HOST="$DB_HOST" ;;
esac
PG_HOST="${RESTORE_DB_HOST:-$PG_HOST}"
PG_PORT="${RESTORE_DB_PORT:-$DB_PORT}"
export PGPASSWORD="$DB_PASSWORD"
PG_CONN=(-h "$PG_HOST" -p "$PG_PORT" -U "$DB_USER" -d "$DB_NAME")
PSQL=(psql "${PG_CONN[@]}" -X -v ON_ERROR_STOP=1)

mkdir -p "$WORK_DIR" "$BACKUP_DIR"
chmod 700 "$RESTORE_HOME" "$WORK_DIR" "$BACKUP_DIR"

"${PSQL[@]}" -Atc "SELECT 1" >/dev/null 2>"$WORK_DIR/conn.err" || {
  cat "$WORK_DIR/conn.err" >&2
  die "cannot connect to Postgres as $DB_USER@$PG_HOST:$PG_PORT/$DB_NAME (credentials from $DJANGO)"
}

confirm() {
  [ "$ASSUME_YES" = 1 ] && return 0
  local reply=""
  read -r -p "$1 [type 'yes' to continue]: " reply || true
  [ "$reply" = "yes" ]
}

current_db_summary() {
  local companies
  companies=$("${PSQL[@]}" -At -c "SELECT string_agg('[' || id || '] ' || name, ', ' ORDER BY id) FROM (SELECT id, name FROM companies ORDER BY id LIMIT 15) c" 2>/dev/null || true)
  echo "${companies:-(no companies yet)}"
}

# ── App stop/start (containers only - nothing is redeployed) ─────────────────
WAS_RUNNING=(); APP_STOPPED=0; DB_TOUCHED=0; BACKUP=""; CLEANUP=()
for c in "${APP_STOP_ORDER[@]}"; do running "$c" && WAS_RUNNING+=("$c"); done

stop_app() {
  [ ${#WAS_RUNNING[@]} -gt 0 ] || return 0
  log "Stopping ${WAS_RUNNING[*]} ..."
  docker stop "${WAS_RUNNING[@]}" >/dev/null
  APP_STOPPED=1
}

start_app() {
  [ "$APP_STOPPED" = 1 ] || return 0
  local c started=()
  for c in "${APP_START_ORDER[@]}"; do
    [[ " ${WAS_RUNNING[*]} " == *" $c "* ]] && started+=("$c")
  done
  log "Starting ${started[*]} ..."
  docker start "${started[@]}" >/dev/null
  APP_STOPPED=0
  # django runs `migrate` (a no-op here) before serving; wait for its healthcheck.
  local i status=""
  for i in $(seq 1 60); do
    status=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$DJANGO" 2>/dev/null || true)
    [ "$status" = "healthy" ] || [ "$status" = "none" ] && break
    sleep 5
  done
  [ "$status" = "healthy" ] || [ "$status" = "none" ] || warn "$DJANGO is still '$status' after 5 min - check: docker logs $DJANGO"
  # nginx caches the backend's container IP and can 502 until it restarts.
  if running "$NGINX"; then docker restart "$NGINX" >/dev/null && log "Restarted $NGINX."; fi
}

on_exit() {
  local rc=$?
  [ $rc -eq 0 ] && return
  [ "$KEEP_FILES" = 1 ] || rm -f "${CLEANUP[@]}"
  [ "$DB_TOUCHED" = 1 ] || [ "$APP_STOPPED" = 1 ] || return
  echo >&2
  echo "────────────────────────────────────────────────────────────────" >&2
  echo "FAILED (exit $rc). Logs: $WORK_DIR/" >&2
  if [ "$DB_TOUCHED" = 1 ] && [ -n "$BACKUP" ] && [ -f "$BACKUP" ]; then
    echo "The database was already modified. Put the previous data back with:" >&2
    echo "  $SELF --rollback $BACKUP" >&2
  fi
  if [ "$APP_STOPPED" = 1 ]; then
    echo "The app is stopped. Start it with: docker start ${APP_START_ORDER[*]}" >&2
  fi
}
trap on_exit EXIT

backup_db() {
  if [ "$DO_BACKUP" != 1 ]; then
    warn "--no-backup: the current database will NOT be recoverable"
    return
  fi
  need pg_dump "install the PostgreSQL client, or rerun with --no-backup"
  BACKUP="$BACKUP_DIR/pre_restore_${DB_NAME}_${TS}.dump"
  log "Backing up '$DB_NAME' -> $BACKUP ..."
  if ! pg_dump "${PG_CONN[@]}" -Fc -f "$BACKUP" 2>"$WORK_DIR/backup.err"; then
    cat "$WORK_DIR/backup.err" >&2
    rm -f "$BACKUP"; BACKUP=""
    die "backup failed (a pg_dump older than the server can't dump it - install postgresql-client-<server version>), or rerun with --no-backup"
  fi
  chmod 600 "$BACKUP"
  log "Backup done ($(du -h "$BACKUP" | cut -f1))."
}

# ══════════════════════════════════════════════════════════════════════════════
# Rollback: drop everything and pg_restore a backup this script took
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
  stop_app
  DB_TOUCHED=1
  log "Dropping everything in '$DB_NAME' ..."
  # One table per statement first: a lone DROP SCHEMA CASCADE locks every object in one
  # transaction and can overflow a small server's lock table.
  "${PSQL[@]}" -At -c "SELECT format('DROP TABLE IF EXISTS public.%I CASCADE;', tablename) FROM pg_tables WHERE schemaname = 'public'" \
    | PGOPTIONS='-c client_min_messages=warning' "${PSQL[@]}" -q
  if ! PGOPTIONS='-c client_min_messages=warning' "${PSQL[@]}" -q -c \
      "DROP SCHEMA public CASCADE; CREATE SCHEMA public; GRANT ALL ON SCHEMA public TO \"$DB_USER\"; GRANT ALL ON SCHEMA public TO public; CREATE EXTENSION IF NOT EXISTS pg_trgm;" \
      2>"$WORK_DIR/reset_schema.err"; then
    [ "$DB_IS_LOCAL" = 1 ] && command -v sudo >/dev/null 2>&1 \
      || { cat "$WORK_DIR/reset_schema.err" >&2; die "could not recreate the public schema as $DB_USER"; }
    log "  ($DB_USER can't do that - retrying as the postgres superuser via sudo)"
    sudo -u postgres env PGOPTIONS='-c client_min_messages=warning' psql -X -q -v ON_ERROR_STOP=1 -d "$DB_NAME" -c \
      "DROP SCHEMA public CASCADE; CREATE SCHEMA public AUTHORIZATION \"$DB_USER\"; GRANT ALL ON SCHEMA public TO public; CREATE EXTENSION IF NOT EXISTS pg_trgm;"
  fi
  log "Restoring $ROLLBACK ..."
  pg_restore "${PG_CONN[@]}" --no-owner --no-acl -j 4 "$ROLLBACK" 2>"$WORK_DIR/rollback_errors.log" || true
  # Expected, harmless: extension entries a non-superuser can't replay, and settings a
  # newer pg_dump writes that an older server doesn't know (transaction_timeout).
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
# Restore
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
  head_bytes=$(head -c 1024 "$RAW" | tr -d '\0' | tr '[:upper:]' '[:lower:]')
  if [[ "$head_bytes" == *"<html"* ]] || [[ "$head_bytes" == *"<!doctype html"* ]]; then
    die "Google Drive returned a web page instead of the file - set the file's sharing to 'Anyone with the link' (Viewer) and check the link"
  fi
  log "Downloaded $(du -h "$RAW" | cut -f1)."
fi

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

head -n 3 "$DUMP" | grep -q '^-- Company dump' \
  || die "not a company_dump.sh dump (no '-- Company dump' header in the first lines)"
DUMP_COMPANIES=$(head -n 200 "$DUMP" | sed -n '3,/^-- Generated/p' | { grep -E '^--   \[' || true; } | sed 's/^--   //' | paste -sd ',' - | sed 's/,/, /g')
DUMP_GENERATED=$(grep -m1 '^-- Generated:' "$DUMP" | sed 's/^-- Generated: *//' || true)
COPY_BLOCKS=$(grep -c '^COPY "' "$DUMP" || true)
[ "${COPY_BLOCKS:-0}" -gt 0 ] || die "dump has no data (no COPY blocks)"
tail -n 5 "$DUMP" | grep -q "^SET session_replication_role = DEFAULT;" \
  || die "dump looks truncated (doesn't end with company_dump.sh's footer) - upload / download it again"
grep -q '^-- Fix dangling user-FK references' "$DUMP" \
  || warn "dump has no fix-up footer (older company_dump.sh) - tags may show on the wrong records"

# ── 2. Confirm ────────────────────────────────────────────────────────────────
echo
echo "  Dump       : $(du -h "$DUMP" | cut -f1), $COPY_BLOCKS table blocks, generated $DUMP_GENERATED"
echo "  Companies  : $DUMP_COMPANIES"
echo "  Target DB  : $DB_NAME @ $PG_HOST:$PG_PORT (user $DB_USER, from $DJANGO)"
echo "  Now holds  : $(current_db_summary)"
echo "  Backend    : $BE_IMAGE (not redeployed)"
echo "  Backup     : $([ "$DO_BACKUP" = 1 ] && echo "yes -> $BACKUP_DIR/" || echo "NO (--no-backup)")"
echo
confirm "This REPLACES all data in '$DB_NAME' with the dump." || die "Aborted - nothing was changed."

# ── 3-4. Backup, field defaults (while the backend still runs) ────────────────
backup_db

FIELD_DEFAULTS_PY="$WORK_DIR/field_defaults.py"
PREPARE_PY="$WORK_DIR/prepare_dump.py"
cat > "$FIELD_DEFAULTS_PY" <<'PYEOF'
# Runs inside the target foundry.django image (`manage.py shell < field_defaults.py`)
# and prints every model column's default as
#   FIELD_DEFAULT<TAB>table<TAB>column<TAB>COPY text
# for prepare_dump.py, which uses it to fill columns added after the dump was taken.
# Embedded in restore_dump.sh; kept in sync with foundry.django's gcp_dump_restore.sh.
import datetime, decimal, enum, json, uuid
from django.apps import apps

def esc(s):
    return s.replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n").replace("\r", "\\r")

def copy_text(field, value):
    if value is None:
        return None
    if isinstance(value, enum.Enum):
        value = value.value
    kind = field.get_internal_type()
    if kind == "ArrayField":
        return "{}" if not value else None
    if kind == "JSONField":
        return esc(json.dumps(value))
    if isinstance(value, bool):
        return "t" if value else "f"
    if isinstance(value, (datetime.date, datetime.time)):
        return value.isoformat()
    if isinstance(value, (int, float, decimal.Decimal, uuid.UUID, str)):
        return esc(str(value))
    return None

for model in apps.get_models(include_auto_created=True):
    if model._meta.proxy or not model._meta.managed:
        continue
    for f in model._meta.concrete_fields:
        # A unique column can't take one shared fill value; relations have no default.
        if f.primary_key or f.is_relation or f.unique or not f.has_default():
            continue
        try:
            val = copy_text(f, f.get_default())
        except Exception:
            continue
        if val is not None:
            print(f"FIELD_DEFAULT\t{model._meta.db_table}\t{f.column}\t{val}")
PYEOF
cat > "$PREPARE_PY" <<'PYEOF'
#!/usr/bin/env python3
"""
Prepares a company_dump.sh dump (foundry.django) for restore via psql into a
database whose schema was just created by `manage.py migrate` — so we ONLY emit
COPY blocks (plus the dump's fix-up footer); all DDL in the dump is skipped.

Embedded in foundry.custom's restore_dump.sh. Kept in sync with the prepare_dump.py
embedded in foundry.django's gcp_dump_restore.sh (gc-uat branch) — fix bugs in both.

Usage:
  DB_HOST=127.0.0.1 DB_PORT=5432 DB_USER=caretaker DB_NAME=manufapp PGPASSWORD=... \
  FIELD_DEFAULTS=field_defaults.tsv EXPECTED_COUNTS=expected_counts.tsv \
    python3 prepare_dump.py < dump.sql > dump_ready.sql 2> prepare.log

Steps:
  1. Drop all non-PK unique constraints/indexes (avoid unique violations)
  2. Make all FK constraints DEFERRABLE (FK checks defer to COMMIT)
  3. Load each table in its own transaction (FKs are dropped, nothing to defer)
  4. Filter COPY column lists to match the target schema (drops added columns),
     and append target columns the dump predates, filled with the model default
  5. Replace \\N with column defaults for NOT NULL+default columns in COPY data
  6. Skip COPY blocks for tables absent from the target DB
  7. Skip ALL non-COPY lines from the dump (DDL already applied by migrations)
  8. Recreate unique indexes after COMMIT
  9. Reset all sequences to max(id) so future INSERTs don't collide
"""
import sys, subprocess, os, re

DB_HOST = os.environ.get("DB_HOST", "127.0.0.1")
DB_PORT = os.environ.get("DB_PORT", "5432")
DB_USER = os.environ.get("DB_USER", "caretaker")
DB_NAME = os.environ.get("DB_NAME", "manufapp")
PW      = os.environ.get("PGPASSWORD", "")

def psql(sql):
    env = dict(os.environ, PGPASSWORD=PW)
    r = subprocess.run(
        ["psql", "-h", DB_HOST, "-p", DB_PORT, "-U", DB_USER,
         "-d", DB_NAME, "-At", "-c", sql],
        capture_output=True, text=True, env=env
    )
    return r.stdout.strip()

# psql() swallows errors, so a bad connection would make every table look absent
# from the target and silently skip the whole dump. Fail loudly instead.
if psql("SELECT 1") != "1":
    sys.stderr.write(f"[FATAL] cannot query {DB_USER}@{DB_HOST}:{DB_PORT}/{DB_NAME}\n")
    sys.exit(1)

# Model field defaults (table → {column: COPY text}), written by field_defaults.py
# from the target image. Django 3.2 drops a new column's DB default once AddField
# has filled the existing rows, so a dump taken before that migration has no value
# for the column and the DB has no default to fall back on: the NOT NULL check
# then rolls back the whole table's COPY (sites, machines, warehouses, ...).
model_defaults = {}
if os.environ.get("FIELD_DEFAULTS"):
    with open(os.environ["FIELD_DEFAULTS"]) as fh:
        for row in fh:
            parts = row.rstrip("\n").split("\t", 3)
            if len(parts) == 4 and parts[0] == "FIELD_DEFAULT":
                model_defaults.setdefault(parts[1], {})[parts[2]] = parts[3]
else:
    sys.stderr.write("[WARN] FIELD_DEFAULTS not set — columns the dump predates stay NULL\n")

col_cache = {}

def get_cols(table):
    if table not in col_cache:
        out = psql(
            f"SELECT column_name FROM information_schema.columns "
            f"WHERE table_schema='public' AND table_name='{table}' "
            f"ORDER BY ordinal_position"
        )
        col_cache[table] = set(c for c in out.split("\n") if c)
    return col_cache[table]

# NOT NULL columns that have a DB-level default — if the dump has \N for
# these (e.g. column added after the dump was taken), replace \N with the default.
notnull_defaults_cache = {}

def get_notnull_defaults(table):
    if table not in notnull_defaults_cache:
        out = psql(
            f"SELECT column_name || '|' || column_default "
            f"FROM information_schema.columns "
            f"WHERE table_schema='public' AND table_name='{table}' "
            f"AND is_nullable='NO' AND column_default IS NOT NULL "
            f"AND column_name != 'id' "
            f"AND column_default NOT LIKE 'nextval%%'"
        )
        defaults = {}
        for row in out.split("\n"):
            if not row.strip(): continue
            parts = row.split("|", 1)
            if len(parts) != 2: continue
            col, default = parts[0].strip(), parts[1].strip()
            # Map PostgreSQL column_default → COPY text-format value
            if default == 'false':
                defaults[col] = 'f'
            elif default == 'true':
                defaults[col] = 't'
            elif re.match(r"^-?\d+$", default):
                defaults[col] = default
            elif default.startswith("'") and "'::character" in default:
                defaults[col] = default.split("'")[1]
            elif default.startswith("'") and default.endswith("'"):
                defaults[col] = default[1:-1]
            elif default.startswith("'{}'"):
                defaults[col] = '{}'
            elif default in ('{}', '[]'):
                defaults[col] = default
            else:
                defaults[col] = default
        defaults.update(model_defaults.get(table, {}))
        notnull_defaults_cache[table] = defaults
    return notnull_defaults_cache[table]

# ── 1. psql savepoint mode: errors roll back just that statement ──────────────
sys.stdout.write("\\set ON_ERROR_ROLLBACK on\n\n")

# ── 2. Drop all non-PK unique constraints/indexes to avoid violations during COPY ─
# Two categories:
#   a) Constraint-backed unique indexes: must drop the CONSTRAINT
#      "DROP INDEX" fails with "constraint ... requires it" for these
#   b) Pure unique indexes (partial UniqueConstraint with condition): drop with DROP INDEX
#
# After COMMIT we recreate all of them using their original CREATE UNIQUE INDEX definition.

# 2a — constraint-backed unique constraints
constraint_rows = psql(
    "SELECT tc.table_name || '|' || tc.constraint_name "
    "FROM information_schema.table_constraints tc "
    "WHERE tc.constraint_type = 'UNIQUE' "
    "AND tc.table_schema = 'public'"
)
constraint_names = set()
if constraint_rows:
    sys.stdout.write("-- Drop unique constraints (constraint-backed) to allow bulk COPY\n")
    for row in constraint_rows.split("\n"):
        if not row.strip():
            continue
        parts = row.split("|", 1)
        if len(parts) == 2:
            table, cname = parts[0].strip(), parts[1].strip()
            constraint_names.add(cname)
            sys.stdout.write(f"ALTER TABLE {table} DROP CONSTRAINT IF EXISTS {cname};\n")
    sys.stdout.write("\n")

# 2b — collect ALL non-PK unique index definitions for recreation later
unique_rows = psql(
    "SELECT indexname || '|' || indexdef "
    "FROM pg_indexes "
    "WHERE schemaname='public' "
    "AND indexdef LIKE 'CREATE UNIQUE INDEX%' "
    "AND indexname NOT LIKE '%pkey'"
)
unique_indexes = []  # list of (name, create_sql) to recreate after import
if unique_rows:
    for row in unique_rows.split("\n"):
        if not row.strip():
            continue
        parts = row.split("|", 1)
        if len(parts) == 2:
            name, defn = parts[0].strip(), parts[1].strip()
            unique_indexes.append((name, defn))
            # Only pure (non-constraint-backed) indexes need DROP INDEX
            if name not in constraint_names:
                sys.stdout.write(f"-- Drop partial unique index\nDROP INDEX IF EXISTS {name};\n")
    sys.stdout.write("\n")

# ── 3. Drop ALL FK constraints (DDL outside main transaction) ─────────────────
# Rationale: company-specific dumps don't include every referenced table
# (e.g. companies.profile_img_id → documents, which may be absent).
# Making FKs DEFERRABLE still fails at COMMIT when the referenced row simply
# doesn't exist.  Dropping them entirely lets the COPY complete and the
# COMMIT succeed; referential integrity is enforced by the application layer.
fk_rows = psql(
    "SELECT quote_ident(conrelid::regclass::text) || '|' || quote_ident(conname) "
    "FROM pg_constraint "
    "WHERE contype = 'f' AND connamespace = 'public'::regnamespace"
)
if fk_rows:
    sys.stdout.write("-- Drop all FK constraints (referenced tables may be absent from dump)\n")
    for row in fk_rows.split("\n"):
        if not row.strip():
            continue
        parts = row.split("|", 1)
        if len(parts) == 2:
            table, cname = parts[0].strip(), parts[1].strip()
            sys.stdout.write(f"ALTER TABLE {table} DROP CONSTRAINT IF EXISTS {cname};\n")
    sys.stdout.write("\n")

# ── 4. Truncate all business tables to remove migration-seeded rows ───────────
# Migrations insert default data (e.g. partnerskucode rows) whose PKs collide
# with the dump.  Truncating before COPY avoids duplicate-key violations.
SKIP_TABLES = {
    'django_migrations', 'auth_permission', 'django_content_type',
    'auth_group', 'auth_group_permissions',
    'django_celery_beat_crontabschedule', 'django_celery_beat_intervalschedule',
    'django_celery_beat_periodictask', 'django_celery_beat_periodictasks',
    'django_celery_beat_solarschedule', 'django_celery_beat_clockedschedule',
}
all_tables_raw = psql(
    "SELECT tablename FROM pg_tables WHERE schemaname='public'"
)
business_tables = [
    t.strip() for t in all_tables_raw.split("\n")
    if t.strip() and t.strip() not in SKIP_TABLES
]
# One statement per table: a single TRUNCATE of every table (or one transaction
# around every COPY) locks each table and index at once, which overflows the lock
# table on small Cloud SQL tiers ("out of shared memory", ~3200 slots on db-g1-small).
if business_tables:
    sys.stdout.write(f"-- Truncate business tables (clear migration-seeded rows)\n")
    for t in business_tables:
        sys.stdout.write(f'TRUNCATE TABLE "{t}" CASCADE;\n')
    sys.stdout.write("\n")

# ── 5. COPY blocks — each commits on its own (see the TRUNCATE note above) ────

copy_table      = None
keep_indices    = None
kept_bare_cols  = None
skip_block      = False
fill_vals       = []
row_counts      = {}

# company_dump.sh ends with a fix-up footer (content_type remap for core_taggedrecord,
# dangling created_by/last_updated_by reassignment, profile_img/slug cleanup). It must
# run after the data loads: without the content_type remap every tag points at the
# wrong model (source DB content_type ids != freshly-migrated target ids), so
# machines/SKUs show no tags at all.
FOOTER_MARKER   = "-- Fix dangling user-FK references"
FOOTER_SKIP     = ("SET session_replication_role", "ALTER TABLE core_customtag ADD CONSTRAINT core_customtag_slug_key")
footer_lines    = []
in_footer       = False

for raw in sys.stdin:
    line = raw.rstrip("\n")

    if in_footer or (not copy_table and line.startswith(FOOTER_MARKER)):
        in_footer = True
        if not line.startswith(FOOTER_SKIP):  # replica role is session-scoped; slug index is recreated below
            footer_lines.append(raw)
        continue

    if not copy_table:
        # Only emit COPY blocks — skip ALL other lines from the dump.
        # The schema is already created by Django migrations; passing DDL
        # through (CREATE TABLE, ALTER TABLE, SET commands, etc.) causes
        # "relation already exists" errors that cascade into COPY data being
        # misread as SQL statements, aborting the entire transaction.
        m = re.match(r'COPY "(\w+)" \((.+)\) FROM stdin;', line)
        if not m:
            continue  # skip all DDL / comments / SET commands from dump

        copy_table = m.group(1)
        raw_cols   = [c.strip() for c in m.group(2).split(",")]
        bare_cols  = [c.strip('"') for c in raw_cols]
        tgt_cols   = get_cols(copy_table)

        if not tgt_cols:
            sys.stderr.write(f"[SKIP] table not in target: {copy_table}\n")
            skip_block      = True
            keep_indices    = None
            kept_bare_cols  = None
        else:
            keep           = [(i, raw_cols[i], bare_cols[i])
                              for i in range(len(raw_cols)) if bare_cols[i] in tgt_cols]
            keep_indices   = [i         for i, _, _  in keep]
            kept_raw_cols  = [rc        for _, rc, _ in keep]
            kept_bare_cols = [bc        for _, _,  bc in keep]
            dropped        = [bc for bc in bare_cols if bc not in tgt_cols]
            if dropped:
                sys.stderr.write(f"[FILTER] {copy_table}: dropped cols {dropped}\n")
            # Columns added after the dump was taken: fill them the way AddField
            # filled the existing rows, with the model default.
            fill_defs      = {c: v for c, v in model_defaults.get(copy_table, {}).items()
                              if c in tgt_cols and c not in bare_cols}
            fill_vals      = list(fill_defs.values())
            kept_raw_cols  = kept_raw_cols + [f'"{c}"' for c in fill_defs]
            if fill_defs:
                sys.stderr.write(f"[FILL] {copy_table}: added cols {list(fill_defs)} with model defaults\n")
            kept_str       = ", ".join(kept_raw_cols)
            sys.stdout.write(f'COPY "{copy_table}" ({kept_str}) FROM stdin;\n')
            skip_block = False
        continue

    # Inside a COPY block
    if line == "\\.":
        if not skip_block:
            sys.stdout.write(raw)
        copy_table      = None
        keep_indices    = None
        kept_bare_cols  = None
        skip_block      = False
    elif skip_block:
        pass  # drop the row
    elif keep_indices is not None:
        parts      = line.split("\t")
        nn_defs    = get_notnull_defaults(copy_table)
        filtered   = []
        for idx, i in enumerate(keep_indices):
            val = parts[i] if i < len(parts) else r"\N"
            col = kept_bare_cols[idx]
            # Replace \N with the column default for NOT NULL+default columns
            # to avoid "null value violates not-null constraint" on COPY
            if val == r"\N" and col in nn_defs:
                val = nn_defs[col]
            filtered.append(val)
        sys.stdout.write("\t".join(filtered + fill_vals) + "\n")
        row_counts[copy_table] = row_counts.get(copy_table, 0) + 1
    else:
        sys.stdout.write(raw)

# Rows emitted per table — restore_dump.sh compares these with count(*) after the
# import to report any table whose COPY failed (and was rolled back).
if os.environ.get("EXPECTED_COUNTS"):
    with open(os.environ["EXPECTED_COUNTS"], "w") as fh:
        for t in sorted(row_counts):
            fh.write(f"{t}\t{row_counts[t]}\n")


# ── 5b. Dump footer fix-ups (must run after data, before unique indexes) ──────
if footer_lines:
    sys.stdout.write("-- company_dump.sh footer: content_type remap + FK fix-ups\n")
    sys.stdout.write("".join(footer_lines))
    sys.stdout.write("\n")
else:
    sys.stderr.write("[WARN] dump has no fix-up footer — tags may point at the wrong content types\n")

# ── 6. Recreate unique indexes ─────────────────────────────────────────────────
if unique_indexes:
    sys.stdout.write("-- Recreate unique indexes\n")
    for name, defn in unique_indexes:
        sys.stdout.write(f"{defn.replace('CREATE UNIQUE INDEX', 'CREATE UNIQUE INDEX IF NOT EXISTS', 1)};\n")
    sys.stdout.write("\n")

# ── 7. Reset sequences so future INSERTs don't collide with restored IDs ──────
reset_sql = psql(
    "SELECT 'SELECT SETVAL(' || quote_literal(s.relname::text) || "
    "', COALESCE((SELECT MAX(id) FROM ' || quote_ident(t.relname) || '), 1));' "
    "FROM pg_class s "
    "JOIN pg_depend dep ON dep.objid = s.oid AND dep.deptype = 'a' "
    "JOIN pg_class t ON t.oid = dep.refobjid "
    "JOIN pg_attribute col ON col.attrelid = t.oid AND col.attnum = dep.refobjsubid "
    "WHERE s.relkind = 'S' "
    "AND t.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname='public') "
    "AND col.attname = 'id'"
)
if reset_sql:
    sys.stdout.write("-- Reset sequences to max restored id\n")
    for stmt in reset_sql.split("\n"):
        if stmt.strip():
            sys.stdout.write(stmt + "\n")
    sys.stdout.write("\n")
PYEOF

log "Reading model field defaults from $DJANGO ..."
FIELD_DEFAULTS="$WORK_DIR/field_defaults.tsv"
docker exec -i -e DISABLE_IO=true "$DJANGO" python manage.py shell <"$FIELD_DEFAULTS_PY" 2>"$WORK_DIR/field_defaults.err" \
  | grep '^FIELD_DEFAULT' >"$FIELD_DEFAULTS" || true
n_defaults=$(wc -l <"$FIELD_DEFAULTS")
if [ "$n_defaults" -eq 0 ]; then
  warn "got no field defaults (see $WORK_DIR/field_defaults.err) - columns newer than the dump stay NULL and may reject rows"
else
  log "  $n_defaults model column defaults."
fi

READY="$WORK_DIR/dump_ready_${TS}.sql"; CLEANUP+=("$READY")
EXPECTED="$WORK_DIR/expected_counts.tsv"
log "Fitting the dump to the deployed schema ..."
if ! DB_HOST="$PG_HOST" DB_PORT="$PG_PORT" DB_USER="$DB_USER" DB_NAME="$DB_NAME" \
     FIELD_DEFAULTS="$FIELD_DEFAULTS" EXPECTED_COUNTS="$EXPECTED" \
     python3 -I "$PREPARE_PY" <"$DUMP" >"$READY" 2>"$WORK_DIR/prepare.log"; then
  cat "$WORK_DIR/prepare.log" >&2
  die "preparing the dump failed - see $WORK_DIR/prepare.log"
fi
chmod 600 "$READY"
n_skip=$(grep -c '^\[SKIP\]' "$WORK_DIR/prepare.log" || true)
n_filter=$(grep -c '^\[FILTER\]' "$WORK_DIR/prepare.log" || true)
n_fill=$(grep -c '^\[FILL\]' "$WORK_DIR/prepare.log" || true)
log "  tables not in this schema (skipped): $n_skip | dropped extra columns: $n_filter tables | filled new columns: $n_fill tables"
grep -E '^\[(SKIP|FILTER|WARN)\]' "$WORK_DIR/prepare.log" | sed 's/^/    /' | head -40 || true

# ── 5-6. Stop the app, load ───────────────────────────────────────────────────
stop_app
DB_TOUCHED=1
log "Loading data (existing data in '$DB_NAME' is replaced) ..."
# No ON_ERROR_STOP: each COPY commits on its own, so one bad table is reported below
# instead of aborting the whole load.
PGOPTIONS='-c statement_timeout=0 -c client_min_messages=warning' \
  psql "${PG_CONN[@]}" -X -q -f "$READY" >"$WORK_DIR/import.log" 2>"$WORK_DIR/import_errors.log" || true
n_errors=$(grep -c 'ERROR:' "$WORK_DIR/import_errors.log" || true)
if [ "${n_errors:-0}" -gt 0 ]; then
  warn "psql reported $n_errors error(s) (first 30 lines below, all in $WORK_DIR/import_errors.log):"
  grep -E 'ERROR:|DETAIL:|CONTEXT:' "$WORK_DIR/import_errors.log" | cut -c1-300 | head -30 | sed 's/^/    /' >&2
fi
grep 'WARNING:' "$WORK_DIR/import_errors.log" | cut -c1-300 | head -10 | sed 's/^/    /' >&2 || true

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
DB_TOUCHED=0

# ── 7. Start the app again ────────────────────────────────────────────────────
start_app
[ "$KEEP_FILES" = 1 ] || rm -f "${CLEANUP[@]}"

echo
echo "════════════════════════════════════════════════════════════════"
echo "  $RESULT"
echo "  Companies : $(current_db_summary)"
echo "  Users     : $("${PSQL[@]}" -At -c 'SELECT count(*) FROM users' 2>/dev/null || echo '?') (logins/passwords are now the source DB's)"
[ -n "$BACKUP" ] && echo "  Backup    : $BACKUP  (undo: $SELF --rollback $BACKUP)"
echo "  Logs      : $WORK_DIR/"
[ "$KEEP_FILES" = 1 ] && echo "  Dump files kept in $WORK_DIR/ (they hold customer data - delete when done)"
[ -f "$SOURCE" ] || echo "  Turn off link sharing on the Google Drive file now."
echo "════════════════════════════════════════════════════════════════"
