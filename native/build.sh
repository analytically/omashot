#!/usr/bin/env bash
# Build the native clipboard helper and put it where the plugin looks for it.
#
#   native/build.sh          # or: make native
#
# A Rust toolchain (cargo) is the only build requirement; the crate pulls
# wayland-client and wayland-protocols-wlr from crates.io. Without the binary
# the plugin still copies, through wl-copy, which can only offer one
# representation at a time (the image, not the path).
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CRATE="$ROOT/native/snapmenu-clipboard"
TARGET="$ROOT/bin/snapmenu-clipboard"

if ! command -v cargo >/dev/null 2>&1; then
  printf 'cargo is not installed: skipping the native helper\n' >&2
  printf 'the plugin falls back to wl-copy (image only) without it\n' >&2
  exit 0
fi

if [[ ! -f $CRATE/Cargo.toml ]]; then
  printf 'no crate at %s\n' "$CRATE" >&2
  exit 1
fi

# Build into a temporary directory and replace the binary, so a running helper
# (which may still own the clipboard) is never overwritten in place.
staged=$(mktemp -d)
trap 'rm -rf "$staged"' EXIT
cargo build --release --manifest-path "$CRATE/Cargo.toml" --target-dir "$staged/target" >/dev/null
install -m 0755 "$staged/target/release/snapmenu-clipboard" "$TARGET"
printf 'built %s\n' "$TARGET"
