# frozen_string_literal: true
#
# tree that renders the stack: untracked subtrees, detached stacks, a hand-edited parent cycle.
# See test/support/helper.rb for how the harness works and how to regenerate the snapshot.

require_relative "support/helper"

section "tree renders the whole stack"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
run("tree")

# The untracked parent exists but is recorded nowhere: the trunk walk never
# reaches it and it is not missing, so its subtree vanished from `tree` while
# `restack` still followed it (#58).
section "tree keeps the subtree of a branch that was untracked"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
gsq("create feat-c"); commit("c.txt", "c1")
setup("git checkout -q feat-a")
gsq("untrack")
run("tree")
show("feat-a stackParent (untracked)", "git config --get branch.feat-a.stackParent")
show("feat-b stackParent (still recorded)", "git config --get branch.feat-b.stackParent")
# tracking feat-a again puts the stack back under the trunk, note and all
gsq("track")
run("tree")

# The child sorts before its root, so scanning for roots rather than climbing to
# them would draw it twice.
section "a detached stack is drawn once, from its top, whatever its branches are named"
new_repo
gsq("create feat-mid"); commit("m.txt", "m1")
gsq("create zzz-top"); commit("z.txt", "z1")
gsq("create aaa-leaf"); commit("l.txt", "l1")
setup("git checkout -q feat-mid")
gsq("untrack")
run("tree")

# `parent`/`track` refuse a cycle, but hand-edited config can hold one, and it
# is reachable from no trunk.
section "tree renders a hand-edited parent cycle instead of dropping it"
new_repo
setup("git branch feat-a main")
setup("git branch feat-b main")
setup("git config branch.feat-a.stackParent feat-b")
setup("git config branch.feat-b.stackParent feat-a")
run("tree")
