#!/usr/bin/env bash
#
# Applies the platform building-block tables to your local database.
#
#   ./scripts/dev-db.sh              apply to the default dev database
#   ./scripts/dev-db.sh --reset      drop and recreate first
#
# Requires: docker compose up -d  (see GETTING_STARTED.md step E)

set -euo pipefail
cd "$(dirname "$0")/.."

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; DIM=$'\033[2m'; RESET=$'\033[0m'

CONTAINER="socialremit-postgres"
DB_USER="socialremit"
DB_NAME="${SR_DB_NAME:-socialremit_dev}"

# Each service owns a schema. In production these become separate databases;
# locally they are schemas so one container serves the whole estate.
SCHEMAS=(
  identity_access
  customer_journey
  consent_legal
  notification
  audit_reporting
  provider_integration
  mobile_bff
)

if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
  echo "${RED}The ${CONTAINER} container is not running.${RESET}"
  echo "  Start it with:  docker compose up -d"
  exit 1
fi

echo "${DIM}Waiting for PostgreSQL to accept connections...${RESET}"
for _ in $(seq 1 30); do
  if docker exec "$CONTAINER" pg_isready -U "$DB_USER" -d "$DB_NAME" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! docker exec "$CONTAINER" pg_isready -U "$DB_USER" -d "$DB_NAME" >/dev/null 2>&1; then
  echo "${RED}PostgreSQL did not become ready within 30 seconds.${RESET}"
  echo "  Check the logs:  docker compose logs postgres"
  exit 1
fi

if [ "${1:-}" = "--reset" ]; then
  echo "${DIM}Dropping all service schemas...${RESET}"
  for schema in "${SCHEMAS[@]}"; do
    docker exec -i "$CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -q \
      -c "DROP SCHEMA IF EXISTS ${schema} CASCADE;"
  done
fi

echo
echo "Applying platform building blocks to ${#SCHEMAS[@]} schemas"
echo

for schema in "${SCHEMAS[@]}"; do
  # search_path scopes the migration to one schema, so the same file produces an
  # independent copy of outbox/inbox/idempotency per service — exactly as it will
  # be in production, where each service has its own database entirely.
  {
    echo "CREATE SCHEMA IF NOT EXISTS ${schema};"
    echo "SET search_path TO ${schema};"
    cat db/platform/001_building_blocks.sql
  } | docker exec -i "$CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -q -v ON_ERROR_STOP=1

  echo "  ${GREEN}✓${RESET} ${schema}"
done

echo
echo "${GREEN}Done.${RESET} Each schema now has outbox_events, inbox_messages and idempotency_records."
echo
echo "${DIM}Inspect them with:${RESET}"
echo "  docker exec -it ${CONTAINER} psql -U ${DB_USER} -d ${DB_NAME} -c '\\dt identity_access.*'"
echo
echo "${DIM}What these tables do is explained in docs/HOW_IT_WORKS.md${RESET}"
