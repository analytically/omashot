#!/usr/bin/env bash
# Copy the working tree into the installed plugin directory and restart the
# shell.
#
#   tests/deploy.sh          # or: make deploy
#
# The restart is not optional: the running shell caches the *compiled* QML for a
# URL it has already loaded, so saving files into the plugin directory alone
# keeps the old build alive (see "Developing" in the README).

set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PLUGIN_ID=$(jq -r '.id' "$ROOT/manifest.json")
TARGET="${SNAPMENU_PLUGIN_DIR:-$HOME/.config/omarchy/plugins/$PLUGIN_ID}"

if [[ ! -d $TARGET ]]; then
  printf 'not installed: %s\n' "$TARGET" >&2
  printf 'install it first: omarchy plugin add file://%s --yes\n' "$ROOT" >&2
  exit 1
fi

# The native clipboard helper is build output, not a source file: build it here
# so the plugin never runs without it silently (it falls back to wl-copy, which
# can only carry one representation).
"$ROOT/native/build.sh" || true

if command -v rsync >/dev/null 2>&1; then
  rsync -a --delete \
    --exclude .git --exclude .github --exclude 'tests/manual' --exclude 'native' \
    "$ROOT"/ "$TARGET"/
else
  rm -rf "${TARGET:?}"/bin
  cp -a "$ROOT"/. "$TARGET"/
  rm -rf "$TARGET"/.git
fi

printf 'deployed %s -> %s\n' "$PLUGIN_ID" "$TARGET"

if command -v omarchy >/dev/null 2>&1; then
  omarchy restart shell
  printf 'shell restarted\n'
else
  printf 'omarchy not on PATH: restart the shell yourself (omarchy restart shell)\n' >&2
fi
