#!/usr/bin/env bash
#
# Builds browsable HTML documentation from the mobile contract and opens it.
#
#   bash scripts/api-docs.sh
#
# Note: `redocly preview-docs` was removed in Redocly CLI v2. `build-docs` is the
# replacement, and it produces a single self-contained file you can also attach
# to a ticket or send to the mobile team.

set -uo pipefail
cd "$(dirname "$0")/.."

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; DIM=$'\033[2m'; RESET=$'\033[0m'

SPEC="${1:-contracts/openapi/mobile-bff.v1.yaml}"
OUT="build/api-docs.html"

if ! command -v redocly >/dev/null 2>&1; then
  echo "${RED}redocly is not installed.${RESET}"
  echo "  npm install -g @redocly/cli@latest"
  exit 1
fi

if [ ! -f "$SPEC" ]; then
  echo "${RED}Spec not found: ${SPEC}${RESET}"
  exit 1
fi

mkdir -p build

# Lint first. Generating docs from an invalid contract produces a page that looks
# authoritative and is wrong, which is worse than no page at all.
if ! redocly lint "$SPEC" --format=stylish; then
  echo
  echo "${RED}Contract has lint errors — fix them before generating docs.${RESET}"
  exit 1
fi

echo
if ! redocly build-docs "$SPEC" -o "$OUT"; then
  echo "${RED}Doc generation failed.${RESET}"
  exit 1
fi

echo
echo "${GREEN}Built:${RESET} ${OUT}"

case "$(uname -s)" in
  Darwin) open "$OUT" ;;
  Linux)  command -v xdg-open >/dev/null 2>&1 && xdg-open "$OUT" >/dev/null 2>&1 || true ;;
  *)      echo "${DIM}Open it in your browser: ${OUT}${RESET}" ;;
esac
