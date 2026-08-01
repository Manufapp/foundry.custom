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
#   ./manufapp.sh logs [service...]   # follow logs, all services or the ones named
#
# IMAGE_TAG_FE/IMAGE_TAG_BE are required env vars for start/restart - passed on the
# command line (not read from .env.server), so the image versions actually running
# are always an explicit, visible part of the command.

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

ENV_FILE=.env.server
COMPOSE_FILE=docker-compose.server.yml

usage() {
  echo "Usage: $0 {setup|start|stop|restart|status|logs [service...]}" >&2
  echo "  start/restart also need IMAGE_TAG_FE/IMAGE_TAG_BE set, e.g.:" >&2
  echo "  IMAGE_TAG_FE=1.39.0 IMAGE_TAG_BE=v1.39.0 $0 start" >&2
  exit 1
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

if [ ! -f "$ENV_FILE" ]; then
  echo "Missing $ENV_FILE - copy .env.server.example to $ENV_FILE and fill in real values first." >&2
  exit 1
fi

COMPOSE=(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE")

AWS_REGION=$(get_env AWS_REGION ap-south-1)
AWS_ACCOUNT_ID=$(get_env AWS_ACCOUNT_ID 002429227764)

case "$cmd" in
  start)
    if [ -z "${IMAGE_TAG_FE:-}" ] || [ -z "${IMAGE_TAG_BE:-}" ]; then
      echo "IMAGE_TAG_FE and IMAGE_TAG_BE must be set as environment variables, e.g.:" >&2
      echo "  IMAGE_TAG_FE=1.39.0 IMAGE_TAG_BE=v1.39.0 $0 start" >&2
      exit 1
    fi
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
