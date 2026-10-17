# frozen_string_literal: true
#
# anchors and sync: the scope an anchor gives `sync`, and moving the anchor up to
# its trunk afterwards.
# See test/support/helper.rb for how the harness works and how to regenerate the snapshot.
#
# A worktree sits beside the scenario's repo, so it prints as `<repo>-wt`.

require_relative "support/helper"

def wt
  "#{$repo}-wt"
end

# wt-x anchored with two stacks on it (feat-a, fix-c), a plain stack (other) on
# main, and main one commit ahead of all of them.
def anchored_repo
  new_repo
  setup("git branch wt-x")
  gsq("anchor wt-x")
  setup("git checkout -q wt-x")
  gsq("create feat-a"); commit("a.txt", "a1")
  setup("git checkout -q wt-x")
  gsq("create fix-c"); commit("c.txt", "c1")
  setup("git checkout -q main")
  gsq("create other"); commit("o.txt", "o1")
  setup("git checkout -q main"); commit("m.txt", "m2")
end

section "sync from an anchored stack takes every stack on the anchor, and the anchor"
anchored_repo
setup("git checkout -q feat-a")
run("sync")
show("feat-a behind main", "git rev-list --count feat-a..main")
show("fix-c behind main", "git rev-list --count fix-c..main")
show("other behind main (out of scope)", "git rev-list --count other..main")
show("wt-x == main", 'test "$(git rev-parse wt-x)" = "$(git rev-parse main)" && echo yes || echo no')
show("HEAD", "git branch --show-current")

section "sync from the anchor itself fast-forwards it here"
anchored_repo
setup("git checkout -q wt-x")
run("sync")
show("wt-x == main", 'test "$(git rev-parse wt-x)" = "$(git rev-parse main)" && echo yes || echo no')
show("HEAD", "git branch --show-current")
show("file m.txt", "cat m.txt")

section "sync fast-forwards an anchor checked out in another worktree, from there"
anchored_repo
setup("git worktree add -q #{wt} wt-x")
setup("git checkout -q feat-a")
run("sync")
show("wt-x == main", 'test "$(git rev-parse wt-x)" = "$(git rev-parse main)" && echo yes || echo no')
show("worktree file m.txt", "cat #{wt}/m.txt")

section "sync leaves an anchor whose worktree is dirty, and says so"
anchored_repo
setup("git worktree add -q #{wt} wt-x")
setup("(cd #{wt} && echo dirty > file.txt)")
setup("git checkout -q feat-a")
run("sync")
show("wt-x behind main", "git rev-list --count wt-x..main")
show("feat-a behind main", "git rev-list --count feat-a..main")

section "sync leaves an anchor that has commits of its own"
anchored_repo
setup("git checkout -q wt-x"); commit("w.txt", "w1")
setup("git checkout -q feat-a")
run("sync")
show("wt-x behind main", "git rev-list --count wt-x..main")

section "sync in an anchor heals only its own orphans, and --all heals the rest"
new_repo
setup("git branch wt-x")
gsq("anchor wt-x")
setup("git checkout -q wt-x")
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
setup("git checkout -q main")
gsq("create base-p"); commit("p.txt", "p1")
gsq("create top-q"); commit("q.txt", "q1")
setup("git checkout -q main")
setup("git merge -q --no-ff -m merge-a feat-a")
setup("git merge -q --no-ff -m merge-p base-p")
setup("git branch -D feat-a base-p")
setup("git checkout -q wt-x")
run("sync")
show("feat-b parent", "git config --get branch.feat-b.stackParent")
show("feat-b anchor", "git config --get branch.feat-b.stackAnchor")
show("top-q parent (left alone)", "git config --get branch.top-q.stackParent")
run("sync --all")
show("top-q parent", "git config --get branch.top-q.stackParent")

section "sync outside any anchor still heals every orphan"
new_repo
setup("git branch wt-x")
gsq("anchor wt-x")
setup("git checkout -q wt-x")
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
setup("git checkout -q main")
setup("git merge -q --no-ff -m merge-a feat-a")
setup("git branch -D feat-a")
run("sync")
show("feat-b parent", "git config --get branch.feat-b.stackParent")

section "--all belongs to sync"
new_repo
run("restack --all")

section "with stack.trunkUpstream, sync moves the anchor to the fetched upstream"
new_repo
origin = "#{$repo}-origin.git"
setup("git init -q --bare -b main #{origin}")
setup("git remote add origin #{origin}")
setup("git push -q -u origin main")
setup("git branch wt-x")
gsq("anchor wt-x")
setup("git checkout -q wt-x")
gsq("create feat-a"); commit("a.txt", "a1")
setup("git clone -q #{origin} #{$repo}-other")
setup("(cd #{$repo}-other && git config user.email o@example.com && git config user.name Other && " \
      "echo o1 > o.txt && git add o.txt && git commit -qm o1 && git push -q origin main)")
setup("git config stack.trunkUpstream true")
run("sync")
show("wt-x == origin/main", 'test "$(git rev-parse wt-x)" = "$(git rev-parse origin/main)" && echo yes || echo no')
show("feat-a behind origin/main", "git rev-list --count feat-a..origin/main")
show("local main behind origin/main (untouched)", "git rev-list --count main..origin/main")
