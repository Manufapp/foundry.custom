#!/usr/bin/env bash
# Wrapper around docker-compose.server.yml - setup/start/stop/logs for the on-prem/customer
# server stack (nginx, react, django, celery, celery-beat, redis).
#
# Usage:
#   ./manufapp.sh setup     # Ubuntu only - install Docker + AWS CLI v2 if missing
#   ./manufapp.sh start     # aws ecr login, pull latest images, up -d
#   ./manufapp.sh stop      # down
#   ./manufapp.sh restart   # stop, then start
#   ./manufapp.sh status    # docker compose ps
#   ./manufapp.sh logs [service...]   # follow logs, all services or the ones named

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

ENV_FILE=.env.server
COMPOSE_FILE=docker-compose.server.yml

usage() {
  echo "Usage: $0 {setup|start|stop|restart|status|logs [service...]}" >&2
  exit 1
}

cmd="${1:-}"
shift || true

if [ "$cmd" = "setup" ]; then
  SUDO=""
  if [ "$(id -u)" -ne 0 ]; then
    SUDO="sudo"
  fi

  if command -v docker >/dev/null 2>&1; then
    echo "docker already installed, skipping."
  else
    echo "Installing Docker Engine + Compose plugin..."
    $SUDO apt-get update
    $SUDO apt-get install -y ca-certificates curl gnupg
    $SUDO install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | $SUDO gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    $SUDO chmod a+r /etc/apt/keyrings/docker.gpg
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      $SUDO tee /etc/apt/sources.list.d/docker.list > /dev/null
    $SUDO apt-get update
    $SUDO apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    $SUDO systemctl enable --now docker
  fi

  if command -v aws >/dev/null 2>&1; then
    echo "aws cli already installed, skipping."
  else
    echo "Installing AWS CLI v2..."
    $SUDO apt-get install -y unzip
    tmpdir=$(mktemp -d)
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o "$tmpdir/awscliv2.zip"
    unzip -q "$tmpdir/awscliv2.zip" -d "$tmpdir"
    $SUDO "$tmpdir/aws/install"
    rm -rf "$tmpdir"
  fi

  echo
  echo "Setup done. Next:"
  echo "  cp .env.server.example .env.server   # fill in real values"
  echo "  aws configure                        # credentials with ECR pull access, if not already set up"
  echo "  ./manufapp.sh start"
  exit 0
fi

if [ ! -f "$ENV_FILE" ]; then
  echo "Missing $ENV_FILE - copy .env.server.example to $ENV_FILE and fill in real values first." >&2
  exit 1
fi

