#!/usr/bin/env bash
#
# Starts the local stack, checking for port collisions first so you get a clear
# message instead of a Docker daemon error halfway through pulling images.
#
#   bash scripts/dev-up.sh
#
# Equivalent to `docker compose up -d`, with a preflight check and a wait for
# everything to report healthy.

set -uo pipefail
cd "$(dirname "$0")/.."

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[0;33m'; DIM=$'\033[2m'; RESET=$'\033[0m'

# Defaults must match docker-compose.yml. A .env file overrides them.
SR_POSTGRES_PORT="${SR_POSTGRES_PORT:-5433}"
SR_REDIS_PORT="${SR_REDIS_PORT:-6380}"
SR_LOCALSTACK_PORT="${SR_LOCALSTACK_PORT:-4566}"

if [ -f .env ]; then
  # shellcheck disable=SC1091
  set -a; . ./.env; set +a
  echo "${DIM}Using overrides from .env${RESET}"
fi

if ! docker info >/dev/null 2>&1; then
  echo "${RED}Docker is not running.${RESET}"
  echo "  Start Docker Desktop and wait for the whale icon to stop animating."
  exit 1
fi

port_holder() {
  if command -v lsof >/dev/null 2>&1; then
    lsof -nP -iTCP:"$1" -sTCP:LISTEN 2>/dev/null | awk 'NR==2 {print $1" (pid "$2")"}'
  fi
}

echo
echo "${DIM}Checking ports...${RESET}"

COLLISION=0
check_port() {
  local port="$1" name="$2" var="$3"
  # A port held by our own container is fine — that just means it is already up.
  if docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | grep -q "socialremit-.*:${port}->"; then
    echo "  ${GREEN}✓${RESET} ${port} — already held by our own ${name} container"
    return
  fi
  local holder; holder="$(port_holder "$port")"
  if [ -n "$holder" ]; then
    echo "  ${RED}✗${RESET} ${port} (${name}) is in use by ${holder}"
    echo "      Stop it, or set ${var} to a free port in .env"
    COLLISION=1
  else
    echo "  ${GREEN}✓${RESET} ${port} (${name}) is free"
  fi
}

check_port "$SR_POSTGRES_PORT"   "postgres"   "SR_POSTGRES_PORT"
check_port "$SR_REDIS_PORT"      "redis"      "SR_REDIS_PORT"
check_port "$SR_LOCALSTACK_PORT" "localstack" "SR_LOCALSTACK_PORT"

if [ "$COLLISION" -ne 0 ]; then
  echo
  echo "${YELLOW}Fix the collisions above, then run this again.${RESET}"
  echo "${DIM}To change a port:${RESET}"
  echo "  cp .env.example .env      # if you have not already"
  echo "  # edit the port, then:"
  echo "  docker compose down && bash scripts/dev-up.sh"
  exit 1
fi

echo
echo "${DIM}Starting containers (first run pulls images — this can take several minutes)...${RESET}"
if ! docker compose up -d; then
  echo
  echo "${RED}Startup failed.${RESET} Clear any partial state and retry:"
  echo "  docker compose down"
  echo "  bash scripts/dev-up.sh"
  exit 1
fi

echo
echo "${DIM}Waiting for health checks...${RESET}"
for _ in $(seq 1 60); do
  unhealthy="$(docker compose ps --format '{{.Name}} {{.Health}}' 2>/dev/null \
               | awk '$2 != "healthy" && $2 != "" {print $1}')"
  [ -z "$unhealthy" ] && break
  sleep 2
done

docker compose ps --format 'table {{.Name}}\t{{.Status}}'

echo
if [ -n "${unhealthy:-}" ]; then
  echo "${YELLOW}Some containers are not healthy yet:${RESET} ${unhealthy}"
  echo "${DIM}Give it another minute, then check logs:  docker compose logs ${unhealthy}${RESET}"
else
  echo "${GREEN}All containers healthy.${RESET}"
fi

echo
echo "${DIM}Next:${RESET}  bash scripts/dev-db.sh    ${DIM}(creates the tables)${RESET}"
