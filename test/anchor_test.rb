# frozen_string_literal: true
#
# anchors: registering the branch a worktree tool made for a worktree, and
# stacks created on top of it.
# See test/support/helper.rb for how the harness works and how to regenerate the snapshot.
#
# An anchor here is a plain branch at main; the worktree it would normally be
# checked out in does not change what these commands record.

require_relative "support/helper"

section "anchor with no arguments lists the anchors"
new_repo
run("anchor")
setup("git branch wt-x")
gsq("anchor wt-x")
run("anchor")

section "anchor registers branches alongside the existing ones"
new_repo
setup("git branch wt-x")
setup("git branch wt-y")
run("anchor wt-x")
run("anchor wt-y")
show("stack.anchor", "git config --get-all stack.anchor | tr '\\n' ' '")

section "anchor refuses a missing branch, a trunk, a repeat and a stacked branch"
new_repo
setup("git branch wt-x")
gsq("anchor wt-x")
gsq("create feat-a")
run("anchor nope")
run("anchor main")
run("anchor wt-x")
run("anchor feat-a")
setup("git branch wt-y")
run("anchor wt-y wt-y")

section "unanchor removes an anchor and keeps the branch"
new_repo
setup("git branch wt-x")
setup("git branch wt-y")
gsq("anchor wt-x wt-y")
run("unanchor wt-x")
run("unanchor wt-y")
run("unanchor wt-y")
show("wt-x still a branch", "git rev-parse --verify --quiet refs/heads/wt-x >/dev/null && echo yes || echo no")

section "create on an anchor stacks on the trunk and records the anchor"
new_repo
setup("git branch wt-x")
gsq("anchor wt-x")
setup("git checkout -q wt-x")
run("create feat-a")
show("feat-a parent", "git config --get branch.feat-a.stackParent")
show("feat-a base == wt-x", 'test "$(git config --get branch.feat-a.stackBase)" = "$(git rev-parse wt-x)" && echo yes || echo no')
show("feat-a anchor", "git config --get branch.feat-a.stackAnchor")
show("wt-x used", "git config --get branch.wt-x.stackAnchorUsed")
show("wt-x parent (none)", "git config --get branch.wt-x.stackParent || echo none")

section "create on a stacked branch inherits its anchor"
new_repo
setup("git branch wt-x")
gsq("anchor wt-x")
setup("git checkout -q wt-x")
gsq("create feat-a"); commit("a.txt", "a1")
run("create feat-b")
show("feat-b parent", "git config --get branch.feat-b.stackParent")
show("feat-b anchor", "git config --get branch.feat-b.stackAnchor")

section "create elsewhere records no anchor"
new_repo
setup("git branch wt-x")
gsq("anchor wt-x")
run("create feat-a")
show("feat-a anchor", "git config --get branch.feat-a.stackAnchor || echo none")

section "an anchor is never a parent"
new_repo
setup("git branch wt-x")
gsq("anchor wt-x")
setup("git checkout -q -b feat-a")
run("track wt-x")
gsq("track main")
run("parent wt-x")
show("feat-a parent", "git config --get branch.feat-a.stackParent")

section "unanchor clears the anchor from its stacks"
new_repo
setup("git branch wt-x")
gsq("anchor wt-x")
setup("git checkout -q wt-x")
gsq("create feat-a")
run("unanchor wt-x")
show("feat-a anchor", "git config --get branch.feat-a.stackAnchor || echo none")
show("feat-a parent", "git config --get branch.feat-a.stackParent")

section "a branch that leaves its stack leaves its anchor"
new_repo
setup("git branch wt-x")
gsq("anchor wt-x")
setup("git checkout -q wt-x")
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
gsq("create feat-c")
run("drop feat-a")
show("feat-a anchor", "git config --get branch.feat-a.stackAnchor || echo none")
show("feat-b anchor", "git config --get branch.feat-b.stackAnchor")
run("untrack")
show("feat-c anchor", "git config --get branch.feat-c.stackAnchor || echo none")

section "tree draws an anchor as a heading over its stacks"
new_repo
setup("git branch wt-x")
setup("git branch wt-y")
gsq("anchor wt-x wt-y")
setup("git checkout -q wt-x")
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
setup("git checkout -q wt-x")
gsq("create fix-c"); commit("c.txt", "c1")
setup("git checkout -q main")
gsq("create other"); commit("o.txt", "o1")
setup("git checkout -q feat-b")
run("tree")

section "tree says when an anchor has fallen behind its trunk"
new_repo
setup("git branch wt-x")
gsq("anchor wt-x")
setup("git checkout -q wt-x")
gsq("create feat-a"); commit("a.txt", "a1")
setup("git checkout -q main"); commit("m.txt", "m2")
run("tree")

section "tree marks an anchor done once every branch on it is deleted"
new_repo
setup("git branch wt-x")
setup("git branch wt-y")
gsq("anchor wt-x wt-y")
setup("git checkout -q wt-x")
gsq("create feat-a"); commit("a.txt", "a1")
setup("git checkout -q main")
setup("git merge -q --no-ff -m merge-a feat-a")
setup("git branch -D feat-a")
run("tree")
