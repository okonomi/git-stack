# frozen_string_literal: true
#
# multiple trunks: how the list is read, kept live, and treated as a set of roots.
# See test/support/helper.rb for how the harness works and how to regenerate the snapshot.

require_relative "support/helper"

# A list that is already duplicated cannot be fixed by validating input: repos
# that ran the old `init main main`, or a hand-written `config --add`, still carry
# two rows. Written straight to config here to be exactly that repo. Every reader
# goes through `configured_trunks`, so deduping there is what stops `tree` drawing
# the trunk -- and its whole subtree -- twice.
section "an already-duplicated trunk list is deduped on read"
new_repo
gsq("init main")
gsq("create feat-a")
setup("git config --add stack.trunk main")
show("stack.trunk (raw config)", "git config --get-all stack.trunk | tr '\\n' ' '")
run("tree")

# `init` and auto-detect only ever record a branch that exists, but nothing
# keeps it there. These three cover a recorded trunk that was renamed or
# deleted afterwards -- the name reads back fine and is a ghost.
section "sync re-detects a renamed trunk instead of reparenting onto its old name"
new_repo
setup("git branch -m main master")
gsq("init master")
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
# the trunk is renamed and feat-b's parent deleted, as a merged-and-cleaned-up
# PR would leave it: `stack.trunk` still says `master`, which no longer exists
setup("git checkout -q master")
setup("git branch -m master main")
setup("git branch -D feat-a")
setup("git checkout -q feat-b")
run("sync")
show("stack.trunk", "git config --get-all stack.trunk")
show("feat-b stackParent", "git config --get branch.feat-b.stackParent")
show("feat-b behind main", "git rev-list --count feat-b..main")

section "a vanished secondary trunk is dropped from the trunk list"
new_repo
setup("git branch develop main")
gsq("init main develop")
setup("git branch -D develop")
run("tree")
show("stack.trunk", "git config --get-all stack.trunk")
# the pruned list is cached, so the next command has nothing to say
run("tree")

section "a trunk that is gone with no replacement is an error, and config is kept"
new_repo
gsq("init main")
setup("git branch -m main feature")
run("tree")
show("stack.trunk", "git config --get-all stack.trunk")

# The other half of asking exactly, and the half that is NOT about case folding --
# so unlike refnames_test.rb's "a trunk whose stored spelling is not the refname
# is not live" and "trunk auto-detect will not store a name the refs do not
# have" sections, this one fails on every filesystem if the check regresses.
# `for-each-ref refs/heads/main` matches one level down and answers
# `refs/heads/main/wip`, so testing "did it print anything" would resurrect the
# phantom trunk: `detect_trunk` would store `main` in a repo that has no such
# branch. Only the exact-line test refuses it.
section "a branch one level down does not stand in for its parent name"
new_repo
setup("git branch -m main main/wip")
run("tree")
show("stack.trunk (nothing stored)", "git config --get-all stack.trunk")

section "tree renders each trunk as its own root"
new_repo
setup("git branch develop main")
gsq("init main develop")
setup("git checkout -q main")
gsq("create feat-a"); commit("a.txt", "a1")
setup("git checkout -q develop")
gsq("create feat-d"); commit("d.txt", "d1")
run("tree")

# A hand-emptied `branch.<name>.stackParent` is untracked config, not an edge.
# Admitting it put the branch in the parent index with a parent nothing could
# resolve: `tree` drew it as a detached root and measured the row against the
# snapshot's single build-time trunk -- main, for a branch built on develop
# (issue #73). Two entries are written so the empty one is not the last line of
# `git config --get-regexp`, whose trailing space the scan's `.strip` removed:
# the same config used to parse two different ways depending on its position.
section "an emptied stackParent is read as untracked, not as the primary trunk"
new_repo
setup("git branch develop main")
gsq("init main develop")
setup("git checkout -q develop"); commit("d.txt", "d1")
setup("git checkout -q -b feat-d"); commit("x.txt", "x1")
setup("git config branch.feat-d.stackParent ''")
# a whitespace-only value is the same non-answer, and has to read the same way
# through both doors into this key: `get_parent` normalizes it through
# `git_out`'s strip, so the scan strips too. Untreated it was a parent NAMED " ".
setup("git checkout -q -b feat-w develop"); commit("w.txt", "w1")
setup("git config branch.feat-w.stackParent ' '")
setup("git checkout -q main")
gsq("create feat-m"); commit("m.txt", "m1")
show("feat-d stackParent is empty", "git config --list | grep -c '^branch\\.feat-d\\.stackparent=$'")
show("feat-w stackParent is blank", "git config --list | grep -c '^branch\\.feat-w\\.stackparent= $'")
# feat-d is one commit past develop and two past main, so a row for it here
# would have named the count that gives it away. Neither draws a row at all.
run("tree")
# navigation was already right (it reads the branch's own history) and stays so
setup("git checkout -q feat-d")
run("parent")
run("track")
run("tree")

