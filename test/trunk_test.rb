# frozen_string_literal: true
#
# multiple trunks: how the list is read, kept live, edited one name at a time
# (plant/fell), and treated as a set of roots.
# See test/support/helper.rb for how the harness works and how to regenerate the snapshot.

require_relative "support/helper"

# An old `init main main` or a hand-written `config --add` leaves two rows,
# which validating input cannot fix; read back as-is, `tree` drew the trunk's
# subtree twice (#83).
section "an already-duplicated trunk list is deduped on read"
new_repo
gsq("init main")
gsq("create feat-a")
setup("git config --add stack.trunk main")
show("stack.trunk (raw config)", "git config --get-all stack.trunk | tr '\\n' ' '")
run("tree")

# A trunk renamed or deleted after `init` still reads back fine from config.
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

# `for-each-ref refs/heads/main` also matches `refs/heads/main/wip`, so testing
# for any output would store `main` in a repo without it. Unlike the
# case-folding sections in refnames_test.rb, this fails on every filesystem.
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

# A hand-emptied stackParent is untracked, not an edge; indexed, it drew feat-d
# as a root measured against main (#73). Two entries, so the empty one is not
# the last `--get-regexp` line, whose trailing space the scan strips.
section "an emptied stackParent is read as untracked, not as the primary trunk"
new_repo
setup("git branch develop main")
gsq("init main develop")
setup("git checkout -q develop"); commit("d.txt", "d1")
setup("git checkout -q -b feat-d"); commit("x.txt", "x1")
setup("git config branch.feat-d.stackParent ''")
# A blank value reads as empty through `get_parent`, so the scan has to agree;
# untreated it was a parent named " ".
setup("git checkout -q -b feat-w develop"); commit("w.txt", "w1")
setup("git config branch.feat-w.stackParent ' '")
setup("git checkout -q main")
gsq("create feat-m"); commit("m.txt", "m1")
show("feat-d stackParent is empty", "git config --list | grep -c '^branch\\.feat-d\\.stackparent=$'")
show("feat-w stackParent is blank", "git config --list | grep -c '^branch\\.feat-w\\.stackparent= $'")
# A row for feat-d would show a count against the wrong trunk; neither is drawn.
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

# The heal rebases, not just records: onto main it would drop develop's d1 from
# feat-b, so the ref is checked, not only the config. main is advanced first so
# a wrong trunk really would move feat-b.
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

# An old or hand-written `stackParent` on a trunk: honoured, `tree` would draw
# the subtree twice and `restack` would rebase a shared trunk. main is advanced
# first so such a rebase would really move develop.
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

# --- editing the list: plant / fell -----------------------------------------

# A dead name carried across the write would look confirmed in the summary.
section "plant drops a dead trunk from the list it writes"
new_repo
setup("git branch develop main")
setup("git branch release main")
gsq("init main develop")
setup("git branch -D develop")
run("plant release")
show("stack.trunk", "git config --get-all stack.trunk | tr '\\n' ' '")

section "plant adds a trunk without re-typing the list, and fell removes one"
new_repo
setup("git branch develop main")
setup("git branch release main")
gsq("init main")
run("plant develop")
run("plant release")
show("stack.trunk", "git config --get-all stack.trunk | tr '\\n' ' '")
run("tree")
# felling a SECONDARY trunk leaves the primary where it was: config order is
# precedence, and `containing_trunk` breaks ties with the first name
run("fell develop")
show("stack.trunk", "git config --get-all stack.trunk | tr '\\n' ' '")
# config only -- the branch itself survives being felled
show("branches", "git branch --format='%(refname:short)' | tr '\\n' ' '")

# Looking must not change what the next command does: a listing that registered
# `main` turned the following `plant my-base` into "main, my-base". The second
# half runs that pair.
section "plant and fell report the list with no arguments, and register nothing"
new_repo
setup("git branch develop main")
gsq("init main develop")
run("plant")
run("fell")
# a detection is labelled as one: `fell` cannot remove it
new_repo
setup("git branch my-base main")
run("plant")
show("stack.trunk (still unwritten)", "git config --get-all stack.trunk")
run("plant my-base")
show("stack.trunk", "git config --get-all stack.trunk | tr '\\n' ' '")

# A rejected edit must leave the list exactly as it was.
section "plant and fell reject a name the list already answers for"
new_repo
setup("git branch develop main")
gsq("init main")
run("plant main")
run("plant nope")
run("plant develop develop")
run("fell develop")
run("fell main main")
show("stack.trunk (unchanged)", "git config --get-all stack.trunk | tr '\\n' ' '")

# No auto-detect: it would plant `main` beside the name typed, and it dies in a
# repo without main/master.
section "plant on a repo that never ran init does not pull in a detected trunk"
new_repo
setup("git branch my-base main")
run("plant my-base")
show("stack.trunk", "git config --get-all stack.trunk | tr '\\n' ' '")

# Detection answers `main` again, so only the message tells this apart from a
# silent no-op.
section "felling the last trunk leaves the next command to auto-detect"
new_repo
gsq("init main")
run("fell main")
show("stack.trunk (unset)", "git config --get-all stack.trunk")
run("tree")
show("stack.trunk (re-detected)", "git config --get-all stack.trunk")

# Written back raw, the remainder (`develop`, deleted) would read as empty next
# time, re-detect, and put `main` straight back.
section "fell is not undone by a remainder of dead trunks"
new_repo
setup("git branch develop main")
gsq("init main develop")
setup("git branch -D develop")
run("fell main")
show("stack.trunk (unset, not 'develop')", "git config --get-all stack.trunk")
run("tree")

# An unset key is what asks for detection, so felling it could change nothing.
# Not the typo's message: `tree` does call this branch a trunk.
section "fell refuses a trunk that is auto-detected rather than registered"
new_repo
setup("git branch my-base main")
run("fell main")
run("plant my-base")
show("stack.trunk", "git config --get-all stack.trunk | tr '\\n' ' '")

# Named from raw config, not the live list. The "no longer exists" note prints
# once, because liveness is asked before anything is removed.
section "fell removes a trunk whose branch is already gone"
new_repo
setup("git branch develop main")
gsq("init main develop")
setup("git branch -D develop")
run("fell develop")
show("stack.trunk", "git config --get-all stack.trunk | tr '\\n' ' '")

# The dead name is the last trunk and nothing is detectable, so every other
# command dies; checked against the live list, `fell` would refuse the one name
# in config.
section "fell works on the repo where a dead trunk cannot be pruned"
new_repo
gsq("init main")
setup("git branch -m main feature")
run("tree")
run("fell main")
show("stack.trunk (unset)", "git config --get-all stack.trunk")
run("plant feature")
run("tree")

# Nothing is orphaned -- the parent still exists and `restack` replays onto it
# -- but the stack is now drawn as a detached root.
section "a stack on a felled trunk keeps its parent and is drawn as a detached root"
new_repo
setup("git branch develop main")
gsq("init main develop")
setup("git checkout -q develop"); commit("d.txt", "d1")
gsq("create feat-d"); commit("f.txt", "f1")
setup("git checkout -q main")
run("tree")
run("fell develop")
show("feat-d stackParent", "git config --get branch.feat-d.stackParent")
run("tree")

# The recorded parent is kept, inert while the branch is a trunk, so `fell` is
# an exact undo.
section "planting a tracked branch promotes it, and felling it puts it back"
new_repo
gsq("init main")
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
setup("git checkout -q main")
run("plant feat-a")
show("feat-a stackParent (kept)", "git config --get branch.feat-a.stackParent")
run("tree")
run("fell feat-a")
run("tree")