COMPOSE=(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE")

get_env() {
  local key="$1" default="$2" val
  val=$(grep -E "^${key}=" "$ENV_FILE" | tail -1 | cut -d= -f2-)
  echo "${val:-$default}"
}

AWS_REGION=$(get_env AWS_REGION ap-south-1)
AWS_ACCOUNT_ID=$(get_env AWS_ACCOUNT_ID 002429227764)
DB_HOST=$(get_env DB_HOST host.docker.internal)
DB_NAME=$(get_env DB_NAME manufapp)
DB_USER=$(get_env DB_USER caretaker)
DB_PASSWORD=$(get_env DB_PASSWORD "")
DB_PORT=$(get_env DB_PORT 5432)

# Bare-metal Postgres on this same host needs three things a fresh install never has out of
# the box, and each one produces a different opaque error if missed:
#   1. listen_addresses defaults to 'localhost' - the container can't even open a TCP
#      connection ("Connection refused") until Postgres also listens on the docker0 bridge
#      gateway IP that host.docker.internal/host-gateway resolves to.
#   2. pg_hba.conf defaults to only trusting 127.0.0.1/::1 - without a rule for Docker's
#      bridge address-pool range, step 1 alone still gets rejected at the network layer.
#   3. A fresh Postgres has no role/database/extension for this app at all - migrate fails
#      with "password authentication failed" (no role) or later with "operator class
#      gin_trgm_ops does not exist" (no pg_trgm) once auth is fixed.
# Idempotent and safe to run on every `start`: no-ops (and skips the restart) once configured.
ensure_local_postgres() {
  if [ "$DB_HOST" != "host.docker.internal" ] && [ "$DB_HOST" != "localhost" ] && [ "$DB_HOST" != "127.0.0.1" ]; then
    return 0
  fi
  if ! command -v psql >/dev/null 2>&1 && ! command -v pg_lsclusters >/dev/null 2>&1; then
    return 0
  fi
  if [ -z "$DB_PASSWORD" ]; then
    echo "DB_PASSWORD is empty in $ENV_FILE, skipping local Postgres provisioning." >&2
    return 0
  fi

  local SUDO=""
  [ "$(id -u)" -ne 0 ] && SUDO="sudo"
  # Switching to the postgres OS user is a separate concern from the general "am I root"
  # SUDO prefix above - needed even when we're already root, since the target user differs.
  local PG_PSQL="sudo -u postgres psql"

  local pg_conf pg_hba
  pg_conf=$($SUDO find /etc/postgresql -maxdepth 3 -name postgresql.conf 2>/dev/null | sort -V | tail -1)
  if [ -z "$pg_conf" ]; then
    echo "psql found but no /etc/postgresql/*/main/postgresql.conf - skipping local DB provisioning (unfamiliar layout, check manually)." >&2
    return 0
  fi
  pg_hba="$(dirname "$pg_conf")/pg_hba.conf"

  # This is what host.docker.internal (via extra_hosts: host-gateway) actually resolves to -
  # confirmed empirically, it's docker0's address even for containers on a custom compose
  # network, not that network's own gateway.
  local docker_gw
  docker_gw=$(ip -4 addr show docker0 2>/dev/null | grep -oP 'inet \K[\d.]+' | head -1)
  docker_gw="${docker_gw:-172.17.0.1}"

  local changed=0

  # sed -i / tee -a rewrite the file, which drops root:root perms back to whatever the
  # invoking user defaults to - Postgres (running as the postgres user) then can't read its
  # own config. Preserve ownership/mode explicitly every time we touch these files.
  local owner perms
  if ! $SUDO grep -E "^listen_addresses" "$pg_conf" 2>/dev/null | grep -qF "$docker_gw"; then
    owner=$($SUDO stat -c '%U:%G' "$pg_conf")
    perms=$($SUDO stat -c '%a' "$pg_conf")
    if $SUDO grep -qE "^\s*#?\s*listen_addresses" "$pg_conf"; then
      $SUDO sed -i -E "s/^\s*#?\s*listen_addresses\s*=.*/listen_addresses = 'localhost,${docker_gw}'/" "$pg_conf"
    else
      printf '\nlisten_addresses = '"'"'localhost,%s'"'"'\n' "$docker_gw" | $SUDO tee -a "$pg_conf" >/dev/null
    fi
    $SUDO chown "$owner" "$pg_conf"
    $SUDO chmod "$perms" "$pg_conf"
    changed=1
  fi

  local hba_line="host    ${DB_NAME}    ${DB_USER}    172.16.0.0/12    scram-sha-256"
  # Match on fields, not exact spacing - pg_hba.conf columns are hand-aligned and a rule
  # added by a human (or a prior version of this script) can have different whitespace
  # than what we'd write, which a plain string/-F match would miss and duplicate.
  if ! $SUDO grep -qE "^host[[:space:]]+${DB_NAME}[[:space:]]+${DB_USER}[[:space:]]+172\.16\.0\.0/12[[:space:]]+scram-sha-256" "$pg_hba" 2>/dev/null; then
    owner=$($SUDO stat -c '%U:%G' "$pg_hba")
    perms=$($SUDO stat -c '%a' "$pg_hba")
    { echo ""; echo "# manufapp docker-compose stack (see manufapp.sh ensure_local_postgres)"; echo "$hba_line"; } \
      | $SUDO tee -a "$pg_hba" >/dev/null
    $SUDO chown "$owner" "$pg_hba"
    $SUDO chmod "$perms" "$pg_hba"
    changed=1
  fi

  if [ "$changed" = "1" ]; then
    echo "Updated Postgres config for Docker connectivity (listen_addresses/pg_hba.conf), restarting postgresql..."
    $SUDO systemctl restart postgresql
    sleep 2
  fi

  # psql only does client-side :'var' substitution outside dollar-quoted strings, so this
  # can't be a DO $$ ... $$ block (the substitution would silently not happen inside it) -
  # build each statement with format() and run it via \gexec instead.
  $PG_PSQL -v ON_ERROR_STOP=1 -v dbuser="$DB_USER" -v dbpass="$DB_PASSWORD" <<-'SQL'
	SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'dbuser', :'dbpass')
	WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = :'dbuser')
	\gexec
	SELECT format('ALTER ROLE %I WITH LOGIN PASSWORD %L', :'dbuser', :'dbpass')
	\gexec
	SQL

  $PG_PSQL -v ON_ERROR_STOP=1 -v dbname="$DB_NAME" -v dbuser="$DB_USER" <<-'SQL'
	SELECT format('CREATE DATABASE %I OWNER %I', :'dbname', :'dbuser')
	WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = :'dbname')
	\gexec
	SQL

  # core.0002_auto_20260625_0555 needs this for a GIN trigram index - CREATE EXTENSION
  # requires connecting to the target database itself, so this can't fold into the block above.
  $PG_PSQL -v ON_ERROR_STOP=1 -d "$DB_NAME" -c "CREATE EXTENSION IF NOT EXISTS pg_trgm;" >/dev/null
}

case "$cmd" in
  start)
    ensure_local_postgres
    aws ecr get-login-password --region "${AWS_REGION:-ap-south-1}" \
      | docker login --username AWS --password-stdin "${AWS_ACCOUNT_ID:-002429227764}.dkr.ecr.${AWS_REGION:-ap-south-1}.amazonaws.com"
    "${COMPOSE[@]}" pull
    "${COMPOSE[@]}" up -d
    "${COMPOSE[@]}" ps
    ;;
  stop)
    "${COMPOSE[@]}" down
    ;;
  restart)
    "${COMPOSE[@]}" down
    "$0" start
    ;;
  status)
    "${COMPOSE[@]}" ps
    ;;
  logs)
    "${COMPOSE[@]}" logs -f --tail 200 "$@"
    ;;
  *)
    usage
    ;;
esac
