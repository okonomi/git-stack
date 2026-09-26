# frozen_string_literal: true
#
# name resolution: a tag shadowing a branch name, and HEAD / trunk names whose spelling is not the one git stores.
# See test/support/helper.rb for how the harness works and how to regenerate the snapshot.
#
# The spelling sections share one cause: `origin/HEAD`, HEAD or a stored trunk
# name can hold a spelling that differs from the refname git has -- after a
# `git checkout -b main origin/Main`, a rename, or on a case-insensitive
# filesystem. The user cannot correct a name they never typed, so readers
# resolve it against git's spelling rather than trusting or refusing it (#106,
# #108).

require_relative "support/helper"

# Silent when broken: `develop` and `main` both exist, so detection falls past
# the remote's answer and records `main`. Unlike the HEAD- and trunk-spelling
# sections, this fails on a case-sensitive filesystem too, where
# `refs/remotes/origin/Develop` is simply another ref.
section "init resolves the remote's default branch to the spelling git stores"
new_repo
setup("git branch develop main")
setup("git update-ref refs/remotes/origin/Develop develop")
setup("git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/Develop")
run("init")
show("stack.trunk", "git config --get stack.trunk")

# `show-ref --verify refs/heads/Main` succeeds beside `main` on a
# case-insensitive filesystem, so `init main Main` stored one branch as two
# trunks and `tree` drew it twice (#83). On a case-sensitive filesystem `Main`
# simply does not exist, with the same transcript.
section "init rejects a trunk whose spelling is not the stored refname"
new_repo
run("init main Main")

# A loose liveness check let a trunk stored as `Main` pass in a repo holding only
# `main`: `tree` drew a phantom `Main (trunk)` and cut the real stack adrift.
# Passes trivially on a case-sensitive filesystem; it is the guard on macOS.
section "a trunk whose stored spelling is not the refname is not live"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
setup("git config --add stack.trunk Main")
run("tree")
show("stack.trunk (re-detected)", "git config --get-all stack.trunk")

# In a repo holding only `Main`, a loose check accepted `main` and stored it.
# Renamed via a third name because `git branch -m main Main` fails on a
# case-insensitive filesystem.
section "trunk auto-detect will not store a name the refs do not have"
new_repo
setup("git branch -m main tmp-rename && git branch -m tmp-rename Main")
run("tree")
show("stack.trunk (nothing stored)", "git config --get-all stack.trunk")

# `%(refname:short)` answers `heads/feat-a` for a branch sharing a tag's name,
# so a `:short` scan would drop it: `tree` would flag feat-b's parent as
# missing, and the `sync` it recommends would reparent feat-b onto trunk.
section "tree keeps a branch whose name collides with a tag"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
setup("git tag feat-a") # tag sharing feat-a's name triggers the %(refname:short) disambiguation
run("tree")

# Read bare, `main..feat-b` measures the tag on main, counts 0, and main wins.
# Both callers act on that: `up` checks a develop stack out from main, and
# `sync` rebases onto it. `tree` reads recorded parents, not history, and is
# the control.
section "trunk detection ignores a tag sharing a branch's name"
new_repo
setup("git branch develop main")
gsq("init main develop")
# develop gains a commit of its own, so a branch stacked on it is strictly
# further from main -- the distance containing_trunk compares
setup("git checkout -q develop"); commit("d.txt", "d1")
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
# untracking feat-a leaves feat-b a detached root, the shape that sends `up`
# through containing_trunk to decide which trunk's menu it belongs on
setup("git checkout -q feat-a"); gsq("untrack")
setup("git tag feat-b main")
setup("git checkout -q main")
run("tree")
# main has no stack of its own: the tag is the only thing that could put feat-b here
run("up")
show("HEAD", "git branch --show-current")
# ...and from the trunk feat-b really rests on, `up` still reaches it. git's own
# ambiguity warning on the checkout stays -- the ref it lands on is the branch.
setup("git checkout -q develop")
run("up")
show("HEAD", "git branch --show-current")
# Deleting feat-a makes feat-b an orphan, sending `sync` through
# containing_trunk. Run from develop, not feat-b, so the HEAD-reading hazard
# further down cannot hide this one.
setup("git branch -D feat-a")
setup("git checkout -q develop")
run("sync")
show("feat-b stackParent", "git config --get branch.feat-b.stackParent")
# Spelled with refs/heads on both ends, or this check reads the tag too and
# reports the distance from main. 0 behind / 2 ahead is feat-b sitting on
# develop's tip carrying its own a1 and b1.
show("feat-b behind/ahead of develop",
     "git rev-list --left-right --count refs/heads/develop...refs/heads/feat-b")

