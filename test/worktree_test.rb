# frozen_string_literal: true
#
# worktrees: restacking a branch another worktree has checked out, and skipping
# one whose worktree cannot take a rebase.
# See test/support/helper.rb for how the harness works and how to regenerate the snapshot.
#
# Each worktree sits beside the scenario's repo, so it prints as `<repo>-wt`.

require_relative "support/helper"

def wt
  "#{$repo}-wt"
end

# Run a shell command inside the worktree, discarding output. The subshell keeps
# `setup`'s trailing `>/dev/null` off the command's own redirect.
def in_wt(cmd)
  setup("(cd #{wt} && #{cmd})")
end

section "restack rebases a branch checked out in another worktree, from there"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
gsq("create feat-c"); commit("c.txt", "c1")
setup("git checkout -q feat-a"); commit("a2.txt", "a2")
setup("git worktree add -q #{wt} feat-b")
run("restack")
show("feat-b behind feat-a", "git rev-list --count feat-b..feat-a")
show("feat-c behind feat-b", "git rev-list --count feat-c..feat-b")
show("worktree HEAD", "git -C #{wt} branch --show-current")
show("worktree status", "git -C #{wt} status --porcelain | wc -l | tr -d ' '")
show("HEAD", "git branch --show-current")

section "restack fast-forwards a branch with no commits in another worktree"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b")
setup("git checkout -q feat-a"); commit("a2.txt", "a2")
setup("git worktree add -q #{wt} feat-b")
run("restack")
show("feat-b == feat-a", 'test "$(git rev-parse feat-b)" = "$(git rev-parse feat-a)" && echo yes || echo no')
show("worktree file a2.txt", "cat #{wt}/a2.txt")

section "restack skips a branch whose worktree is dirty, with its descendants"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
gsq("create feat-c"); commit("c.txt", "c1")
setup("git checkout -q feat-a")
gsq("create feat-x"); commit("x.txt", "x1")
setup("git checkout -q feat-a"); commit("a2.txt", "a2")
setup("git worktree add -q #{wt} feat-b")
in_wt("echo dirty > b.txt")
run("restack")
show("feat-b behind feat-a", "git rev-list --count feat-b..feat-a")
show("feat-c behind feat-a", "git rev-list --count feat-c..feat-a")
# A sibling outside the skipped subtree is still restacked.
show("feat-x behind feat-a", "git rev-list --count feat-x..feat-a")
show("worktree change kept", "cat #{wt}/b.txt")
show("HEAD", "git branch --show-current")

section "an untracked file does not make a worktree dirty"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
setup("git checkout -q feat-a"); commit("a2.txt", "a2")
setup("git worktree add -q #{wt} feat-b")
in_wt("echo scratch > notes.txt")
run("restack")
show("feat-b behind feat-a", "git rev-list --count feat-b..feat-a")

section "a dirty worktree is no reason to skip a branch with nothing to move"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
setup("git checkout -q feat-a")
setup("git worktree add -q #{wt} feat-b")
in_wt("echo dirty > b.txt")
run("restack")

section "restack skips a branch whose worktree is mid-rebase (listed as detached)"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
setup("git checkout -q -b other main"); commit("b.txt", "other")
setup("git checkout -q feat-a"); commit("a2.txt", "a2")
setup("git worktree add -q #{wt} feat-b")
in_wt("git rebase other")
show("worktree listed as", "git worktree list --porcelain | grep -c detached")
run("restack")
show("worktree still rebasing", "git -C #{wt} status | grep -c 'rebase in progress'")

section "restack skips a branch whose worktree directory is gone"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
setup("git checkout -q feat-a"); commit("a2.txt", "a2")
setup("git worktree add -q #{wt} feat-b")
setup("rm -rf #{wt}")
run("restack")

section "a conflict in another worktree is aborted there, with a cd to resolve it"
new_repo
gsq("create feat-a")
setup("echo from-a > shared.txt && git add shared.txt && git commit -qm a-shared")
gsq("create feat-b")
setup("echo from-b > shared.txt && git add shared.txt && git commit -qm b-shared")
setup("git checkout -q feat-a")
setup("echo changed-a > shared.txt && git add shared.txt && git commit -qm a-conflict")
setup("git worktree add -q #{wt} feat-b")
run("restack")
show("worktree still rebasing", "git -C #{wt} status | grep -c 'rebase in progress' || true")
show("worktree HEAD", "git -C #{wt} branch --show-current")
show("HEAD", "git branch --show-current")

section "sync heals an orphan checked out in another worktree"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
# feat-a squash-merged into main and deleted
setup("git checkout -q main && echo a1 > a.txt && git add a.txt && git commit -qm squash-a")
setup("git branch -D feat-a")
setup("git worktree add -q #{wt} feat-b")
run("sync")
show("feat-b parent", "git config --get branch.feat-b.stackParent")
show("feat-b commits above main", "git rev-list --count main..feat-b")
show("worktree HEAD", "git -C #{wt} branch --show-current")

section "drop restacks a child checked out in another worktree"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
setup("git checkout -q main"); commit("m.txt", "m1")
setup("git worktree add -q #{wt} feat-b")
run("drop feat-a")
show("feat-b parent", "git config --get branch.feat-b.stackParent")
show("feat-b behind main", "git rev-list --count feat-b..main")
show("HEAD", "git branch --show-current")

section "drop still splices when a moved child is skipped, then reports it"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
setup("git checkout -q main"); commit("m.txt", "m1")
setup("git worktree add -q #{wt} feat-b")
in_wt("echo dirty > b.txt")
run("drop --delete feat-a")
show("feat-b parent", "git config --get branch.feat-b.stackParent")
show("feat-a exists", "git show-ref --verify --quiet refs/heads/feat-a && echo yes || echo no")
