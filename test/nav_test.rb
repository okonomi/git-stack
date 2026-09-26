# frozen_string_literal: true
#
# up / down / parent: walking the stack, including through untracked parents and detached roots.
# See test/support/helper.rb for how the harness works and how to regenerate the snapshot.

require_relative "support/helper"

# With no recorded parent, the trunk comes from the branch's history rather than
# defaulting to the primary.
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

# One section on purpose: the bug was `tree`, `up`, `parent` and `down`
# disagreeing, which only shows side by side in the transcript (#85). `down`
# lands on feat-a, a branch `tree` never drew, because that is what `restack`
# replays feat-b onto; the note is what makes the jump legible.
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

# `tree` and `parent` side by side, printing the same note for the same branch
# (#85).
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

# The menu reads in `tree`'s row order: recorded children, then detached roots.
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

# `up` moves HEAD, so a detached root is offered only from the trunk its history
# rests on, not whichever trunk you stand on (#73).
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

# `tree` and `parent` print the same note. `down` dies on the missing ref before
# reaching it, which is shown here rather than assumed.
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

# The menu refuses a root that belongs to another trunk, but naming it is not a
# silent jump, so `up m-b` still reaches across (#85, #91).
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

# One detached root per trunk, with `tree` and an `up` from each trunk side by
# side, since the bug was their disagreement (#91). `d-b` is what makes this a
# real test: with only main's root, drawing everything under the primary trunk
# -- also `containing_trunk`'s fallback -- would pass.
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

# feat-b's ref is deleted with `update-ref`, so its config outlives it. `tree`
# still draws the row, but `up` must not offer it: the checkout would die with
# git's own "did not match any file(s)".
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

# Stacks created in reverse order (zzz-* before aaa-*), so an unsorted menu would
# show it; `tree` alongside proves the rows agree.
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
