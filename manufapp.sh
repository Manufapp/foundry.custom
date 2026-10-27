#!/usr/bin/env bash
# Wrapper around docker-compose.server.yml - setup/start/stop/logs for the on-prem/customer
# server stack (nginx, react, django, celery, celery-beat, redis).
#
# Usage:
#   ./manufapp.sh setup     # Ubuntu only - install/configure Docker, AWS CLI v2 + credentials, Postgres
#   IMAGE_TAG_FE=1.39.0 IMAGE_TAG_BE=v1.39.0 ./manufapp.sh start     # aws ecr login, pull those image tags, up -d
#   ./manufapp.sh stop      # down
#   IMAGE_TAG_FE=1.39.0 IMAGE_TAG_BE=v1.39.0 ./manufapp.sh restart   # stop, then start
#   ./manufapp.sh status    # docker compose ps
#   ./manufapp.sh record-version   # re-record running versions for the infra versions page
#                                  # (start does this itself; use after a manual `compose up`)
#   ./manufapp.sh logs [service...]   # follow logs, all services or the ones named
#   ./manufapp.sh remove    # undo setup - tears down the stack, asks before touching
#                           # Postgres data or uninstalling Docker/AWS CLI/Postgres itself
#
# IMAGE_TAG_FE/IMAGE_TAG_BE are required env vars for start/restart - passed on the
# command line (not read from .env.server), so the image versions actually running
# are always an explicit, visible part of the command.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

ENV_FILE=.env.server
COMPOSE_FILE=docker-compose.server.yml

usage() {
  echo "Usage: $0 {setup|start|stop|restart|status|logs [service...]|record-version|remove}" >&2
  echo "  start/restart also need IMAGE_TAG_FE/IMAGE_TAG_BE set, e.g.:" >&2
  echo "  IMAGE_TAG_FE=1.39.0 IMAGE_TAG_BE=v1.39.0 $0 start" >&2
  exit 1
}

# Prompts for a literal "yes" and echoes back the answer (defaulting to "no" - including
# on EOF, e.g. stdin isn't a terminal) - never treat "unanswered" as consent for a
# destructive step.
confirm() {
  local prompt="$1" reply=""
  read -r -p "$prompt [type 'yes' to confirm]: " reply || true
  [ "$reply" = "yes" ]
}

cmd="${1:-}"
shift || true

get_env() {
  local key="$1" default="$2" val=""
  if [ -f "$ENV_FILE" ]; then
    val=$(grep -E "^${key}=" "$ENV_FILE" | tail -1 | cut -d= -f2- || true)
  fi
  echo "${val:-$default}"
}

if [ "$cmd" = "setup" ]; then
  SUDO=""
  if [ "$(id -u)" -ne 0 ]; then
    SUDO="sudo"
  fi

  # `sudo -u postgres ...` below switches to the postgres OS user for peer-auth
  # psql access - needed even when we're already root, so make sure it exists
  # rather than trying to special-case root out of using sudo entirely.
  if ! command -v sudo >/dev/null 2>&1; then
    apt-get update
    apt-get install -y sudo
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

  if aws sts get-caller-identity >/dev/null 2>&1; then
    echo "aws credentials already configured, skipping."
  else
    echo "Configuring AWS credentials (needed for ECR pull access)..."
    aws configure
  fi

  DB_NAME=$(get_env DB_NAME manufapp)
  DB_USER=$(get_env DB_USER caretaker)
  DB_PASSWORD=$(get_env DB_PASSWORD caretaker)

  if command -v psql >/dev/null 2>&1; then
    echo "postgresql already installed, skipping install."
  else
    echo "Installing PostgreSQL..."
    $SUDO apt-get update
    $SUDO apt-get install -y postgresql postgresql-contrib
    $SUDO systemctl enable --now postgresql
  fi

  echo "Configuring role/database/extension ($DB_USER/$DB_NAME)..."
  sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${DB_USER}'" | grep -q 1 \
    || sudo -u postgres createuser -s "$DB_USER"
  sudo -u postgres psql -c "ALTER USER \"${DB_USER}\" WITH PASSWORD '${DB_PASSWORD}';" >/dev/null
  sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1 \
    || sudo -u postgres createdb "$DB_NAME" -O "$DB_USER"
  # core.0002_auto_20260625_0555 needs this for a GIN trigram index - see README.
  sudo -u postgres psql -d "$DB_NAME" -c "CREATE EXTENSION IF NOT EXISTS pg_trgm;" >/dev/null

  PG_CONF_DIR=$(sudo -u postgres psql -tAc "SHOW config_file;" | xargs dirname)
  PG_CONF="$PG_CONF_DIR/postgresql.conf"
  PG_HBA="$PG_CONF_DIR/pg_hba.conf"

  # Containers reach Postgres over the Docker bridge, not localhost - a default
  # install only listens on localhost and only trusts 127.0.0.1 in pg_hba.conf.
  if $SUDO grep -qE "^\s*listen_addresses\s*=\s*'\*'" "$PG_CONF"; then
    echo "listen_addresses already '*', skipping."
  else
    echo "Setting listen_addresses = '*' in $PG_CONF..."
    $SUDO sed -i "s/^#\?listen_addresses.*/listen_addresses = '*'/" "$PG_CONF"
  fi

  # Covers Docker's default bridge allocation range (172.17.0.0-172.31.255.255);
  # a custom compose network (e.g. this stack's manufapp_default) gets a subnet
  # from within this range too. Narrow this down if that's too broad for your setup.
  DOCKER_SUBNET="172.16.0.0/12"
  if $SUDO grep -q "$DOCKER_SUBNET" "$PG_HBA"; then
    echo "pg_hba.conf already allows $DOCKER_SUBNET, skipping."
  else
    echo "Adding pg_hba.conf entry for $DOCKER_SUBNET..."
    echo "host    all             all             $DOCKER_SUBNET          scram-sha-256" | $SUDO tee -a "$PG_HBA" > /dev/null
  fi

  # listen_addresses is postmaster-level - a reload won't pick it up, needs a full restart.
  $SUDO systemctl restart postgresql

  echo
  echo "Setup done. Next:"
  echo "  cp .env.server.example .env.server   # fill in real values"
  echo "  IMAGE_TAG_FE=<fe_tag> IMAGE_TAG_BE=<be_tag> ./manufapp.sh start"
  exit 0
