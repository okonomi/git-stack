#!/bin/bash
#
# SessionStart hook: build & install Spinel (the `spin` tool) so that
# `spin build` / `spin test` work in Claude Code on the web sessions.
#
# Spinel is Matz's AOT Ruby compiler; it is not distributed as a package, so
# we build it from source and install it under ~/.local. The container state
# is cached after the hook completes, so this only pays the full build cost on
# the first (uncached) session; later sessions find it already installed and
# return immediately.
set -euo pipefail

# Only run in the remote (Claude Code on the web) environment; locally you
# presumably already have your own toolchain.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

# Pin the Spinel revision we validated the test suite against. Override with
# SPINEL_REF to track a different commit/branch/tag.
SPINEL_REF="${SPINEL_REF:-0ee18cfc7496d1c50cb5399919544d174ab38572}"
SPINEL_REPO="${SPINEL_REPO:-https://github.com/matz/spinel.git}"

PREFIX="$HOME/.local"
SRC_DIR="${SPINEL_SRC:-$HOME/.local/share/spinel-src}"
SPIN_BIN="$PREFIX/bin/spin"
STAMP="$PREFIX/lib/spinel/.installed-ref"

# Make the freshly built tool visible to this session (idempotent append).
echo "export PATH=\"$PREFIX/bin:\$PATH\"" >> "$CLAUDE_ENV_FILE"
export PATH="$PREFIX/bin:$PATH"

# Already installed at the pinned ref? Nothing to do.
if [ -x "$SPIN_BIN" ] && [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$SPINEL_REF" ]; then
  echo "spin already installed ($SPINEL_REF); skipping build."
  exit 0
fi

echo "Building Spinel @ $SPINEL_REF ..."

# Fetch the source at the pinned revision (shallow).
if [ ! -d "$SRC_DIR/.git" ]; then
  rm -rf "$SRC_DIR"
  mkdir -p "$SRC_DIR"
  git init -q "$SRC_DIR"
  git -C "$SRC_DIR" remote add origin "$SPINEL_REPO"
fi
git -C "$SRC_DIR" fetch -q --depth 1 origin "$SPINEL_REF"
git -C "$SRC_DIR" checkout -q FETCH_HEAD

# Build the compiler + spin tool, then install under ~/.local.
make -C "$SRC_DIR" deps
make -C "$SRC_DIR"
make -C "$SRC_DIR" install PREFIX="$PREFIX"

# Record the installed revision so future sessions can skip the rebuild.
mkdir -p "$(dirname "$STAMP")"
echo "$SPINEL_REF" > "$STAMP"

echo "spin installed: $("$SPIN_BIN" --version 2>/dev/null || echo unknown)"
