# frozen_string_literal: true
#
# sync: healing orphans, fast-forwarding merged branches, and clamping a stale base.
# See test/support/helper.rb for how the harness works and how to regenerate the snapshot.

require_relative "support/helper"

# One section on purpose: the bug was `tree`, `restack` and `sync` naming
# different roots, which only shows side by side (#80).
section "restack and sync name the same root tree draws, with an untracked parent"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
gsq("create feat-c"); commit("c.txt", "c1")
setup("git checkout -q feat-a")
gsq("untrack")
setup("git checkout -q feat-b")
run("tree")
run("restack")
run("sync")
# feat-b still rests on feat-a, and sync did not "heal" it onto the trunk: an
# untracked parent that still EXISTS is not an orphan.
show("feat-b stackParent after both", "git config --get branch.feat-b.stackParent")
show("feat-c stackParent after both", "git config --get branch.feat-c.stackParent")

section "sync reparents an orphaned branch onto trunk and restacks it"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
# simulate "merge feat-a into main, then delete it"
setup("git checkout -q main")
setup("git merge -q --no-edit feat-a")
setup("git branch -d feat-a")
setup("git checkout -q feat-b")
run("sync")
show("branch.feat-b.stackParent", "git config --get branch.feat-b.stackParent")
show("feat-b behind main", "git rev-list --count feat-b..main")
show("HEAD", "git branch --show-current")

section "sync heals a multi-level orphan chain in one pass"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
gsq("create feat-c"); commit("c.txt", "c1")
# merge and delete both feat-a and feat-b, leaving feat-c's parent chain
# (feat-c -> feat-b -> feat-a -> main) with two missing links
setup("git checkout -q main")
setup("git merge -q --no-edit feat-b") # feat-b already contains feat-a's commit
setup("git branch -d feat-a")
setup("git branch -d feat-b")
setup("git checkout -q feat-c")
run("sync")
show("branch.feat-c.stackParent", "git config --get branch.feat-c.stackParent")
show("feat-c behind main", "git rev-list --count feat-c..main")

section "sync reports a conflict the same way restack does"
new_repo
gsq("create feat-a")
setup("echo from-a > shared.txt && git add shared.txt && git commit -qm a-shared")
gsq("create feat-b")
setup("echo from-b > shared.txt && git add shared.txt && git commit -qm b-shared")
setup("git checkout -q main")
setup("git merge -q --no-edit feat-a")
setup("git branch -d feat-a")
setup("echo changed-a > shared.txt && git add shared.txt && git commit -qm main-conflict")
setup("git checkout -q feat-b")
run("sync")

section "tree shows a branch whose parent was deleted, then sync fixes it"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
setup("git checkout -q main")
setup("git merge -q --no-edit feat-a")
setup("git branch -d feat-a")
setup("git checkout -q feat-b")
run("tree")
gsq("sync")
run("tree")

# `tree` recommends `sync` beside any orphan, from anywhere, so `sync` has to
# heal every orphan from anywhere (#55); side by side for the same reason as
# above. other-b is detached too, but its parent is merely untracked: not an
# orphan, and not touched.
section "sync heals an orphan in another stack when run from the trunk"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
setup("git checkout -q main")
gsq("create other-a"); commit("o.txt", "o1")
gsq("create other-b"); commit("p.txt", "p1")
setup("git checkout -q other-a")
gsq("untrack")
# merge feat-a into main and delete it, as a merged PR would, then run sync from
# the trunk -- not from the orphaned subtree
setup("git checkout -q main")
setup("git merge -q --no-edit feat-a")
setup("git branch -d feat-a")
run("tree")
run("sync")
show("feat-b stackParent", "git config --get branch.feat-b.stackParent")
show("feat-b behind main", "git rev-list --count feat-b..main")
show("other-b stackParent (untouched)", "git config --get branch.other-b.stackParent")
show("HEAD", "git branch --show-current")
run("tree")

# Run from inside an orphaned stack: feat-b roots the first walk, so the sweep
# that heals other-b must not replay it again.
section "sync heals every orphaned stack in one pass, without repeating its own"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
setup("git checkout -q main")
gsq("create other-a"); commit("o.txt", "o1")
gsq("create other-b"); commit("p.txt", "p1")
setup("git checkout -q main")
setup("git merge -q --no-edit feat-a")
setup("git merge -q --no-edit other-a")
setup("git branch -d feat-a")
setup("git branch -d other-a")
setup("git checkout -q feat-b")
run("sync")
show("feat-b stackParent", "git config --get branch.feat-b.stackParent")
show("other-b stackParent", "git config --get branch.other-b.stackParent")
show("HEAD", "git branch --show-current")

