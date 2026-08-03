# frozen_string_literal: true
#
# tree that renders the stack: untracked subtrees, detached stacks, a hand-edited parent cycle.
# See test/support/helper.rb for how the harness works and how to regenerate the snapshot.

require_relative "support/helper"

# tree's agreement with up on which trunk a detached root belongs to is
# covered in nav_test.rb's "tree and up agree on which trunk a detached root
# belongs to" section, not here.

section "tree renders the whole stack"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
run("tree")

# `untrack` on a branch with children leaves a parent that exists but is
# recorded nowhere: not a trunk's child, so the walk down from main never
# reaches it, and not missing either, so the orphan rule did not catch it. The
# whole subtree above it used to vanish from `tree` while the config below --
# which `restack` still obeys -- stayed exactly as it was.
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

# The root of a detached stack is found by climbing to it, not by scanning for
# it, so the branch names cannot decide the shape: here the child sorts BEFORE
# the root it hangs off. Scanning would emit the child as a root of its own and
# draw it twice -- once at root indent, once under zzz-top.
section "a detached stack is drawn once, from its top, whatever its branches are named"
new_repo
gsq("create feat-mid"); commit("m.txt", "m1")
gsq("create zzz-top"); commit("z.txt", "z1")
gsq("create aaa-leaf"); commit("l.txt", "l1")
setup("git checkout -q feat-mid")
gsq("untrack")
run("tree")

# A parent cycle is impossible through `parent`/`track` (both refuse one), but a
# hand-edited config can still hold one -- and a cycle is reachable from no
# trunk, so it used to be drawn nowhere at all. The climb to the root breaks out
# of it and the subtree walk renders each branch once.
section "tree renders a hand-edited parent cycle instead of dropping it"
new_repo
setup("git branch feat-a main")
setup("git branch feat-b main")
setup("git config branch.feat-a.stackParent feat-b")
setup("git config branch.feat-b.stackParent feat-a")
run("tree")
