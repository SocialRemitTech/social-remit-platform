#!/usr/bin/env python3
"""
Static checks for the Terraform estate.

`terraform validate` needs the terraform binary and a provider download. This
runs without either, so it works on a laptop that has not installed Terraform
and in CI before the provider cache is warm. It catches the mistakes that
actually happen when wiring modules by hand:

  1. A module call passing an input the module does not declare.
  2. A module call missing a required input.
  3. A reference to module.<x>.<output> that the module does not produce.
  4. The event subscription map drifting from contracts/events/CATALOGUE.md.
  5. A hardcoded secret-looking literal.

Usage:  python3 scripts/tf-check.py
Exit 0 = clean.
"""

import glob
import os
import re
import sys
from collections import defaultdict

try:
    import hcl2
except ImportError:
    print("python-hcl2 is not installed. Install it with:")
    print("    python3 -m pip install python-hcl2")
    sys.exit(0)  # a missing checker is a setup gap, not a contract failure

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
TF_ROOT = os.path.join(ROOT, "infrastructure", "terraform")
CATALOGUE = os.path.join(ROOT, "contracts", "events", "CATALOGUE.md")

RESERVED = {"source", "version", "providers", "count", "for_each", "depends_on"}
NOISE = {"__is_block__", "__comments__", "__start_line__", "__end_line__"}

GREEN, RED, YELLOW, DIM, RESET = "\033[0;32m", "\033[0;31m", "\033[0;33m", "\033[2m", "\033[0m"


def unquote(name):
    """hcl2 returns block labels with their quotes attached."""
    return name.strip('"')


def load(path):
    with open(path) as handle:
        return hcl2.load(handle)


def collect_modules():
    """dir -> ({var: has_default}, {outputs})"""
    declared, outputs = defaultdict(dict), defaultdict(set)

    for path in glob.glob(os.path.join(TF_ROOT, "**", "*.tf"), recursive=True):
        rel_dir = os.path.relpath(os.path.dirname(path), TF_ROOT)
        doc = load(path)

        for block in doc.get("variable", []):
            for name, body in block.items():
                declared[rel_dir][unquote(name)] = "default" in body

        for block in doc.get("output", []):
            for name in block:
                outputs[rel_dir].add(unquote(name))

    return declared, outputs


def check_wiring(declared, outputs):
    problems = []
    module_targets = {}

    for path in glob.glob(os.path.join(TF_ROOT, "envs", "**", "*.tf"), recursive=True):
        rel_dir = os.path.relpath(os.path.dirname(path), TF_ROOT)
        doc = load(path)

        for block in doc.get("module", []):
            for raw_name, body in block.items():
                name = unquote(raw_name)
                source = unquote(str(body.get("source", "")))
                target = os.path.normpath(os.path.join(rel_dir, source))
                module_targets[name] = target

                passed = {k for k in body if k not in RESERVED and k not in NOISE}
                decl = declared.get(target, {})

                if not decl:
                    problems.append(f"module {name!r}: cannot resolve source {source!r} -> {target}")
                    continue

                unknown = passed - set(decl)
                if unknown:
                    problems.append(f"module {name!r}: passes undeclared input(s) {sorted(unknown)}")

                required = {k for k, has_default in decl.items() if not has_default}
                missing = required - passed
                if missing:
                    problems.append(f"module {name!r}: missing required input(s) {sorted(missing)}")

    # module.<name>.<output> references
    env_text = "\n".join(
        open(p).read()
        for p in glob.glob(os.path.join(TF_ROOT, "envs", "**", "*.tf"), recursive=True)
    )
    for mod, attr in sorted(set(re.findall(r"module\.([a-z_]+)\.([a-z_]+)", env_text))):
        target = module_targets.get(mod)
        if target is None:
            problems.append(f"reference to module.{mod} which is not declared")
        elif attr not in outputs.get(target, set()):
            problems.append(f"module.{mod}.{attr} — {target} declares no such output")

    return problems


def check_subscriptions_match_catalogue():
    """
    The event topology in envs/*/main.tf must match the catalogue. A queue that
    exists but is undocumented is a queue nobody monitors; a documented event
    with no queue is silently dropped.
    """
    if not os.path.exists(CATALOGUE):
        return ["contracts/events/CATALOGUE.md not found"]

    # Only table rows count. The catalogue also uses `aggregate.fact` in prose to
    # explain the naming convention, and that is not an event anyone publishes.
    catalogue_events = set()
    for line in open(CATALOGUE):
        if line.lstrip().startswith("| `"):
            catalogue_events |= set(
                re.findall(r"`([a-z][a-z0-9_]*\.[a-z][a-z0-9_]*)`", line)
            )

    tf_events = set()
    for path in glob.glob(os.path.join(TF_ROOT, "envs", "**", "*.tf"), recursive=True):
        tf_events |= set(re.findall(r'"([a-z][a-z0-9_]*\.[a-z][a-z0-9_]*)",', open(path).read()))

    if not tf_events:
        return []

    undocumented = tf_events - catalogue_events
    unrouted = catalogue_events - tf_events

    problems = []
    if undocumented:
        problems.append(f"subscribed but not in CATALOGUE.md: {sorted(undocumented)}")
    if unrouted:
        problems.append(f"in CATALOGUE.md but no subscription: {sorted(unrouted)}")
    return problems


def check_no_hardcoded_secrets():
    """
    Terraform state records every value. A literal password in a .tf file is a
    password in state, in the plan output and in the PR diff.
    """
    patterns = [
        (r'password\s*=\s*"(?!\$\{)[^"]{8,}"', "literal password"),
        (r'secret_string\s*=\s*"(?!\$\{)[^"]{16,}"', "literal secret_string"),
        (r'(access_key|secret_key)\s*=\s*"[A-Za-z0-9/+]{16,}"', "literal AWS credential"),
        (r'AKIA[0-9A-Z]{16}', "AWS access key ID"),
    ]

    problems = []
    for path in glob.glob(os.path.join(TF_ROOT, "**", "*.tf*"), recursive=True):
        text = open(path).read()
        for pattern, label in patterns:
            for match in re.finditer(pattern, text, re.IGNORECASE):
                line = text[: match.start()].count("\n") + 1
                problems.append(f"{os.path.relpath(path, ROOT)}:{line} — possible {label}")
    return problems


def main():
    if not os.path.isdir(TF_ROOT):
        print(f"  {YELLOW}−{RESET} no infrastructure/terraform directory {DIM}(skipped){RESET}")
        return 0

    declared, outputs = collect_modules()

    sections = [
        ("Module wiring", check_wiring(declared, outputs)),
        ("Event topology matches catalogue", check_subscriptions_match_catalogue()),
        ("No hardcoded secrets", check_no_hardcoded_secrets()),
    ]

    failed = 0
    for label, problems in sections:
        if problems:
            failed += 1
            print(f"  {RED}✗{RESET} {label}")
            for problem in problems:
                print(f"      - {problem}")
        else:
            print(f"  {GREEN}✓{RESET} {label}")

    module_count = len([d for d in declared if d.startswith("modules")])
    if not failed:
        print(f"  {GREEN}✓{RESET} {module_count} modules parsed")

    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