# Two commits on feature-a: a one-commit squash matches its patch-id, so even
# a plain rebase would drop it, hiding the bug `--onto` exists for.
section "sync recovers a branch whose parent was squash-merged and deleted"
new_repo
gsq("create feature-a"); commit("a.txt", "a1")
commit("a.txt", "a2") # second commit on feature-a, so the squash differs from any one commit
gsq("create feature-b"); commit("b.txt", "b1")
# squash-merge feature-a into main and delete it (as a squash-merge PR would):
# main gains one combined commit, and feature-a's own commits are gone from any ref.
setup("git checkout -q main")
setup("git merge --squash feature-a >/dev/null 2>&1 && git commit -qm squash-feature-a")
setup("git branch -D feature-a")
setup("git checkout -q feature-b")
run("sync")
show("feature-b stackParent", "git config --get branch.feature-b.stackParent")
show("feature-b behind main", "git rev-list --count feature-b..main")
show("feature-b commits above main", "git rev-list --count main..feature-b")
puts "feature-b contains a1: #{`cd #{$repo} && git log --oneline feature-b | grep -c ' a1$' || true`.strip}"
puts "feature-b contains a2: #{`cd #{$repo} && git log --oneline feature-b | grep -c ' a2$' || true`.strip}"
puts "feature-b contains b1: #{`cd #{$repo} && git log --oneline feature-b | grep -c ' b1$' || true`.strip}"
show("feature-b stackBase == main tip",
     'test "$(git config --get branch.feature-b.stackBase)" = "$(git rev-parse main)" && echo yes || echo no')

# feat-a has commits in `base..branch` but none above its parent, so
# `rebase --onto` would re-apply what the parent already has and conflict.
section "sync fast-forwards a branch fully merged into its parent"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
# Fold feat-a into main (fast-forward), then advance main so feat-a is a strict
# ancestor of main with no commits of its own above it.
setup("git checkout -q main")
setup("git merge -q --ff-only feat-a")
commit("m.txt", "m1")
setup("git checkout -q feat-a")
run("sync")
show("feat-a behind main", "git rev-list --count feat-a..main")
show("feat-a commits above main", "git rev-list --count main..feat-a")
show("feat-a stackBase == main tip",
     'test "$(git config --get branch.feat-a.stackBase)" = "$(git rev-parse main)" && echo yes || echo no')
show("HEAD", "git branch --show-current")

# git-stack re-records the base only when it moves a branch itself, so a manual
# `git rebase` leaves it stale. Replaying from it would re-apply s2 (already in
# feat-a) and conflict with s3; clamped to the merge-base, only b1 is replayed.
section "sync clamps a stale stackBase to the merge-base instead of re-applying parent commits"
new_repo
gsq("create feat-a"); commit("shared.txt", "s1")
gsq("create feat-b"); commit("b.txt", "b1")
# advance feat-a, then move feat-b onto it with a plain git rebase (not git-stack),
# so feat-b now contains s2 but its recorded stackBase is left at the old feat-a tip.
setup("git checkout -q feat-a"); commit("shared.txt", "s2"); commit("a.txt", "a1")
setup("git checkout -q feat-b && git rebase -q feat-a")
# advance feat-a once more with a commit that conflicts with the stale range's s2
setup("git checkout -q feat-a"); commit("shared.txt", "s3")
setup("git checkout -q feat-b")
run("sync")
show("feat-b behind feat-a", "git rev-list --count feat-b..feat-a")
show("feat-b commits above feat-a", "git rev-list --count feat-a..feat-b")
puts "feat-b contains b1: #{`cd #{$repo} && git log --oneline feat-b | grep -c ' b1$' || true`.strip}"
puts "feat-b contains s3: #{`cd #{$repo} && git log --oneline feat-b | grep -c ' s3$' || true`.strip}"
show("feat-b stackBase == feat-a tip (re-anchored)",
     'test "$(git config --get branch.feat-b.stackBase)" = "$(git rev-parse feat-a)" && echo yes || echo no')
