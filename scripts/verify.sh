#!/usr/bin/env bash
#
# Runs the same checks CI runs, locally, in a few seconds.
# Run this before every push.
#
#   ./scripts/verify.sh
#
# Exit code 0 means CI will pass these checks too.

set -uo pipefail
cd "$(dirname "$0")/.."

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YELLOW=$'\033[0;33m'; DIM=$'\033[2m'; RESET=$'\033[0m'
FAILURES=0
GAPS_COUNT=0
GAPS_TEXT=""

pass() { echo "  ${GREEN}✓${RESET} $1"; }
fail() { echo "  ${RED}✗${RESET} $1"; FAILURES=$((FAILURES + 1)); }
skip() { echo "  ${YELLOW}−${RESET} $1 ${DIM}(skipped)${RESET}"; }
gap()  { echo "  ${YELLOW}!${RESET} $1"; GAPS_COUNT=$((GAPS_COUNT + 1)); GAPS_TEXT="${GAPS_TEXT}${1}\n"; }
section() { echo; echo "${DIM}──${RESET} $1"; }

PYTHON=$(command -v python3 || command -v python)
if [ -z "$PYTHON" ]; then
  echo "${RED}Python 3 is required. See GETTING_STARTED.md step A4.${RESET}"
  exit 1
fi

# ---------------------------------------------------------------------------
section "Structural validity"
# ---------------------------------------------------------------------------

