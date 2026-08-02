# frozen_string_literal: true
#
# drop: splicing a branch out and reconnecting its children.
# See test/support/helper.rb for how the harness works and how to regenerate the snapshot.

require_relative "support/helper"

section "drop reconnects children to the trunk the dropped branch rested on"
new_repo
setup("git branch develop main")
gsq("init main develop")
setup("git checkout -q develop"); commit("d.txt", "d1")
# feat-a is created with plain git, so it records no parent and `drop` has to
# read the trunk it rests on out of history
setup("git checkout -q -b feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
setup("git checkout -q develop")
run("drop feat-a")
show("feat-b stackParent", "git config --get branch.feat-b.stackParent")
show("feat-b behind develop", "git rev-list --count feat-b..develop")

section "drop splices the bottom branch out, reparenting children onto trunk"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
gsq("create feat-c"); commit("c.txt", "c1")
# drop from trunk so HEAD is not one of the branches being spliced/restacked
setup("git checkout -q main")
run("drop feat-a")
show("feat-a stackParent (untracked)", "git config --get branch.feat-a.stackParent")
show("feat-a still exists", "git show-ref --verify --quiet refs/heads/feat-a && echo yes || echo no")
show("feat-b stackParent", "git config --get branch.feat-b.stackParent")
show("feat-b behind main", "git rev-list --count feat-b..main")
show("feat-c stackParent", "git config --get branch.feat-c.stackParent")
show("HEAD", "git branch --show-current")

section "drop a middle branch reconnects children to the grandparent"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
gsq("create feat-c"); commit("c.txt", "c1")
setup("git checkout -q feat-a")
run("drop feat-b")
show("feat-c stackParent", "git config --get branch.feat-c.stackParent")
show("feat-b stackParent (untracked)", "git config --get branch.feat-b.stackParent")
show("HEAD", "git branch --show-current")

section "drop reparents every child of a branch with multiple children"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
setup("git checkout -q feat-a")
gsq("create feat-c"); commit("c.txt", "c1")
setup("git checkout -q main")
run("drop feat-a")
show("feat-b stackParent", "git config --get branch.feat-b.stackParent")
show("feat-c stackParent", "git config --get branch.feat-c.stackParent")

section "drop --delete removes the branch ref after splicing"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
setup("git checkout -q main")
run("drop feat-a --delete")
show("feat-a exists", "git show-ref --verify --quiet refs/heads/feat-a && echo yes || echo no")
show("feat-b stackParent", "git config --get branch.feat-b.stackParent")
show("HEAD", "git branch --show-current")

section "drop falls back to trunk when the dropped branch's own parent is gone"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
gsq("create feat-c"); commit("c.txt", "c1")
# feat-b's recorded parent is deleted behind git-stack's back, so the name it
# reads back is dead -- non-empty, but no branch to reconnect feat-c onto
setup("git checkout -q main")
setup("git branch -D feat-a")
run("drop feat-b")
show("feat-c stackParent", "git config --get branch.feat-c.stackParent")
show("feat-c stackBase == main tip",
     'test "$(git config --get branch.feat-c.stackBase)" = "$(git rev-parse main)" && echo yes || echo no')

section "drop --delete on the current branch survives a dead recorded parent"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
setup("git checkout -q main")
setup("git branch -D feat-a")
setup("git checkout -q feat-b")
run("drop feat-b --delete")
show("feat-b exists", "git show-ref --verify --quiet refs/heads/feat-b && echo yes || echo no")
show("HEAD", "git branch --show-current")

section "drop refuses a trunk and a non-existent branch"
new_repo
gsq("create feat-a")
run("drop main")
run("drop nope")

section "drop with no argument splices the current branch"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
setup("git checkout -q feat-a")
run("drop")
show("feat-a stackParent (untracked)", "git config --get branch.feat-a.stackParent")
show("feat-b stackParent", "git config --get branch.feat-b.stackParent")
show("HEAD", "git branch --show-current")