section "restack stops at the secondary trunk it rests on"
new_repo
setup("git branch develop main")
gsq("init main develop")
setup("git checkout -q develop")
gsq("create feat-d"); commit("d.txt", "d1")
gsq("create feat-d2"); commit("d2.txt", "d2")
# advance develop, leaving feat-d behind its trunk
setup("git checkout -q develop"); commit("dev.txt", "dev2")
setup("git checkout -q feat-d")
run("restack")
show("feat-d parent", "git config --get branch.feat-d.stackParent")
show("feat-d behind develop", "git rev-list --count feat-d..develop")
show("feat-d2 behind feat-d", "git rev-list --count feat-d2..feat-d")

section "down and parent treat every trunk as a bottom"
new_repo
setup("git branch develop main")
gsq("init main develop")
# on the secondary trunk: no parent is recorded, but it must not fall back to
# the primary trunk -- trunks are peers, not stacked on one another
setup("git checkout -q develop")
run("down")
show("HEAD", "git branch --show-current")
run("parent")
# the primary trunk behaves the same way
setup("git checkout -q main")
run("down")
run("parent")
# a branch stacked on the secondary trunk still walks down to it
setup("git checkout -q develop")
gsq("create feat-d")
run("parent")
run("down")
show("HEAD", "git branch --show-current")

# The heaviest of the three: sync's orphan heal doesn't just record a parent, it
# rebases onto it. Healing this stack onto main would replay feat-b off develop
# and drop develop's own commits from it -- so the checks below assert the ref,
# not only the config. main is advanced first so a wrong trunk really would move
# feat-b.
section "sync heals an orphan onto the trunk its stack rests on"
new_repo
setup("git branch develop main")
gsq("init main develop")
setup("git checkout -q develop"); commit("d.txt", "d1")
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
# merge feat-a into develop and delete it, as a merged PR would
setup("git checkout -q develop")
setup("git merge -q --no-edit feat-a")
setup("git branch -d feat-a")
setup("git checkout -q main"); commit("m.txt", "m1")
setup("git checkout -q feat-b")
run("sync")
show("feat-b stackParent", "git config --get branch.feat-b.stackParent")
show("feat-b behind develop", "git rev-list --count feat-b..develop")
puts "feat-b contains d1: #{`cd #{$repo} && git log --oneline feat-b | grep -c ' d1$' || true`.strip}"

section "sync still heals a main-based orphan onto main when a second trunk exists"
new_repo
setup("git branch develop main")
gsq("init main develop")
setup("git checkout -q develop"); commit("d.txt", "d1")
setup("git checkout -q main")
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
setup("git checkout -q main")
setup("git merge -q --no-edit feat-a")
setup("git branch -d feat-a")
setup("git checkout -q feat-b")
run("sync")
show("feat-b stackParent", "git config --get branch.feat-b.stackParent")

# A trunk that still carries a `stackParent` -- recorded before `track`/`parent`
# learned to refuse a trunk, or set by hand -- must be read back as a root
# anyway: `tree` must not print its subtree a second time under the other trunk,
# and `restack` must not rebase the shared trunk onto it (rewriting published
# history). main is advanced past develop first, so a trunk that were treated as
# a stack member really would be replayed.
section "a trunk's recorded parent is ignored by tree and restack"
new_repo
setup("git branch develop main")
gsq("init main develop")
setup("git checkout -q develop"); commit("d.txt", "d1")
gsq("create feat-d"); commit("f.txt", "f1")
setup("git checkout -q main"); commit("m.txt", "m1")
setup("git checkout -q develop")
setup("git config branch.develop.stackParent main")
show("develop before", "git rev-parse develop")
run("tree")
run("restack")
show("develop after", "git rev-parse develop")
show("feat-d stackParent", "git config --get branch.feat-d.stackParent")