fi

if [ "$cmd" = "remove" ]; then
  SUDO=""
  if [ "$(id -u)" -ne 0 ]; then
    SUDO="sudo"
  fi

  DB_NAME=$(get_env DB_NAME manufapp)
  DB_USER=$(get_env DB_USER caretaker)

  # Tears down what setup/start provisioned, most destructive last - each of the two
  # steps that touch real data or host-wide packages asks for explicit confirmation
  # first, since this repo has no way to know if Postgres/Docker/the AWS profile here
  # are also used by anything else on this box.
  if [ -f "$COMPOSE_FILE" ]; then
    echo "Stopping and removing the docker-compose stack (containers, network, volumes)..."
    if [ -f "$ENV_FILE" ]; then
      docker compose -f "$COMPOSE_FILE" --env-file "$ENV_FILE" down -v --remove-orphans
    else
      docker compose -f "$COMPOSE_FILE" down -v --remove-orphans
    fi
  else
    echo "$COMPOSE_FILE not found, skipping stack teardown."
  fi

  echo
  if confirm "Drop the '$DB_NAME' database and '$DB_USER' role, and revert the pg_hba.conf/postgresql.conf changes setup/start made"; then
    if command -v psql >/dev/null 2>&1; then
      echo "Dropping database '$DB_NAME' and role '$DB_USER'..."
      sudo -u postgres psql -c "DROP DATABASE IF EXISTS \"${DB_NAME}\";" >/dev/null
      sudo -u postgres psql -c "DROP ROLE IF EXISTS \"${DB_USER}\";" >/dev/null

      PG_CONF_DIR=$(sudo -u postgres psql -tAc "SHOW config_file;" | xargs dirname)
      PG_CONF="$PG_CONF_DIR/postgresql.conf"
      PG_HBA="$PG_CONF_DIR/pg_hba.conf"

      # sed -i rewrites the file, which drops root:root perms back to whatever the invoking
      # user defaults to - Postgres (running as the postgres user) then can't read its own
      # config. Preserve ownership/mode explicitly, same as ensure_local_postgres does.
      for f in "$PG_CONF" "$PG_HBA"; do
        owner=$($SUDO stat -c '%U:%G' "$f")
        perms=$($SUDO stat -c '%a' "$f")
        if [ "$f" = "$PG_CONF" ]; then
          echo "Reverting listen_addresses to 'localhost' in $f..."
          $SUDO sed -i -E "s/^\s*#?\s*listen_addresses\s*=.*/listen_addresses = 'localhost'/" "$f"
        else
          echo "Removing the docker-bridge access rule(s) added to $f..."
          $SUDO sed -i -E '/172\.16\.0\.0\/12/d; /# manufapp docker-compose stack/d' "$f"
        fi
        $SUDO chown "$owner" "$f"
        $SUDO chmod "$perms" "$f"
      done

      $SUDO systemctl restart postgresql
    else
      echo "psql not found, nothing to revert."
    fi
  else
    echo "Skipping Postgres database/role/config removal."
  fi

  echo
  if confirm "Uninstall Docker Engine, AWS CLI v2, and the PostgreSQL server package, and clear this user's ~/.aws credentials (affects the whole host, not just this app)"; then
    echo "Uninstalling PostgreSQL server..."
    $SUDO apt-get purge -y postgresql postgresql-contrib >/dev/null 2>&1 || true
    echo "Uninstalling Docker Engine..."
    $SUDO apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null 2>&1 || true
    echo "Uninstalling AWS CLI v2 and clearing ~/.aws..."
    $SUDO rm -rf /usr/local/aws-cli /usr/local/bin/aws /usr/local/bin/aws_completer
    rm -rf "${HOME:?}/.aws"
    $SUDO apt-get autoremove -y >/dev/null 2>&1 || true
  else
    echo "Skipping Docker/AWS CLI/PostgreSQL package removal."
  fi

  echo
  echo "Remove done."
  exit 0
