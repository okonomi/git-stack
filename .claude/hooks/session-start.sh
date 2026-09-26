#!/bin/bash
#
# SessionStart hook: install Spinel under ~/.local so `spin build` / `spin test`
# work in Claude Code on the web. Spinel is not packaged, so it is built from
# source; the container is cached after the hook, so only the first session pays
# for the build.
set -euo pipefail

# Local sessions bring their own toolchain.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

# Must match SPINEL_REF in .github/workflows/ci.yml, which greps for this exact
# `${SPINEL_REF:-<sha>}` form -- keep the shape when bumping.
SPINEL_REF="${SPINEL_REF:-a3be2abdc09c3d5fa7094948baa7ce4d40dbb397}"
SPINEL_REPO="${SPINEL_REPO:-https://github.com/matz/spinel.git}"

PREFIX="$HOME/.local"
SRC_DIR="${SPINEL_SRC:-$HOME/.local/share/spinel-src}"
SPIN_BIN="$PREFIX/bin/spin"
STAMP="$PREFIX/lib/spinel/.installed-ref"

# CLAUDE_ENV_FILE carries PATH into the session's later commands.
echo "export PATH=\"$PREFIX/bin:\$PATH\"" >> "$CLAUDE_ENV_FILE"
export PATH="$PREFIX/bin:$PATH"

if [ -x "$SPIN_BIN" ] && [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$SPINEL_REF" ]; then
  echo "spin already installed ($SPINEL_REF); skipping build."
  exit 0
fi

echo "Building Spinel @ $SPINEL_REF ..."

if [ ! -d "$SRC_DIR/.git" ]; then
  rm -rf "$SRC_DIR"
  mkdir -p "$SRC_DIR"
  git init -q "$SRC_DIR"
  git -C "$SRC_DIR" remote add origin "$SPINEL_REPO"
fi
git -C "$SRC_DIR" fetch -q --depth 1 origin "$SPINEL_REF"
git -C "$SRC_DIR" checkout -q FETCH_HEAD

make -C "$SRC_DIR" deps
make -C "$SRC_DIR"
make -C "$SRC_DIR" install PREFIX="$PREFIX"

# Lets a cached container skip the build above.
mkdir -p "$(dirname "$STAMP")"
echo "$SPINEL_REF" > "$STAMP"

echo "spin installed: $("$SPIN_BIN" --version 2>/dev/null || echo unknown)"