# `--short` answers `heads/feat-a` here (#93). The damage is quiet, so the
# section drives a whole session: `untrack` succeeds and removes nothing,
# `track` writes keys no reader looks at, `create` records a non-branch parent,
# and only the `sync` after it destroys anything. `tree` is the witness.
section "commands read HEAD past a tag sharing the branch's name"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
setup("git tag feat-a")
# the `*` marker is `cur == branch`, the first comparison the short name breaks
run("tree")
# reports success; the assertion below is whether the recorded parent is gone
run("untrack")
show("feat-a stackParent after untrack", "git config --get branch.feat-a.stackParent")
run("track")
# the only key any reader consults is `branch.feat-a.*` -- anything else is a leak
show("stack config keys", "git config --get-regexp '^branch\\..*stack' | sort")
# a parent recorded here as `heads/feat-a` is a name `sync` reads back as missing
gsq("create feat-b"); commit("b.txt", "b1")
show("feat-b stackParent", "git config --get branch.feat-b.stackParent")
run("tree")
# ...which is where the silent mis-record turns into a rewrite: feat-b rests on
# feat-a, and healing it onto trunk would drop a1 out from under it
run("sync")
show("feat-b stackParent after sync", "git config --get branch.feat-b.stackParent")
setup("git checkout -q feat-a")
run("drop")

# Reading HEAD without `--short` must still answer "" when detached: `parent`
# dies naming the state, `tree` renders without a `*`.
section "a detached HEAD is still detached without --short"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
setup("git checkout -q --detach")
run("parent")
run("tree")

# `.git/HEAD` says `Feat-A` for the branch `feat-a`: `track` wrote keys nobody
# reads, `drop` died on the branch it stood in, and `tree` marked no row
# (#106). On a case-sensitive filesystem the checkout fails and the transcript
# is the same.
section "HEAD spelled differently from the ref still names the branch"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
setup("git checkout -q Feat-A")
run("tree")
run("track")
show("stack config keys", "git config --get-regexp '^branch\\..*stack' | sort | tr '\\n' ' '")
run("drop")

# Not a variation for its own sake: `for-each-ref --ignore-case` folds ASCII
# only, so it passes the section above and fails this one.
section "HEAD spelled differently outside ASCII still names the branch"
new_repo
gsq("create feat-ä"); commit("a.txt", "a1")
setup("git checkout -q feat-Ä")
run("tree")
run("track")
show("stack config keys", "git config --get-regexp '^branch\\..*stack' | sort | tr '\\n' ' '")
run("drop")

# The writing side: `merge-base` and `rebase --onto` resolved a bare name, so
# feat-b was replayed onto the tag on main and a1/a2 vanished, exit 0 (#96).
section "restack replays onto the parent branch, not a tag that shadows it"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
# feat-a advances, so feat-b is behind and restack has real work to do
setup("git checkout -q feat-a"); commit("a2.txt", "a2")
setup("git tag feat-a main") # tag on main sharing the PARENT's name
setup("git checkout -q feat-b")
run("restack")
# the whole assertion: a1 and a2 must still be under b1
show("feat-b commits", "git log --format=%s refs/heads/feat-b | tr '\\n' ' '")
# and the base re-anchored after the replay must be feat-a's tip, not the tag's
show("feat-b stackBase == feat-a tip",
     'test "$(git config --get branch.feat-b.stackBase)" = "$(git rev-parse refs/heads/feat-a)" && echo yes || echo no')

# `record_reparent_base`'s `merge-base` is a bare-name site the restack above
# never reaches. The tag's commit would record a base below the real fork,
# the range a later restack replays from.
section "reparenting anchors the base to the parent branch, not a tag that shadows it"
new_repo
# The tag sits below main's tip, or both merge-bases would be the same commit
# and the check could not tell them apart.
commit("m.txt", "m1")
gsq("create feat-a"); commit("a.txt", "a1")
setup("git checkout -q -b feat-c main"); commit("c.txt", "c1")
setup("git tag feat-a main~1")
run("parent feat-a")
show("feat-c stackBase == merge-base(feat-c, feat-a)",
     'test "$(git config --get branch.feat-c.stackBase)" = "$(git merge-base refs/heads/feat-c refs/heads/feat-a)" && echo yes || echo no')