fi

if [ ! -f "$ENV_FILE" ]; then
  echo "Missing $ENV_FILE - copy .env.server.example to $ENV_FILE and fill in real values first." >&2
  exit 1
fi

COMPOSE=(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE")

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

# nginx is the single entry point (port 80, see README "Why nginx") - print what to
# actually type into a browser instead of leaving that as a guess after `up -d`.
print_access_urls() {
  echo
  echo "App is served through nginx on port 80. Access it at:"
  local local_ip public_ip
  local_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  [ -n "$local_ip" ] && echo "  http://$local_ip   (same network/VPN as this server)"
  # Best-effort only - times out fast and is silently skipped if this box has no
  # internet egress or the lookup service is unreachable.
  public_ip=$(curl -fsSL --max-time 3 https://api.ipify.org 2>/dev/null || true)
  if [ -n "$public_ip" ] && [ "$public_ip" != "$local_ip" ]; then
    echo "  http://$public_ip   (public internet - only reachable if this host's firewall/router forwards port 80 to it)"
  fi
  echo "  (or any hostname/DNS record you've pointed at this server)"
}

# Records the running BE/FE image versions in Firestore platform_versions/$SERVER_NAME, which
# the infra "Deployed versions" page lists next to every cloud server (this box can't be
# polled from outside). The writer runs inside the django container, which already carries
# the Firebase key - so nothing extra is needed on this host. Re-recording an unchanged
# version is a no-op, so this is safe after any start/restart or a manual `compose up`.
record_version() {
  local server be fe service version
  server=$(get_env SERVER_NAME "")
  if [ -z "$server" ]; then
    echo "SERVER_NAME is not set in $ENV_FILE - skipping version record for the infra versions page."
    return 0
  fi
  be=$(docker inspect -f '{{.Config.Image}}' manufapp-django 2>/dev/null | sed 's/.*://')
  fe=$(docker inspect -f '{{.Config.Image}}' manufapp-react 2>/dev/null | sed 's/.*://')
  for service in be fe; do
    if [ "$service" = be ]; then version=$be; else version=$fe; fi
    [ -n "$version" ] || { echo "WARN: no running $service container - not recording its version."; continue; }
    docker exec -e DEPLOY_PLATFORM=onprem -e DEPLOYED_BY="${SUDO_USER:-${USER:-}}" manufapp-django \
      python scripts/write_firebase_version.py "$service" "$version" "$server" \
      || echo "WARN: could not record $service=$version in Firestore - the deploy itself is fine."
  done
}

case "$cmd" in
  start)
    if [ -z "${IMAGE_TAG_FE:-}" ] || [ -z "${IMAGE_TAG_BE:-}" ]; then
      echo "IMAGE_TAG_FE and IMAGE_TAG_BE must be set as environment variables, e.g.:" >&2
      echo "  IMAGE_TAG_FE=1.39.0 IMAGE_TAG_BE=v1.39.0 $0 start" >&2
      exit 1
    fi
    ensure_local_postgres
    aws ecr get-login-password --region "${AWS_REGION:-ap-south-1}" \
      | docker login --username AWS --password-stdin "${AWS_ACCOUNT_ID:-002429227764}.dkr.ecr.${AWS_REGION:-ap-south-1}.amazonaws.com"
    "${COMPOSE[@]}" pull
    "${COMPOSE[@]}" up -d
    "${COMPOSE[@]}" ps
    record_version
    print_access_urls
    ;;
  record-version)
    record_version
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
