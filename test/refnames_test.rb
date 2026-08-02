# frozen_string_literal: true
#
# name resolution: a tag shadowing a branch name, and HEAD / trunk names whose spelling is not the one git stores.
# See test/support/helper.rb for how the harness works and how to regenerate the snapshot.
#
# Six sections below share one cause: `origin/HEAD`, `HEAD` itself, or a trunk name
# can end up holding a spelling that differs from the refname git actually has --
# left behind by a `git checkout -b main origin/Main`, a rename, or an
# outside-ASCII fold, on a filesystem loose enough to accept it. The name is not
# one the user typed and cannot correct, so every reader resolves or checks it
# against the spelling git stores rather than trusting it verbatim or matching it
# loosely -- the same treatment `current_branch_or_empty` already gives HEAD
# (issues #106, #108). Refusing it would mean declining to work in a repo git is
# perfectly happy with. Each section below still carries its own call site, its
# own symptom, and its own platform behavior -- only this shared cause is told
# once, here.

require_relative "support/helper"

# `origin/HEAD` names a branch whose stored spelling differs only in case here --
# what a `git checkout -b main origin/Main` or a rename on a case-insensitive
# filesystem leaves behind.
#
# The damage without resolving it is silent, and worse than the miss in
# init_test.rb's "init reads the remote's default branch past a local branch
# named origin/<name>" section: `develop` and `main` both exist, so detection
# does not fail -- it falls past the remote's answer to the hardcoded candidate
# and records `main`, with no note. The remote says `develop`.
#
# Unlike this file's HEAD-spelling section, this one is NOT a no-op on a
# case-sensitive filesystem: `refs/remotes/origin/Develop` and
# `refs/heads/develop` are simply two different refs there, so the fixture builds
# and the old behaviour fails the same way on Linux.
section "init resolves the remote's default branch to the spelling git stores"
new_repo
setup("git branch develop main")
setup("git update-ref refs/remotes/origin/Develop develop")
setup("git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/Develop")
run("init")
show("stack.trunk", "git config --get stack.trunk")

# The repeat check compares the strings the user typed, so a second spelling of
# ONE branch used to walk straight past it. `show-ref --verify refs/heads/Main`
# succeeds on a case-insensitive filesystem with only `main` present, so
# `init main Main` stored two trunks for one branch and `tree` drew it twice --
# the #83 symptom, reached by a different door. `init` checks the exact stored
# refnames now.
#
# The section runs the same on a case-SENSITIVE filesystem, where `Main` is
# simply a branch that does not exist: same message, same exit, for the same
# reason -- git has no `refs/heads/Main`.
section "init rejects a trunk whose spelling is not the stored refname"
new_repo
run("init main Main")

# The liveness re-check in trunk_test.rb's "a trunk that is gone with no
# replacement is an error, and config is kept" section asks about a CONFIGURED
# name, and asking loosely (see `branch_ref_exists?`) meant a trunk stored as
# `Main` passed as live in a repo holding only `main`. `tree` then drew a phantom
# `Main (trunk)` row while the real stack, resting on `main`, was cut adrift at
# trunk-child indent -- the issue #83 symptom, produced by the very re-check
# whose job is to keep ghost trunks out. Asked exactly, `Main` is what it is: a
# name with no ref. It drops out through the note in that section and the
# auto-detect puts the real trunk back.
#
# On a case-SENSITIVE filesystem `Main` never passed in the first place, so this
# reads as a no-op on CI and as the regression guard on a developer's Mac. That
# parity holds only of the FIXED output -- before the fix the two platforms
# disagreed, so no version of this section could have failed on CI.
section "a trunk whose stored spelling is not the refname is not live"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
setup("git config --add stack.trunk Main")
run("tree")
show("stack.trunk (re-detected)", "git config --get-all stack.trunk")

# `detect_trunk` asks the same question about names it is about to STORE, and got
# the same wrong answer: in a repo holding only `Main` it accepted `main`, and
# `trunk_branches` wrote that name to config -- so `tree` drew `main (trunk)`, a
# trunk git does not have, and `Main` appeared nowhere. Its own comment says a
# name with no local ref is a dead end it refuses to store.
#
# Renamed in two steps on purpose: `git branch -m main Main` FAILS on a
# case-insensitive filesystem ("a branch named 'Main' already exists" -- git
# resolving the destination the same loose way this fix is about), so going via a
# third name is what actually leaves the repo holding only `Main`.
section "trunk auto-detect will not store a name the refs do not have"
new_repo
setup("git branch -m main tmp-rename && git branch -m tmp-rename Main")
run("tree")
show("stack.trunk (nothing stored)", "git config --get-all stack.trunk")

# A branch with a same-named tag must still be seen as existing. `for-each-ref
# --format='%(refname:short)' refs/heads/` disambiguates such a branch as
# `heads/<name>` rather than `<name>`, so a `:short` scan would drop it from the
# existing-branches set: `tree` would then flag its children as "parent
# missing", and the sync the message tells the user to run would reparent those
# healthy branches onto trunk, destroying the recorded stack. Here feat-a shares
# its name with a tag; tree must still render feat-b nested under feat-a.
section "tree keeps a branch whose name collides with a tag"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
setup("git tag feat-a") # tag sharing feat-a's name triggers the %(refname:short) disambiguation
run("tree")

