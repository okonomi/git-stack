# frozen_string_literal: true
#
# create / track / untrack / parent: the commands that write the stack metadata, and the edges they refuse.
# See test/support/helper.rb for how the harness works and how to regenerate the snapshot.

require_relative "support/helper"

# The three commands below have to answer "which trunk is this branch on?" with
# no recorded parent to follow -- untracked, or a parent that was merged and
# deleted. Naming the primary trunk pulled a develop-based stack over to main;
# each now reads the trunk out of the branch's own history.

section "track with no argument picks the trunk the branch rests on"
new_repo
setup("git branch develop main")
gsq("init main develop")
setup("git checkout -q develop"); commit("d.txt", "d1")
setup("git checkout -q -b feat-d"); commit("x.txt", "x1")
run("track")
show("feat-d stackParent", "git config --get branch.feat-d.stackParent")
# a branch off the primary trunk still tracks onto it
setup("git checkout -q main")
setup("git checkout -q -b feat-m"); commit("m.txt", "m1")
run("track")
show("feat-m stackParent", "git config --get branch.feat-m.stackParent")

section "create records the parent and checks out the branch"
new_repo
run("create feat-a")
show("HEAD", "git branch --show-current")
show("branch.feat-a.stackParent", "git config --get branch.feat-a.stackParent")

section "create rejects an existing branch"
new_repo
setup("git branch dup")
run("create dup")

section "parent shows and sets the parent"
new_repo
gsq("create feat-a")
gsq("create feat-b")
run("parent")
setup("git branch other main")
run("parent other")
show("branch.feat-b.stackParent", "git config --get branch.feat-b.stackParent")

section "untrack removes the metadata"
new_repo
gsq("create feat-a")
run("untrack")
show("branch.feat-a.stackParent", "git config --get branch.feat-a.stackParent")

section "parent rejects an indirect cycle"
new_repo
gsq("create feat-a")
gsq("create feat-b") # feat-b stacked on feat-a
setup("git checkout -q feat-a")
run("parent feat-b") # would make feat-a <-> feat-b a cycle
show("branch.feat-a.stackParent", "git config --get branch.feat-a.stackParent")

section "track rejects an indirect cycle"
new_repo
gsq("create feat-a")
gsq("create feat-b")
setup("git checkout -q feat-a")
run("track feat-b")

section "track refuses to track a trunk"
new_repo
setup("git branch develop main")
gsq("init main develop")
setup("git checkout -q develop")
run("track")
show("branch.develop.stackParent (untracked)", "git config --get branch.develop.stackParent")

section "parent refuses to reparent a trunk"
new_repo
setup("git branch develop main")
gsq("init main develop")
setup("git checkout -q develop")
run("parent main")
show("branch.develop.stackParent (untracked)", "git config --get branch.develop.stackParent")
