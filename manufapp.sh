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

case "$cmd" in
  start)
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