# The other half of the same hazard, one layer down: `containing_trunk` answers
# "which of these trunks does this branch rest on" by counting `<trunk>..<branch>`
# and taking the smallest, and a bare refname there resolves `refs/tags/` BEFORE
# `refs/heads/`. feat-b is on develop's stack while a tag of that name points at
# main, so `main..feat-b` measures the tag, counts 0, and main wins as the
# "nearest" trunk. That is not a cosmetic slip -- both callers below act on the
# answer: `up` checks a develop stack out from main, and `sync`'s orphan heal
# REBASES onto the trunk it names, dropping the commits of the one the branch was
# really built on. `tree` is the control: it reads the recorded stack rather than
# history, so it was never fooled and must keep saying develop throughout.
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
# Deleting feat-a leaves feat-b an orphan, which is what sends `sync` through
# containing_trunk. Run it from develop, not feat-b: `symbolic-ref --short` has
# the same tag-collision hazard and would report HEAD as `heads/feat-b`, which
# resolves unambiguously and would hide the bug under test.
setup("git branch -D feat-a")
setup("git checkout -q develop")
run("sync")
show("feat-b stackParent", "git config --get branch.feat-b.stackParent")
# Spelled with refs/heads on both ends, or this check reads the tag too and
# reports the distance from main. 0 behind / 2 ahead is feat-b sitting on
# develop's tip carrying its own a1 and b1.
show("feat-b behind/ahead of develop",
     "git rev-list --left-right --count refs/heads/develop...refs/heads/feat-b")

# The third leak of the same hazard, and the widest: reading HEAD. Why `--short`
# answers `heads/feat-a` here is on `current_branch_or_empty`; what it costs is
# what this section is for.
#
# The damage is quiet rather than loud, which is why this section drives a whole
# session instead of one command: `untrack` reports success and removes nothing,
# `track` writes keys under `branch.heads/feat-a.*` that no reader ever looks at,
# `create` records a parent that is not a branch, and the `sync` after it sees
# that dead parent and reparents the child onto trunk -- so the mis-record only
# becomes destructive one command later. `drop` is the sole loud one. `tree` runs
# throughout as the witness: it is the only place the current-branch marker `*`
# and the recorded edges are visible at the same time (issue #93).
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

# The guard the fix above rests on, which nothing else here covers: dropping
# `--short` must not cost the detached-HEAD check (why it does not is on
# `current_branch_or_empty`). "" is the whole distinction `current_branch` dies
# on, so both sides belong here: `parent` needs a branch and must die naming the
# state, `tree` does not and must render, minus the `*`.
section "a detached HEAD is still detached without --short"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
setup("git checkout -q --detach")
run("parent")
run("tree")

# The third way HEAD can name something the rest of the file will not match, after
# the tag shadow above and the `--short` shortening below it -- why `.git/HEAD`
# ends up holding a spelling the refs do not have is on `current_branch_or_empty`.
# What it costs is this section: `track` wrote a second `branch.Feat-A.*` nobody
# reads, `drop` died "branch 'Feat-A' does not exist" for the branch it was
# standing in, and `tree` marked no row at all (issue #106).
#
# On a case-SENSITIVE filesystem the checkout simply fails and HEAD stays on
# `feat-a`, which is the same transcript -- so this reads as a no-op on CI and as
# the regression guard on a developer's Mac, the same shape as the trunk-spelling
# sections near the top of this file.
section "HEAD spelled differently from the ref still names the branch"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
setup("git checkout -q Feat-A")
run("tree")
run("track")
show("stack config keys", "git config --get-regexp '^branch\\..*stack' | sort | tr '\\n' ' '")
run("drop")

# The same shape one character out of ASCII, and it is not a variation for its own
# sake: `for-each-ref --ignore-case` -- the obvious way to ask git for the stored
# spelling -- folds ASCII ONLY, so it answers nothing here and every symptom above
# comes back. The ASCII section is green either way, which is exactly why this one
# exists. The fold has to be Ruby's, whose `downcase` covers what the filesystem
# folded when it accepted the checkout.
section "HEAD spelled differently outside ASCII still names the branch"
new_repo
gsq("create feat-ä"); commit("a.txt", "a1")
setup("git checkout -q feat-Ä")
run("tree")
run("track")
show("stack config keys", "git config --get-regexp '^branch\\..*stack' | sort | tr '\\n' ' '")
run("drop")

# The same hazard on the WRITING side, which is where it stops being a wrong
# reading and starts destroying commits. The sections above hardened everything
# that MEASURES history; `restack` then hands the answer to `merge-base` and
# `rebase --onto`, and those still resolved a bare name -- so with a tag on main
# named after the parent, feat-b was replayed onto main and feat-a's a1/a2 were
# simply gone, under a "restacking feat-b onto feat-a" that named the branch it
# had not used. Exit 0, no warning: only the commit list shows it (issue #96).
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

# `parent` re-anchors an EXISTING branch through `merge-base <branch> <parent>`
# (record_reparent_base), a second bare-name site the restack above never reaches
# -- feat-c has diverged rather than been created on the parent's tip. Anchoring
# to the tag's commit records a base BELOW where the two actually diverge, which
# is the range a later `restack --onto` would replay from.
section "reparenting anchors the base to the parent branch, not a tag that shadows it"
new_repo
# main gains m1 so the tag can sit BELOW it: with the tag on main's tip both
# merge-bases would land on the same commit and the check could not tell them
# apart. Against `main~1` the branch answers m1 and the tag answers base.
commit("m.txt", "m1")
gsq("create feat-a"); commit("a.txt", "a1")
setup("git checkout -q -b feat-c main"); commit("c.txt", "c1")
setup("git tag feat-a main~1")
run("parent feat-a")
show("feat-c stackBase == merge-base(feat-c, feat-a)",
     'test "$(git config --get branch.feat-c.stackBase)" = "$(git merge-base refs/heads/feat-c refs/heads/feat-a)" && echo yes || echo no')
