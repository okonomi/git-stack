# frozen_string_literal: true
#
# up / down / parent: walking the stack, including through untracked parents and detached roots.
# See test/support/helper.rb for how the harness works and how to regenerate the snapshot.

require_relative "support/helper"

# With no recorded parent there is no stack to walk down, so `down`/`parent`
# read the trunk out of the branch's own history -- the same question `track`
# and `sync` ask, not the primary trunk by default.
section "down and parent walk an untracked branch to the trunk it rests on"
new_repo
setup("git branch develop main")
gsq("init main develop")
setup("git checkout -q develop"); commit("d.txt", "d1")
# created with plain git, so nothing is recorded in stack config
setup("git checkout -q -b feat-d"); commit("x.txt", "x1")
run("parent")
run("down")
show("HEAD", "git branch --show-current")
# a branch off the primary trunk still resolves to it
setup("git checkout -q main")
setup("git checkout -q -b feat-m"); commit("m.txt", "m1")
run("parent")
run("down")
show("HEAD", "git branch --show-current")

section "down / up navigate the stack"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
run("down")
show("HEAD", "git branch --show-current")
run("down")
show("HEAD", "git branch --show-current")
setup("git checkout -q feat-a")
run("up")
show("HEAD", "git branch --show-current")

section "up with multiple children requires a choice"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b")
setup("git checkout -q feat-a")
gsq("create feat-c")
setup("git checkout -q feat-a")
run("up")
run("up feat-c")
show("HEAD", "git branch --show-current")

# `tree` draws feat-b at trunk-child indent and names the untracked parent it
# actually rests on; `up`, `parent` and `down` all have to agree with it. The
# whole loop runs in ONE section on purpose -- the bug was a disagreement
# BETWEEN these commands, so only their outputs side by side in the transcript
# can show it (issue #85). Nothing else here would notice.
#
# `down` deliberately lands on feat-a, a branch tree never drew as a row: it is
# where `restack` replays feat-b onto, so refusing to go there would be its own
# kind of lie. The note is what makes the jump legible.
section "up and down round-trip through an untracked parent"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
gsq("create feat-c"); commit("c.txt", "c1")
setup("git checkout -q feat-a")
gsq("untrack")
setup("git checkout -q main")
run("tree")
run("up")
show("HEAD", "git branch --show-current")
run("parent")
run("down")
show("HEAD", "git branch --show-current")
# feat-a records no parent of its own, so the walk down ends at the trunk
run("down")
show("HEAD", "git branch --show-current")

# The round trip above cannot exercise the untracked note on `parent`/`down` by
# itself: `up` still errors (Task 3 has not landed), so HEAD never leaves `main`
# and those two calls only ever hit the trunk-is-its-own-parent case. Reach
# feat-b with a plain `git checkout` instead of `up`, so this proof does not
# wait on Task 3 -- and put `tree` right next to `parent` so the transcript
# shows them printing the SAME words for the SAME branch, from the SAME
# parent_note (issue #85).
section "parent and down name the untracked parent they walk to"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
gsq("create feat-c"); commit("c.txt", "c1")
setup("git checkout -q feat-a")
gsq("untrack")
setup("git checkout -q feat-b")
run("tree")
run("parent")
run("down")
show("HEAD", "git branch --show-current")

# The "pick one" menu has to read in the same order as the tree above it:
# recorded children first, then the detached roots -- which is the order `tree`
# prints those same rows in. `other` is the trunk's tracked child, feat-b the
# detached root, and both are rows under main.
section "up lists a detached root alongside the trunk's tracked children"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
setup("git checkout -q feat-a")
gsq("untrack")
setup("git checkout -q main")
gsq("create other"); commit("o.txt", "o1")
setup("git checkout -q main")
run("tree")
run("up")

# Trunks are peers, and `up` MOVES HEAD -- so a detached root belongs to the one
# trunk its history rests on, not to whichever trunk you happen to stand on.
# This is the same question #73 made `track`/`sync`/`drop` ask. `tree` draws the
# root without saying whose it is; `up` has to decide, and it decides by history.
section "up offers a detached root only from the trunk its stack rests on"
new_repo
setup("git branch develop main")
gsq("init main develop")
setup("git checkout -q develop"); commit("d.txt", "d1")
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
setup("git checkout -q feat-a")
gsq("untrack")
run("tree")
setup("git checkout -q main")
run("up")
setup("git checkout -q develop")
run("up")
show("HEAD", "git branch --show-current")

# The other half of the same sentence-sharing: a parent whose ref is gone. `tree`
# has always printed the sync hint for it; `parent` printed the dead name with no
# hint at all. Both rows come from parent_note now, so they are the same words.
# `down` does not reach the note -- it dies on the missing ref first, saying the
# same thing in its own way -- and that is shown here rather than assumed.
section "parent notes a parent whose ref is gone"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
setup("git checkout -q main")
setup("git merge -q --no-edit feat-a")
setup("git branch -d feat-a")
setup("git checkout -q feat-b")
run("tree")
run("parent")
run("down")

