#!/usr/bin/env bash
# One gate for the whole plugin: everything that has to pass before this code
# goes anywhere near a live shell.
#
#   tests/run.sh          # or: make test
#
# Every step is optional in the sense that a missing tool is reported as a skip
# rather than a failure (node, qmllint, shellcheck and omarchy are all provided
# by an Omarchy install, so in practice nothing is skipped).

set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd) || exit 1
cd "$ROOT" || exit 1

PASSED=()
FAILED=()
SKIPPED=()
LOGS=$(mktemp -d)
trap 'rm -rf "$LOGS"' EXIT

step() { # label -- command...
  local label="$1"
  shift 2
  printf '\n== %s\n' "$label"

  local log
  log="$LOGS/$(printf '%s' "$label" | tr -c 'a-zA-Z0-9' '-').log"
  if "$@" >"$log" 2>&1; then
    printf '   ok    %s\n' "$(grep -E 'passed|clean|valid|ok' "$log" | tail -n 1 | cut -c1-96)"
    PASSED+=("$label")
    return 0
  fi

  printf '   FAIL  %s\n' "$label"
  sed -n '1,40p' "$log" | sed 's/^/   | /'
  FAILED+=("$label")
  return 1
}

skip() { # label reason
  printf '\n== %s\n   skip  %s\n' "$1" "$2"
  SKIPPED+=("$1")
}

have() { command -v "$1" >/dev/null 2>&1; }

qmllint_bin() {
  if have qmllint; then
    command -v qmllint
  elif [[ -x /usr/lib/qt6/bin/qmllint ]]; then
    printf '%s' /usr/lib/qt6/bin/qmllint
  fi
}

# ------------------------------------------------------------------- suites

run_model_tests() { node --test tests/; }

run_script_tests() { bash tests/capture.test.sh; }

run_syntax() {
  local file status=0
  for file in bin/*.sh tests/*.sh; do
    bash -n "$file" || status=1
  done
  printf 'bash -n: %d script(s) clean\n' "$(ls bin/*.sh tests/*.sh | wc -l)"
  return $status
}

run_qmllint() {
  local linter file status=0
  linter=$(qmllint_bin)
  for file in *.qml; do
    "$linter" "$file" || status=1
  done
  printf 'qmllint: %d file(s) clean\n' "$(ls ./*.qml | wc -l)"
  return $status
}

run_shellcheck() {
  shellcheck -S warning bin/*.sh tests/*.sh && printf 'shellcheck: clean\n'
}

rust_step() {
  local crate="$ROOT/native/snapmenu-clipboard"
  [[ -f $crate/Cargo.toml ]] || {
    printf 'no crate\n'
    return 0
  }
  cargo fmt --manifest-path "$crate/Cargo.toml" --check || return 1
  cargo build --release --manifest-path "$crate/Cargo.toml" --target-dir "$LOGS/rust-target" >/dev/null
  printf 'cargo build --release: clean\n'
}

run_validate() {
  omarchy plugin validate . && printf 'plugin validate: valid\n'
}

# --------------------------------------------------------------------- main

printf 'snapmenu test gate (%s)\n' "$(pwd)"

step "bash syntax" -- run_syntax
step "capture helper (hermetic)" -- run_script_tests
step "model (node --test)" -- run_model_tests

if have cargo; then
  step "rust clipboard helper" -- rust_step
else
  skip "rust clipboard helper" "cargo not installed"
fi

if have shellcheck; then
  step "shellcheck" -- run_shellcheck
else
  skip "shellcheck" "not installed"
fi

if [[ -n $(qmllint_bin) ]]; then
  step "qmllint" -- run_qmllint
else
  skip "qmllint" "not installed"
fi

if have omarchy; then
  step "omarchy plugin validate" -- run_validate
else
  skip "omarchy plugin validate" "omarchy not on PATH"
fi


printf '\n---------------------------------------------\n'
printf 'passed: %d   failed: %d   skipped: %d\n' \
  "${#PASSED[@]}" "${#FAILED[@]}" "${#SKIPPED[@]}"
if ((${#FAILED[@]} > 0)); then
  printf 'failed steps:\n'
  printf '  - %s\n' "${FAILED[@]}"
  exit 1
fi
printf 'all good\n'
