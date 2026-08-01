#!/usr/bin/env bash
# Wrapper around docker-compose.server.yml - start/stop/logs for the on-prem/customer
# server stack (nginx, react, django, celery, celery-beat, redis).
#
# Usage:
#   ./manufapp.sh start     # aws ecr login, pull latest images, up -d
#   ./manufapp.sh stop      # down
#   ./manufapp.sh restart   # stop, then start
#   ./manufapp.sh status    # docker compose ps
#   ./manufapp.sh logs [service...]   # follow logs, all services or the ones named

set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

ENV_FILE=.env.server
COMPOSE_FILE=docker-compose.server.yml
COMPOSE=(docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE")

if [ ! -f "$ENV_FILE" ]; then
  echo "Missing $ENV_FILE - copy .env.server.example to $ENV_FILE and fill in real values first." >&2
  exit 1
fi

get_env() {
  local key="$1" default="$2" val
  val=$(grep -E "^${key}=" "$ENV_FILE" | tail -1 | cut -d= -f2-)
  echo "${val:-$default}"
}

AWS_REGION=$(get_env AWS_REGION ap-south-1)
AWS_ACCOUNT_ID=$(get_env AWS_ACCOUNT_ID 002429227764)

usage() {
  echo "Usage: $0 {start|stop|restart|status|logs [service...]}" >&2
  exit 1
}

cmd="${1:-}"
shift || true

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