# Issue #85's own shape. `tree` now draws `m-b` under `main`, the trunk
# `containing_trunk` assigns it to (issue #91) -- so the refusal below reads as
# the obvious consequence of the picture rather than a contradiction of it:
# `develop` is drawn with no children, and `up` from `develop` says exactly
# that. Naming the branch is not the silent jump that gate exists to stop, so
# `up m-b` still has to reach across. Both halves are asserted: the menu says
# no, the name works.
section "up <name> reaches another trunk's detached root; the menu still refuses it"
new_repo
setup("git branch develop main")
gsq("init main develop")
setup("git checkout -q develop"); commit("d.txt", "d1")
setup("git checkout -q main")
gsq("create m-a"); commit("a.txt", "a1")
gsq("create m-b"); commit("b.txt", "b1")
setup("git checkout -q m-a")
gsq("untrack")
setup("git checkout -q develop")
run("tree")
run("up")
run("up m-b")
show("HEAD", "git branch --show-current")

# The shape that made #91 worth fixing rather than annotating: one detached root
# per trunk. Emitted after ALL trunks, BOTH landed at `develop`'s child indent --
# so `develop` showed two rows and offered one (the menu is per-trunk), moving
# HEAD with no prompt from a picture that showed a choice, while `main` drew no
# children and offered `m-b` anyway. The section is one `tree` and an `up` from
# EACH trunk, because the bug was that those two disagreed; only side by side
# does the agreement show.
#
# `d-b` is what makes it an answer rather than a default: `main` is `trunks[0]`,
# so a repo whose only detached root grows from `main` is passed by an
# implementation that just draws everything under the primary -- which is also
# where `containing_trunk` falls back when it cannot answer at all.
section "tree and up agree on which trunk a detached root belongs to"
new_repo
setup("git branch develop main")
gsq("init main develop")
setup("git checkout -q develop"); commit("d.txt", "d1")
setup("git checkout -q main")
gsq("create m-a"); commit("a.txt", "a1")
gsq("create m-b"); commit("b.txt", "b1")
setup("git checkout -q m-a")
gsq("untrack")
# develop's own detached root, the mirror of m-b on the non-primary trunk
setup("git checkout -q develop")
gsq("create d-a"); commit("da.txt", "da1")
gsq("create d-b"); commit("db.txt", "db1")
setup("git checkout -q d-a")
gsq("untrack")
setup("git checkout -q develop")
run("tree")
run("up")
show("HEAD", "git branch --show-current")
setup("git checkout -q main")
run("up")
show("HEAD", "git branch --show-current")

# Fix-wave finding 2, a regression this branch itself introduced (in the
# `children_of` that already shipped on it, ahead of today's finding 1):
# `feat-b`'s ref is deleted with `update-ref` (not `branch -d`), so its config
# outlives it -- the same phantom shape `orphan_roots` already guards against,
# which `detached_roots` deliberately does NOT filter (`tree` still wants to
# draw the row). Before this branch `up` reached no detached root at all, so
# this failure mode is new on it: offering the phantom would check it out and
# die with git's own "did not match any file(s)". `up` must instead refuse it
# with the same honest message an ordinary childless branch gets.
section "up refuses a detached root whose ref no longer exists (a phantom node)"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
gsq("create feat-c"); commit("c.txt", "c1")
setup("git checkout -q feat-a")
gsq("untrack")
setup("git checkout -q main")
setup("git update-ref -d refs/heads/feat-b")
run("tree")
run("up")

# Deferred from the earlier task loop: two independently-untracked stacks
# under the same trunk. `detached_roots` sorts its candidate names before
# climbing, so the menu's order should not depend on which stack was created
# first -- created in reverse-alphabetical order (zzz-* before aaa-*) here so
# an unsorted `up` would show it. `tree` and `up` sit adjacent so the
# transcript itself proves the two rows agree: main's own tracked child first,
# then the detached roots in sorted order, matching tree's rows top to bottom.
section "up orders a trunk's tracked child before its detached roots, sorted"
new_repo
gsq("create main-child"); commit("mc.txt", "1")
setup("git checkout -q main")
gsq("create zzz-a"); commit("za.txt", "1")
gsq("create zzz-b"); commit("zb.txt", "1")
setup("git checkout -q zzz-a")
gsq("untrack")
setup("git checkout -q main")
gsq("create aaa-a"); commit("aa.txt", "1")
gsq("create aaa-b"); commit("ab.txt", "1")
setup("git checkout -q aaa-a")
gsq("untrack")
setup("git checkout -q main")
run("tree")
run("up")
