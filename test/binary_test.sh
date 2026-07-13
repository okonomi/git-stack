#!/usr/bin/env bash
#
# Runtime snapshot test for the *compiled* git-stack binary.
#
# `spin test` compiles test/cli_test.rb, but that harness still shells out to
# `ruby bin/git-stack.rb` -- so the command under test runs under CRuby, and
# the native binary that actually ships is never executed. Any method the
# Spinel runtime does not support (e.g. `Array#sort`) compiles and passes the
# CRuby snapshot, then dies with NoMethodError only on the real binary.
#
# This script closes that gap: it builds ONE known-shape fixture repository
# (trunk / nested branches / multiple siblings / an orphan whose parent was
# merged and deleted) and drives the compiled binary over it, printing a
# transcript of each command's combined stdout+stderr and exit status. CI
# diffs that transcript against test/binary_test.sh.expected; any change -- a
# different message, a new line, a NoMethodError, a changed exit code -- fails.
#
# The `tree` command is exercised against the multiple-sibling stack on
# purpose: sibling ordering is the only path that reaches the `.sort` calls in
# `StackContext#children_of` and `#walk_order`, which is exactly where an
# unsupported runtime method would hide. Those `.sort`s are also load-bearing
# for type inference -- Spinel only dispatches `sort` on a concrete
# `Array[String]`, never on a poly array -- so this fixture doubles as the
# runtime proof that the element type stayed narrow.
#
# This is the binary counterpart to test/cli_test.rb's CRuby snapshot; it adds
# a check, it does not replace one. It does NOT cover `version`, whose output
# deliberately differs on the binary (it stamps the build's Spinel ref, which
# is not deterministic across builds).
#
# Point GIT_STACK at the binary to test (default: build/bin/git-stack next to
# this checkout). Build it first, then run or regenerate the snapshot:
#
#     spin build
#     test/binary_test.sh | diff -u test/binary_test.sh.expected -   # check
#     test/binary_test.sh > test/binary_test.sh.expected             # regen
#
# It only reads the finished binary, so it runs under any POSIX-ish shell with
# git on PATH -- no Ruby, no Spinel toolchain.

set -u

root="$(cd "$(dirname "$0")/.." && pwd)"
GIT_STACK="${GIT_STACK:-$root/build/bin/git-stack}"

repo=""

section() { printf '\n### %s\n' "$1"; }

# git-stack, run inside the fixture with colour disabled, transcript recorded.
run() {
  printf '$ git stack %s\n' "$*"
  local out rc
  out="$(cd "$repo" && NO_COLOR=1 "$GIT_STACK" "$@" 2>&1)"
  rc=$?
  [ -n "$out" ] && printf '%s\n' "$out"
  printf '[exit %d]\n' "$rc"
}

# git-stack, run quietly to build up state a later command reveals.
gsq() { (cd "$repo" && NO_COLOR=1 "$GIT_STACK" "$@") >/dev/null 2>&1; }

# Deterministic repository state, one labelled line.
# $2 is an unquoted git subcommand, split into words on purpose.
# shellcheck disable=SC2086
show() { printf '%s: %s\n' "$1" "$(git -C "$repo" ${2} 2>/dev/null | tr -d '\n')"; }

git_q() { git -C "$repo" "$@" >/dev/null 2>&1; }

commit() { # commit <file> <message>
  printf '%s\n' "$2" > "$repo/$1"
  git_q add "$1"
  git_q commit -qm "$2"
}

new_repo() {
  repo="$(mktemp -d)"
  git_q init -q -b main
  git_q config user.email test@example.com
  git_q config user.name Test
  git_q config commit.gpgsign false
  commit file.txt base
}

# --- fixture ----------------------------------------------------------------
#
# Known shape, built once and reused across the transcript:
#
#   main (trunk)
#     feat-a
#       feat-b            \ two siblings on feat-a -> reaches the sibling `.sort`
#         feat-b1         / nested one level deeper
#       feat-c
#     feat-x-child        (orphan: parent feat-x was merged into main + deleted)

new_repo

gsq create feat-a;  commit a.txt  a1
gsq create feat-b;  commit b.txt  b1
gsq create feat-b1; commit b1.txt b1a
git_q checkout -q feat-a
gsq create feat-c;  commit c.txt  c1

# Orphan chain: feat-x-child stacked on feat-x, then feat-x merged + deleted.
git_q checkout -q main
gsq create feat-x;       commit x.txt  x1
gsq create feat-x-child; commit xc.txt xc1
git_q checkout -q main
git_q merge -q --no-edit feat-x
git_q branch -d feat-x

# --- transcript -------------------------------------------------------------

section "tree renders siblings, nesting, and the orphan"
run tree

section "parent reports the recorded parent"
git_q checkout -q feat-b
run parent

section "restack replays the sibling subtrees onto an advanced parent"
git_q checkout -q feat-a
commit a2.txt a2            # advance feat-a, leaving feat-b/feat-b1/feat-c behind
git_q checkout -q feat-b
run tree                    # everything on feat-a now shows "needs restack"
run restack
run tree                    # ... and is caught back up afterwards

section "sync heals the orphan onto the trunk"
git_q checkout -q feat-x-child
run sync
run tree
show "feat-x-child parent" "config --get branch.feat-x-child.stackParent"

# Squash-merge recovery on the SHIPPED binary. `restack`'s `git rebase --onto
# <parent> <stackBase>` is what makes this work; a plain rebase would re-apply
# feature-a's two now-squashed commits and conflict. This is the one path that
# exercises stackBase end-to-end on the compiled artifact, so it lives here too
# and not only in the CRuby snapshot. A fresh repo keeps it independent of the
# shared fixture above; feature-a gets TWO commits so the squash matches neither
# original patch-id (a single-commit squash would be dropped even by a plain
# rebase, hiding the bug).
section "sync recovers a branch whose parent was squash-merged and deleted"
new_repo
gsq create feature-a; commit a.txt a1
commit a.txt a2
gsq create feature-b; commit b.txt b1
git_q checkout -q main
git_q merge --squash feature-a
git_q commit -qm squash-feature-a
git_q branch -D feature-a
git_q checkout -q feature-b
run sync
show "feature-b parent"          "config --get branch.feature-b.stackParent"
show "feature-b behind main"     "rev-list --count feature-b..main"
show "feature-b commits above main" "rev-list --count main..feature-b"
if [ "$(git -C "$repo" config --get branch.feature-b.stackBase)" \
   = "$(git -C "$repo" rev-parse main)" ]; then
  printf 'feature-b stackBase == main tip: yes\n'
else
  printf 'feature-b stackBase == main tip: no\n'
fi
