#!/usr/bin/env bash
#
# Runtime snapshot test for the COMPILED git-stack binary.
#
# `spin test` compiles the test harness, but the harness still runs
# `ruby bin/git-stack.rb`, so the shipped binary is never executed there. A method
# the Spinel runtime cannot dispatch compiles, passes both snapshots, and dies
# only on the real binary -- which is what this script runs. It adds to
# test/*_test.rb rather than replacing it.
#
# The multi-sibling fixture reaches the `.sort` calls in
# `StackTopology#children_of` / `#walk_order`, which Spinel dispatches only on a
# concrete `Array[String]`. The chunked-scan fixture further down is the only one
# reaching a second ahead/behind batch, where a widened `each_slice` receiver once
# segfaulted `tree`.
#
# Not covered: `version`, whose output stamps the build's Spinel ref.
#
#     spin build
#     test/binary_test.sh | diff -u test/binary_test.sh.expected -   # check
#     test/binary_test.sh > test/binary_test.sh.expected             # regen
#
# GIT_STACK overrides the binary (default: build/bin/git-stack). Needs only a
# POSIX-ish shell and git.

set -u

root="$(cd "$(dirname "$0")/.." && pwd)"
GIT_STACK="${GIT_STACK:-$root/build/bin/git-stack}"

repo=""
# $repo as git reports it, symlinks resolved; `run` prints it as <repo>.
real=""

section() { printf '\n### %s\n' "$1"; }

# git-stack, run inside the fixture with colour disabled, transcript recorded.
run() {
  printf '$ git stack %s\n' "$*"
  local out rc
  out="$(cd "$repo" && NO_COLOR=1 "$GIT_STACK" "$@" 2>&1)"
  rc=$?
  [ -n "$out" ] && printf '%s\n' "$out" | sed "s|$real|<repo>|g"
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
  real="$(cd "$repo" && pwd -P)"
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

# `children_of` builds the trunk's list at run time (`select`/`concat`), and
# `cmd_up` reads it with `include?` / `length` / `[0]` -- a shape only the
# shipped binary can prove. Ambiguous on purpose: what matters is that
# `feat-x-child`, the orphan `tree` just drew, is offered at all.
section "up from the trunk offers the orphan's root alongside feat-a (issue #85)"
run up

section "parent reports the recorded parent"
git_q checkout -q feat-b
run parent

# Failing commands, for the exit STATUS: scripts read it, and a Spinel codegen
# bug once let `would_cycle?`'s `return` out of `loop` corrupt a later `exit`,
# so a rejected cycle exited 0. CRuby cannot see that. Every rejection dies
# before writing, so the fixture carries on unchanged.
section "parent/track reject a cycle, a self-parent, and a missing branch"
run parent feat-b1        # downstream of feat-b -> cycle
run track feat-b1         # same cycle, reached through track
run parent feat-b
run parent no-such-branch

# `cmd_up`'s only bare `exit 1` outside `die`, straight after a block -- the
# shape of the codegen bug above.
section "up with multiple children exits non-zero"
git_q checkout -q feat-a
run up

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

# The other readers of that run-time list: `[0]` (a lone child is checked out
# without a menu) and `include?` (`up <name>`).
section "up <name> and a lone child both index the run-time-built list (issue #85)"
new_repo
gsq create base-a; commit a.txt a1
gsq create base-b; commit b.txt b1
git_q checkout -q base-a
gsq untrack
git_q checkout -q main
# main's only candidate is base-b, a detached root, so `up` takes children[0].
run up
show "HEAD after the lone child's [0] checkout" "branch --show-current"
git_q checkout -q main
gsq create trunk-child; commit tc.txt tc1
git_q checkout -q main
# Two candidates now; naming one goes through include?.
run up base-b
show "HEAD after the named include? checkout" "branch --show-current"

# stackBase end to end on the compiled binary: a plain rebase would re-apply
# feature-a's squashed commits and conflict. Two commits, because a one-commit
# squash matches its patch-id and a plain rebase would drop it too.
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

# The two scans that grow with the repo, past 4 KB. A Spinel backtick once kept
# only the first ~4 KB without error, so every branch past the cut read as
# deleted: `tree` drew live parents as missing, and `sync` reparented healthy
# branches onto trunk. CRuby never truncated, so only this test can catch a
# compiler that brings the cap back.
#
# The padding is long-named and tracked so both scans overflow, and the stack
# under test sorts last (`zzz-`), since truncation drops the tail.
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

# Big enough to matter, without pinning a byte count a rename would break.
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

# Nested under the trunk, no "parent missing", no duplicate rows. The count is
# separate because a grep transcript alone would not pin the duplication down.
run_grep zzz tree
printf 'zzz rows in tree (expect 2): %s\n' \
  "$(cd "$repo" && NO_COLOR=1 "$GIT_STACK" tree 2>&1 | grep -c zzz)"

# Under truncation, sync "healed" zzz-stack-top onto main.
git_q checkout -q zzz-stack-top
run sync
show "zzz-stack-top parent after sync" "config --get branch.zzz-stack-top.stackParent"
show "zzz-stack-bottom parent after sync" "config --get branch.zzz-stack-bottom.stackParent"

# Only the branch list overflows here; the config dump stays small and accurate.
# The stack then reads as tracked but orphaned -- the shape where `sync`
# destroys the recorded parent.
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

# More branches than one AHEAD_BEHIND_CHUNK, so `tree` reads a second batch whose
# first rows rest on parents from the first. Each branch is one commit above its
# parent, so reading any other parent's column shows as a count other than 1.
# Built with plumbing: 130 `create`s would dominate the script's run time.
section "tree reads ahead/behind across batches of the chunked scan"
new_repo
parent=main
i=1
while [ "$i" -le 130 ]; do
  name="$(printf 'chain-%03d' "$i")"
  sha="$(git -C "$repo" commit-tree -p "$parent" -m "$name" "$parent^{tree}")"
  git_q update-ref "refs/heads/$name" "$sha"
  git_q config "branch.$name.stackParent" "$parent"
  parent="$name"
  i=$((i + 1))
done

chain_rows() { # chain_rows <grep pattern>
  (cd "$repo" && NO_COLOR=1 "$GIT_STACK" tree 2>&1) | grep chain- | grep -c -- "$1"
}
printf 'chain rows in tree (expect 130): %s\n' "$(chain_rows .)"
printf 'chain rows at exactly 1 commit (expect 130): %s\n' "$(chain_rows '(1 commit(s))$')"

# `plant` hands `set_trunks` a run-time concatenation and `fell` a `reject`
# result, array shapes only the shipped binary can prove. The last `fell`
# empties the list, covering the path that unsets the key.
section "plant and fell edit the trunk list on the compiled binary"
new_repo
git_q branch develop
git_q branch release
run init main
run plant develop
run plant release
# `show` strips newlines, so the names run together, in config order.
show "stack.trunk (run together)" "config --get-all stack.trunk"
run fell develop
show "stack.trunk after fell (run together)" "config --get-all stack.trunk"
run plant develop
run fell main release develop
show "stack.trunk (unset)" "config --get-all stack.trunk"

# `sleep` between config-lock retries, compiled.
section "a config lock released during the retries is waited out"
new_repo
gsq init
: > "$repo/.git/config.lock"
(sleep 0.3; rm -f "$repo/.git/config.lock") &
run create feat-a
wait
show "feat-a parent" "config --get branch.feat-a.stackParent"