if "$PYTHON" -c "import yaml" 2>/dev/null; then
  for file in contracts/openapi/*.yaml redocly.yaml .github/workflows/*.yml docker-compose.yml; do
    [ -f "$file" ] || continue
    if "$PYTHON" -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$file" 2>/dev/null; then
      pass "$file parses"
    else
      fail "$file is not valid YAML"
      "$PYTHON" -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$file" 2>&1 | tail -3 | sed 's/^/      /'
    fi
  done
else
  # Tracked, not silently swallowed. A skipped check reads like a passing one at
  # a glance, which is how a broken workflow file reaches CI unnoticed.
  gap "YAML parsing — install with:  $PYTHON -m pip install pyyaml"
fi

for file in contracts/events/*.json contracts/errors/*.json; do
  [ -f "$file" ] || continue
  if "$PYTHON" -c "import json,sys; json.load(open(sys.argv[1]))" "$file" 2>/dev/null; then
    pass "$file parses"
  else
    fail "$file is not valid JSON"
  fi
done

# ---------------------------------------------------------------------------
section "OpenAPI contract"
# ---------------------------------------------------------------------------

if command -v redocly >/dev/null 2>&1; then
  # stylish, not summary: a summary tells you "struct: 2" and nothing about WHERE.
  # That cost a real debugging session, so the full output is the default now.
  if redocly lint contracts/openapi/*.yaml --format=stylish >/tmp/sr-redocly.log 2>&1; then
    pass "OpenAPI lint clean"
  else
    fail "OpenAPI lint reported problems"
    echo
    sed 's/^/      /' /tmp/sr-redocly.log
  fi
else
  skip "OpenAPI lint (npm install -g @redocly/cli)"
fi

# ---------------------------------------------------------------------------
section "Data protection"
# ---------------------------------------------------------------------------

# Nothing that could identify or impersonate a customer may appear in an event
# payload. Schema fields are checked here; the runtime guard in
# EventEnvelopeFactory catches anything a serializer adds later.
"$PYTHON" - <<'PY'
import json, pathlib, sys

envelope = pathlib.Path("contracts/events/envelope.schema.json")
if not envelope.exists():
    print("  \033[0;33m−\033[0m envelope schema not found (skipped)")
    sys.exit(0)

forbidden = {k.lower() for k in json.loads(envelope.read_text())["$defs"]["forbiddenPayloadKeys"]["const"]}
violations = []

for path in pathlib.Path("contracts/events").glob("*.schema.json"):
    if path.name == "envelope.schema.json":
        continue

    def walk(node, trail):
        if isinstance(node, dict):
            for key, value in node.items():
                if key == "properties" and isinstance(value, dict):
                    for prop in value:
                        if prop.lower() in forbidden:
                            violations.append(f"{path.name}: {'.'.join(trail)}.{prop}")
                walk(value, trail + [key])
        elif isinstance(node, list):
            for item in node:
                walk(item, trail)

    walk(json.loads(path.read_text()), [path.stem])

if violations:
    print("  \033[0;31m✗\033[0m Forbidden fields in event payloads:")
    for v in violations:
        print(f"      - {v}")
    sys.exit(1)

print("  \033[0;32m✓\033[0m No secrets in event payload schemas")
PY
[ $? -eq 0 ] || FAILURES=$((FAILURES + 1))

# Catches the case the schema lint cannot: a developer logging the value directly.
if grep -rnE '_logger\.Log[A-Za-z]*\([^)]*\b(passcode|otp|accessToken|refreshToken)\b' \
     --include='*.cs' building-blocks services 2>/dev/null | grep -v '//' > /tmp/sr-logleak.log; then
  if [ -s /tmp/sr-logleak.log ]; then
    fail "Possible secret in a log statement"
    sed 's/^/      /' /tmp/sr-logleak.log
  else
    pass "No secrets in log statements"
  fi
else
  pass "No secrets in log statements"
fi

# ---------------------------------------------------------------------------
section "Contract and code in sync"
# ---------------------------------------------------------------------------

# If the catalogue and the C# constants drift apart, the server sends a code the
# client has no copy for, and the customer sees a blank or wrong message.
"$PYTHON" - <<'PY'
import json, pathlib, re, sys

catalogue = pathlib.Path("contracts/errors/error-catalogue.json")
source = pathlib.Path("building-blocks/SocialRemit.BuildingBlocks.Api/ApiEnvelope.cs")

if not (catalogue.exists() and source.exists()):
    print("  \033[0;33m−\033[0m error catalogue sync (files not found)")
    sys.exit(0)

declared = {e["code"] for e in json.loads(catalogue.read_text())["errors"]}
generated = set(re.findall(r'=\s*"([A-Z][A-Z0-9_]+)"\s*;', source.read_text()))

missing, extra = declared - generated, generated - declared
if missing or extra:
    print("  \033[0;31m✗\033[0m Error catalogue out of sync with ErrorCodes.cs")
    if missing: print(f"      in catalogue, not in code: {sorted(missing)}")
    if extra:   print(f"      in code, not in catalogue: {sorted(extra)}")
    sys.exit(1)

print(f"  \033[0;32m✓\033[0m Error catalogue in sync ({len(declared)} codes)")
PY
[ $? -eq 0 ] || FAILURES=$((FAILURES + 1))

# ---------------------------------------------------------------------------
section "Service isolation"
# ---------------------------------------------------------------------------

# ADR 0001: a service may reference building-blocks and nothing else under /services.
"$PYTHON" - <<'PY'
import pathlib, re, sys

root = pathlib.Path("services")
if not root.exists() or not any(root.rglob("*.csproj")):
    print("  \033[0;33m−\033[0m service isolation (no service projects yet — expected at Step 1)")
    sys.exit(0)

violations = []
for csproj in root.rglob("*.csproj"):
    owner = csproj.relative_to(root).parts[0]
    for ref in re.findall(r'<ProjectReference\s+Include="([^"]+)"', csproj.read_text()):
        resolved = (csproj.parent / ref.replace("\\", "/")).resolve()
        try:
            referenced = resolved.relative_to(root.resolve()).parts[0]
        except ValueError:
            continue
        if referenced != owner:
            violations.append(f"{owner} -> {referenced}")

if violations:
    print("  \033[0;31m✗\033[0m Cross-service project reference (see docs/adr/0001-repository-topology.md)")
    for v in violations:
        print(f"      - {v}")
    sys.exit(1)

print("  \033[0;32m✓\033[0m No cross-service references")
PY
[ $? -eq 0 ] || FAILURES=$((FAILURES + 1))

# ---------------------------------------------------------------------------
section ".NET build"
# ---------------------------------------------------------------------------

if command -v dotnet >/dev/null 2>&1; then
  if ls ./*.sln >/dev/null 2>&1; then
    if dotnet build --configuration Release >/tmp/sr-build.log 2>&1; then
      pass "dotnet build succeeded"
    else
      fail "dotnet build failed"
      tail -25 /tmp/sr-build.log | sed 's/^/      /'
    fi
  else
    skip ".NET build (no solution file yet — arrives in Step 3)"
  fi
else
  skip ".NET build (dotnet not installed)"
fi

# ---------------------------------------------------------------------------
echo
if [ "$GAPS_COUNT" -gt 0 ]; then
  echo "${YELLOW}${GAPS_COUNT} check(s) could not run — your setup is incomplete:${RESET}"
  printf "%b" "$GAPS_TEXT" | while IFS= read -r g; do
    [ -n "$g" ] && echo "  ${YELLOW}!${RESET} $g"
  done
  echo
fi

if [ "$FAILURES" -eq 0 ]; then
  echo "${GREEN}ALL CHECKS PASSED${RESET}"
  exit 0
fi
echo "${RED}${FAILURES} CHECK(S) FAILED${RESET}"
echo "${DIM}Fix the items marked ✗ above and run again.${RESET}"
exit 1
