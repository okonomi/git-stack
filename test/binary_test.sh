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

# git-stack, transcript filtered to the lines containing $1. For the large-repo
# fixture, whose padding rows would otherwise bury the handful that matter.
run_grep() {
  local pat="$1"
  shift
  printf '$ git stack %s | grep %s\n' "$*" "$pat"
  local out rc
  out="$(cd "$repo" && NO_COLOR=1 "$GIT_STACK" "$@" 2>&1)"
  rc=$?
  printf '%s\n' "$out" | grep -- "$pat"
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

# Both scans that grow with the repository -- the local branch list and the
# stack-config dump -- are read through `git_out_full` rather than a backtick,
# because a Spinel-compiled binary's backtick keeps only the first ~4 KB and
# drops the rest with no error. Past that cut every branch answered "does not
# exist": `tree` printed live parents as missing AND duplicated their rows (a
# branch became an orphan root as well as a real child), and `sync` -- which
# that very output tells the user to run -- then reparented those healthy
# branches onto trunk, silently destroying the recorded stack.
#
# This is invisible to test/cli_test.rb: CRuby's backticks do not truncate, so
# only the compiled binary can show it. The padding branches are long-named and
# tracked so BOTH captures blow past 4 KB, and the stack under test is named
# `zzz-` so it sorts entirely beyond the cut -- `for-each-ref` emits refnames in
# sorted order, so truncation always drops the alphabetically last branches.
section "a stack past the 4 KB scan boundary renders and syncs intact"
new_repo
pad="aaa-padding-branch-with-a-deliberately-long-name-to-fill-the-scan-buffer"
i=0
while [ "$i" -lt 70 ]; do
  git_q branch "$pad-$i"
  git_q config "branch.$pad-$i.stackParent" main
  i=$((i + 1))
done
git_q branch zzz-stack-bottom
git_q config branch.zzz-stack-bottom.stackParent main
git_q branch zzz-stack-top
git_q config branch.zzz-stack-top.stackParent zzz-stack-bottom

# Assert the fixture is actually big enough to matter, without baking in an
# exact byte count that a rename would invalidate.
over_cap() { # over_cap <label> <bytes>
  if [ "$2" -gt 4095 ]; then
    printf '%s exceeds the 4 KB backtick cap: yes\n' "$1"
  else
    printf '%s exceeds the 4 KB backtick cap: NO (%s bytes)\n' "$1" "$2"
  fi
}
over_cap "branch-list scan" \
  "$(git -C "$repo" for-each-ref --format='%(refname:short)' refs/heads/ | wc -c | tr -d ' ')"
over_cap "stack-config scan" \
  "$(git -C "$repo" config --get-regexp '^branch\..*\.stackparent$' | wc -c | tr -d ' ')"

# The stack must render nested under the trunk, with no "parent missing" and no
# duplicated rows. The count is asserted separately: duplication was the loudest
# symptom, and a grep transcript alone would not pin it down.
run_grep zzz tree
printf 'zzz rows in tree (expect 2): %s\n' \
  "$(cd "$repo" && NO_COLOR=1 "$GIT_STACK" tree 2>&1 | grep -c zzz)"

# sync must leave the recorded shape alone. Under truncation it "healed"
# zzz-stack-top onto main, discarding its real parent.
git_q checkout -q zzz-stack-top
run sync
show "zzz-stack-top parent after sync" "config --get branch.zzz-stack-top.stackParent"
show "zzz-stack-bottom parent after sync" "config --get branch.zzz-stack-bottom.stackParent"

# The same cap, reached through the branch list ALONE. Above, the config dump
# overflowed too, so the stack read as merely untracked and `sync` left it be.
# Here the padding branches are NOT tracked: the config dump stays small and
# accurate while the branch list still overflows, so the stack is read as
# tracked-but-orphaned -- its live parent "does not exist". That is the
# data-losing shape: `sync` heals the orphan onto trunk and the recorded parent
# is gone for good.
section "an orphan-looking stack past the branch-list cap is not 'healed' away"
new_repo
i=0
while [ "$i" -lt 70 ]; do
  git_q branch "$pad-$i"
  i=$((i + 1))
done
git_q branch zzz-stack-bottom
git_q config branch.zzz-stack-bottom.stackParent main
git_q branch zzz-stack-top
git_q config branch.zzz-stack-top.stackParent zzz-stack-bottom

over_cap "branch-list scan" \
  "$(git -C "$repo" for-each-ref --format='%(refname:short)' refs/heads/ | wc -c | tr -d ' ')"
show "stack-config scan (small and accurate here)" \
  "config --get-regexp ^branch\..*\.stackparent$"

run_grep zzz tree
printf 'zzz rows in tree (expect 2): %s\n' \
  "$(cd "$repo" && NO_COLOR=1 "$GIT_STACK" tree 2>&1 | grep -c zzz)"

git_q checkout -q zzz-stack-top
run sync
show "zzz-stack-top parent after sync" "config --get branch.zzz-stack-top.stackParent"
