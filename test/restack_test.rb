# frozen_string_literal: true
#
# restack: replaying descendants onto an updated parent, and what it declines to touch.
# See test/support/helper.rb for how the harness works and how to regenerate the snapshot.

require_relative "support/helper"

# restack's choice of root against an untracked parent is covered in
# sync_test.rb's "restack and sync name the same root tree draws, with an
# untracked parent" section, alongside sync's -- not here.

section "restack replays descendants onto the updated parent"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
# add a new commit on feat-a, leaving feat-b behind
setup("git checkout -q feat-a")
commit("a2.txt", "a2")
setup("git checkout -q feat-b")
run("restack")
show("feat-b behind feat-a", "git rev-list --count feat-b..feat-a")
puts "feat-b contains a2: #{`cd #{$repo} && git log --oneline feat-b | grep -c ' a2$' || true`.strip}"
show("HEAD", "git branch --show-current")

section "restack aborts cleanly on a conflict"
new_repo
gsq("create feat-a")
setup("echo from-a > shared.txt && git add shared.txt && git commit -qm a-shared")
gsq("create feat-b")
setup("echo from-b > shared.txt && git add shared.txt && git commit -qm b-shared")
# create a conflicting change on feat-a
setup("git checkout -q feat-a")
setup("echo changed-a > shared.txt && git add shared.txt && git commit -qm a-conflict")
setup("git checkout -q feat-b")
run("restack")
puts "rebase in progress: #{`cd #{$repo} && git status | grep -c 'rebase in progress' || true`.strip}"

section "restack leaves an untracked branch alone"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
gsq("untrack") # feat-a is current; drop its parent
run("restack") # must NOT rebase feat-a onto the trunk
show("HEAD", "git branch --show-current")

# A branch that predates stackBase (its config has stackParent but no stackBase)
# must still restack correctly: `restack` falls back to the live merge-base of
# the branch and its parent, then re-records the base.
section "restack falls back to merge-base when stackBase is unrecorded"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
setup("git config --unset branch.feat-b.stackBase") # simulate a pre-stackBase branch
# advance feat-a so feat-b falls behind and a real restack happens
setup("git checkout -q feat-a"); commit("a2.txt", "a2")
setup("git checkout -q feat-b")
run("restack")
show("feat-b behind feat-a", "git rev-list --count feat-b..feat-a")
show("feat-b commits above feat-a", "git rev-list --count feat-a..feat-b")
puts "feat-b contains a2: #{`cd #{$repo} && git log --oneline feat-b | grep -c ' a2$' || true`.strip}"
puts "feat-b contains b1: #{`cd #{$repo} && git log --oneline feat-b | grep -c ' b1$' || true`.strip}"
show("feat-b stackBase == feat-a tip (re-recorded)",
     'test "$(git config --get branch.feat-b.stackBase)" = "$(git rev-parse feat-a)" && echo yes || echo no')
