# frozen_string_literal: true
#
# Snapshot test for git-stack, run by `spin test`.
#
# This is a real snapshot test: it drives git-stack through a series of
# scenarios in throwaway git repositories and prints a transcript of exactly
# what each command emits (stdout+stderr) plus its exit status. `spin test`
# compiles this file with Spinel, runs it, and diffs its stdout against the
# committed snapshot in `test/cli_test.rb.expected`. Any difference -- a
# changed message, a new line, a different exit code -- fails the test.
#
# There are no hand-written expected values here; the snapshot IS the oracle.
# After an intentional behaviour change, refresh it from CRuby with:
#
#     spin test --regen
#
# It also runs unchanged under CRuby, so you can regenerate/inspect without
# Spinel:
#
#     ruby test/cli_test.rb                 # print the transcript
#     ruby test/cli_test.rb > test/cli_test.rb.expected   # regenerate snapshot
#
# By default it drives the Ruby script under CRuby; point GIT_STACK at another
# build to snapshot that one instead:
#
#     GIT_STACK="$PWD/build/bin/git-stack" ruby test/cli_test.rb   # spinel binary
#
# Written in the same Spinel-accepted subset of Ruby as bin/git-stack.rb
# (shelling out via backticks and `system`, no File/Dir/tmpdir).

# The repo root is the directory we are launched from (`spin test` and
# `ruby test/cli_test.rb` both run from the project root). We capture it up
# front because each scenario cd's into a throwaway repo before invoking
# git-stack.
$root = `pwd`.strip

# Pin author/committer dates so every fixture commit hashes reproducibly. The
# conflict-recovery message now prints a base SHA (`git rebase --onto <parent>
# <base>`), and the snapshot must match byte-for-byte across runs -- and between
# the CRuby oracle here and the Spinel build under `spin test`. Every git
# commit below runs through `system`, which inherits this process's environment,
# so setting it once fixes them all. (Spinel supports ENV assignment and
# propagates it to the subshell, same as CRuby.)
ENV["GIT_AUTHOR_DATE"] = "2001-02-03T04:05:06 +0000"
ENV["GIT_COMMITTER_DATE"] = "2001-02-03T04:05:06 +0000"

$gs = ENV["GIT_STACK"]
$gs = "ruby #{$root}/bin/git-stack.rb" if $gs.nil? || $gs == ""
# Disable colour so the transcript is stable regardless of the terminal.
$gs = "NO_COLOR=1 #{$gs}"

$repo = ""

# --- helpers ----------------------------------------------------------------

def section(title)
  puts ""
  puts "### #{title}"
end

# Run a shell command inside the current throwaway repo, discarding output.
# Used to set up state whose effect a later git-stack command reveals.
def setup(cmd)
  system("cd #{$repo} && #{cmd} >/dev/null 2>&1")
end

# Run git-stack quietly (for building up a stack before the command under test).
def gsq(args)
  setup("#{$gs} #{args}")
end

# Run git-stack and record its combined output and exit status in the snapshot.
def run(args)
  puts "$ git stack #{args}"
  out = `cd #{$repo} && #{$gs} #{args} 2>&1`
  rc = ($? == 0) ? "0" : "1"
  print out
  puts "[exit #{rc}]"
end

# Print a labelled, deterministic piece of repository state.
def show(label, cmd)
  puts "#{label}: #{gval(cmd)}"
end

def gval(cmd)
  `cd #{$repo} && #{cmd} 2>/dev/null`.strip
end

# Create a fresh repo with a single commit on `main` and make it current.
def new_repo
  $repo = `mktemp -d`.strip
  setup("git init -q -b main")
  setup("git config user.email test@example.com")
  setup("git config user.name Test")
  setup("git config commit.gpgsign false")
  setup("echo base > file.txt && git add file.txt && git commit -qm base")
end

def commit(file, msg) # commit <file> <message>
  setup("echo #{msg} > #{file} && git add #{file} && git commit -qm #{msg}")
end

# --- scenarios --------------------------------------------------------------

section "init auto-detects the trunk"
new_repo
run("init")
show("stack.trunk", "git config --get stack.trunk")

# `origin/HEAD` is a symbolic ref like any other, so these four point it at a
# remote-tracking ref directly rather than cloning: detect_trunk only ever reads
# `git symbolic-ref refs/remotes/origin/HEAD`, and a real remote would make the
# snapshot depend on a second throwaway repo's path.

section "init prefers the remote's default branch over main"
new_repo
setup("git branch develop main")
setup("git update-ref refs/remotes/origin/develop develop")
setup("git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/develop")
run("init")
show("stack.trunk", "git config --get stack.trunk")

section "init ignores the remote's default branch when it has no local ref"
new_repo
setup("git update-ref refs/remotes/origin/gone main")
setup("git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/gone")
run("init")
show("stack.trunk", "git config --get stack.trunk")

# Why `--short` answers `remotes/origin/develop` here is on `detect_trunk`; what
# it costs is what this section is for. Nothing looks wrong from outside: the
# remote's answer is thrown away and detection falls through to main, which is
# indistinguishable from a repo that simply has no `origin/HEAD`. `develop` is
# what origin/HEAD names, so `develop` is what init must record.
section "init reads the remote's default branch past a local branch named origin/<name>"
new_repo
setup("git branch develop main")
setup("git branch origin/develop main") # the local ref that makes `origin/develop` ambiguous
setup("git update-ref refs/remotes/origin/develop develop")
setup("git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/develop")
run("init")
show("stack.trunk", "git config --get stack.trunk")

section "init dies when the remote's default branch is the only candidate"
new_repo
setup("git branch -m main feature")
setup("git update-ref refs/remotes/origin/gone feature")
setup("git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/gone")
run("init")
show("stack.trunk", "git config --get stack.trunk")

section "init records multiple trunks and lists them"
new_repo
setup("git branch develop main")
run("init main develop")
show("stack.trunk", "git config --get-all stack.trunk")
run("init")

section "init rejects a non-existent trunk"
new_repo
run("init nope")

# A repeated trunk used to be stored twice, and `tree` then drew that trunk --
# and its whole subtree -- twice over. Rejecting rather than quietly deduping:
# `init main main` is a typo, and the trunk list is the one setting every other
# command reads, so saying so beats silently storing something the user did not
# type. The existing list must survive the rejection, which is the second show:
# a failed `init` writes nothing (issue #83).
section "init rejects a duplicate trunk name"
new_repo
setup("git branch develop main")
gsq("init main develop")
run("init main develop main")
show("stack.trunk (unchanged)", "git config --get-all stack.trunk | tr '\\n' ' '")

# The repeat check compares the strings the user typed, so a second spelling of
# ONE branch used to walk straight past it. `show-ref --verify refs/heads/Main`
# succeeds on a case-insensitive filesystem with only `main` present, so
# `init main Main` stored two trunks for one branch and `tree` drew it twice --
# the #83 symptom, reached by a different door. `init` checks the exact stored
# refnames now, which is the spelling every other reader compares against.
#
# The section runs the same on a case-SENSITIVE filesystem, where `Main` is
# simply a branch that does not exist: same message, same exit, for the same
# reason -- git has no `refs/heads/Main`.
section "init rejects a trunk whose spelling is not the stored refname"
new_repo
run("init main Main")

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

section "drop reconnects children to the trunk the dropped branch rested on"
new_repo
setup("git branch develop main")
gsq("init main develop")
setup("git checkout -q develop"); commit("d.txt", "d1")
# feat-a is created with plain git, so it records no parent and `drop` has to
# read the trunk it rests on out of history
setup("git checkout -q -b feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
setup("git checkout -q develop")
run("drop feat-a")
show("feat-b stackParent", "git config --get branch.feat-b.stackParent")
show("feat-b behind develop", "git rev-list --count feat-b..develop")

section "version shows the program version"
run("version")

section "global flags are parsed with optparse"
run("-v")
run("--version")
run("-h")

section "an unknown flag is rejected"
run("--bogus")

# A typo in an argument used to be silent: every command read only the argument
# it wanted and dropped the rest, so `create feat-b oops` created `feat-b` and
# said nothing about `oops`. Worse for `--delete`, which the dispatcher lifts out
# BEFORE the subcommand is known and re-attaches to whatever ran, so it was
# accepted everywhere and honoured only by `drop`.
#
# One section for all of it because the shapes are one rule, not several: a
# command's arity (`init` unlimited, the branch-taking ones at most one, the rest
# none) and its flags are checked together, before the repo is touched. The last
# two shows are that "before": the run above must not have created a branch or
# moved HEAD. `--delete` on `drop` itself keeps working, proved where it always
# was (see "drop --delete removes the branch ref after splicing") (issue #83).
section "commands reject extra arguments and flags they do not take"
new_repo
gsq("create feat-a")
# one per rule, not one per command: too many for a command that takes one, any
# for a command that takes none, and a flag whose owner is someone else
run("create feat-b unexpected")
run("tree bogus")
run("restack --delete")
show("branches", "git branch --format='%(refname:short)' | tr '\\n' ' '")
show("HEAD", "git branch --show-current")

# An empty argument names no branch -- `arg0` and `first_operand` both say so in
# as many words -- so counting it as a positional would reject command lines the
# commands themselves handle. A wrapper writing `git stack down "$maybe_unset"`
# is the ordinary way to hit this. `drop "" feat-a` still drops `feat-a`.
section "an empty argument is not counted as a positional"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
run("tree ''")
run("drop '' feat-a")
show("feat-b stackParent", "git config --get branch.feat-b.stackParent")

section "create records the parent and checks out the branch"
new_repo
run("create feat-a")
show("HEAD", "git branch --show-current")
show("branch.feat-a.stackParent", "git config --get branch.feat-a.stackParent")

section "create rejects an existing branch"
new_repo
setup("git branch dup")
run("create dup")

section "tree renders the whole stack"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
run("tree")

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

section "restack replays descendants onto the updated parent"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
# add a new commit on feat-a, leaving feat-b behind
setup("git checkout -q feat-a")
commit("a2.txt", "a2")
setup("git checkout -q feat-b")
run("restack")
show("feat-b behind feat-a", "git rev-list --count feat-b..feat-a")
puts "feat-b contains a2: #{`cd #{$repo} && git log --oneline feat-b | grep -c ' a2$' || true`.strip}"
show("HEAD", "git branch --show-current")

section "restack aborts cleanly on a conflict"
new_repo
gsq("create feat-a")
setup("echo from-a > shared.txt && git add shared.txt && git commit -qm a-shared")
gsq("create feat-b")
setup("echo from-b > shared.txt && git add shared.txt && git commit -qm b-shared")
# create a conflicting change on feat-a
setup("git checkout -q feat-a")
setup("echo changed-a > shared.txt && git add shared.txt && git commit -qm a-conflict")
setup("git checkout -q feat-b")
run("restack")
puts "rebase in progress: #{`cd #{$repo} && git status | grep -c 'rebase in progress' || true`.strip}"

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

# `tree` and `restack`/`sync` have to agree on where a stack STARTS; they used
# not to (issue #80 -- `StackTopology#stack_root` carries the story). The three
# commands run in ONE section on purpose: the regression is only visible as a
# disagreement between their outputs, so they have to sit next to each other in
# the transcript for a diff to show it. Nothing else here would notice.
section "restack and sync name the same root tree draws, with an untracked parent"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
gsq("create feat-c"); commit("c.txt", "c1")
setup("git checkout -q feat-a")
gsq("untrack")
setup("git checkout -q feat-b")
run("tree")
run("restack")
run("sync")
# feat-b still rests on feat-a, and sync did not "heal" it onto the trunk: an
# untracked parent that still EXISTS is not an orphan.
show("feat-b stackParent after both", "git config --get branch.feat-b.stackParent")
show("feat-c stackParent after both", "git config --get branch.feat-c.stackParent")

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

section "drop splices the bottom branch out, reparenting children onto trunk"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
gsq("create feat-c"); commit("c.txt", "c1")
# drop from trunk so HEAD is not one of the branches being spliced/restacked
setup("git checkout -q main")
run("drop feat-a")
show("feat-a stackParent (untracked)", "git config --get branch.feat-a.stackParent")
show("feat-a still exists", "git show-ref --verify --quiet refs/heads/feat-a && echo yes || echo no")
show("feat-b stackParent", "git config --get branch.feat-b.stackParent")
show("feat-b behind main", "git rev-list --count feat-b..main")
show("feat-c stackParent", "git config --get branch.feat-c.stackParent")
show("HEAD", "git branch --show-current")

section "drop a middle branch reconnects children to the grandparent"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
gsq("create feat-c"); commit("c.txt", "c1")
setup("git checkout -q feat-a")
run("drop feat-b")
show("feat-c stackParent", "git config --get branch.feat-c.stackParent")
show("feat-b stackParent (untracked)", "git config --get branch.feat-b.stackParent")
show("HEAD", "git branch --show-current")

section "drop reparents every child of a branch with multiple children"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
setup("git checkout -q feat-a")
gsq("create feat-c"); commit("c.txt", "c1")
setup("git checkout -q main")
run("drop feat-a")
show("feat-b stackParent", "git config --get branch.feat-b.stackParent")
show("feat-c stackParent", "git config --get branch.feat-c.stackParent")

section "drop --delete removes the branch ref after splicing"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
setup("git checkout -q main")
run("drop feat-a --delete")
show("feat-a exists", "git show-ref --verify --quiet refs/heads/feat-a && echo yes || echo no")
show("feat-b stackParent", "git config --get branch.feat-b.stackParent")
show("HEAD", "git branch --show-current")

section "drop falls back to trunk when the dropped branch's own parent is gone"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
gsq("create feat-c"); commit("c.txt", "c1")
# feat-b's recorded parent is deleted behind git-stack's back, so the name it
# reads back is dead -- non-empty, but no branch to reconnect feat-c onto
setup("git checkout -q main")
setup("git branch -D feat-a")
run("drop feat-b")
show("feat-c stackParent", "git config --get branch.feat-c.stackParent")
show("feat-c stackBase == main tip",
     'test "$(git config --get branch.feat-c.stackBase)" = "$(git rev-parse main)" && echo yes || echo no')

section "drop --delete on the current branch survives a dead recorded parent"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
setup("git checkout -q main")
setup("git branch -D feat-a")
setup("git checkout -q feat-b")
run("drop feat-b --delete")
show("feat-b exists", "git show-ref --verify --quiet refs/heads/feat-b && echo yes || echo no")
show("HEAD", "git branch --show-current")

section "drop refuses a trunk and a non-existent branch"
new_repo
gsq("create feat-a")
run("drop main")
run("drop nope")

section "drop with no argument splices the current branch"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
setup("git checkout -q feat-a")
run("drop")
show("feat-a stackParent (untracked)", "git config --get branch.feat-a.stackParent")
show("feat-b stackParent", "git config --get branch.feat-b.stackParent")
show("HEAD", "git branch --show-current")

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

section "restack leaves an untracked branch alone"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
gsq("untrack") # feat-a is current; drop its parent
run("restack") # must NOT rebase feat-a onto the trunk
show("HEAD", "git branch --show-current")

section "sync reparents an orphaned branch onto trunk and restacks it"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
# simulate "merge feat-a into main, then delete it"
setup("git checkout -q main")
setup("git merge -q --no-edit feat-a")
setup("git branch -d feat-a")
setup("git checkout -q feat-b")
run("sync")
show("branch.feat-b.stackParent", "git config --get branch.feat-b.stackParent")
show("feat-b behind main", "git rev-list --count feat-b..main")
show("HEAD", "git branch --show-current")

section "sync heals a multi-level orphan chain in one pass"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
gsq("create feat-c"); commit("c.txt", "c1")
# merge and delete both feat-a and feat-b, leaving feat-c's parent chain
# (feat-c -> feat-b -> feat-a -> main) with two missing links
setup("git checkout -q main")
setup("git merge -q --no-edit feat-b") # feat-b already contains feat-a's commit
setup("git branch -d feat-a")
setup("git branch -d feat-b")
setup("git checkout -q feat-c")
run("sync")
show("branch.feat-c.stackParent", "git config --get branch.feat-c.stackParent")
show("feat-c behind main", "git rev-list --count feat-c..main")

section "sync reports a conflict the same way restack does"
new_repo
gsq("create feat-a")
setup("echo from-a > shared.txt && git add shared.txt && git commit -qm a-shared")
gsq("create feat-b")
setup("echo from-b > shared.txt && git add shared.txt && git commit -qm b-shared")
setup("git checkout -q main")
setup("git merge -q --no-edit feat-a")
setup("git branch -d feat-a")
setup("echo changed-a > shared.txt && git add shared.txt && git commit -qm main-conflict")
setup("git checkout -q feat-b")
run("sync")

section "tree shows a branch whose parent was deleted, then sync fixes it"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
setup("git checkout -q main")
setup("git merge -q --no-edit feat-a")
setup("git branch -d feat-a")
setup("git checkout -q feat-b")
run("tree")
gsq("sync")
run("tree")

# `tree` prints "run `git stack sync`" beside every orphan it draws, from
# wherever it is run -- so sync has to be able to repair every one of them from
# wherever IT is run. It used to walk only the stack holding the current branch:
# standing on `main`, the command tree had just recommended answered "done." and
# changed nothing, and the missing precondition (be inside the orphaned subtree)
# appeared in neither output (issue #55). The two commands run in one section
# because the regression is exactly a disagreement between them.
#
# other-b is here to be left alone: it is detached from the trunk walk too, but
# its parent still exists and is merely untracked, so it is no orphan and sync
# has no business rebasing it.
section "sync heals an orphan in another stack when run from the trunk"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
setup("git checkout -q main")
gsq("create other-a"); commit("o.txt", "o1")
gsq("create other-b"); commit("p.txt", "p1")
setup("git checkout -q other-a")
gsq("untrack")
# merge feat-a into main and delete it, as a merged PR would, then run sync from
# the trunk -- not from the orphaned subtree
setup("git checkout -q main")
setup("git merge -q --no-edit feat-a")
setup("git branch -d feat-a")
run("tree")
run("sync")
show("feat-b stackParent", "git config --get branch.feat-b.stackParent")
show("feat-b behind main", "git rev-list --count feat-b..main")
show("other-b stackParent (untouched)", "git config --get branch.other-b.stackParent")
show("HEAD", "git branch --show-current")
run("tree")

# Every orphan in the repository is healed, not just the first one found, and
# the sweep runs even when the current branch is itself inside an orphaned
# stack: feat-b is the root of the walk sync starts with, so it must not be
# replayed a second time by the sweep that repairs other-b.
section "sync heals every orphaned stack in one pass, without repeating its own"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
setup("git checkout -q main")
gsq("create other-a"); commit("o.txt", "o1")
gsq("create other-b"); commit("p.txt", "p1")
setup("git checkout -q main")
setup("git merge -q --no-edit feat-a")
setup("git merge -q --no-edit other-a")
setup("git branch -d feat-a")
setup("git branch -d other-a")
setup("git checkout -q feat-b")
run("sync")
show("feat-b stackParent", "git config --get branch.feat-b.stackParent")
show("other-b stackParent", "git config --get branch.other-b.stackParent")
show("HEAD", "git branch --show-current")

# The reason `restack` uses `git rebase --onto <parent> <stackBase>` instead of a
# plain `git rebase <parent>`: when a parent is squash-merged into trunk and
# deleted, its several commits become ONE new commit whose patch-id matches none
# of the originals, so a plain rebase re-applies them and conflicts. feature-a
# has TWO commits here on purpose -- a single-commit squash would share a1's
# patch-id and be dropped even by a plain rebase, hiding the bug.
section "sync recovers a branch whose parent was squash-merged and deleted"
new_repo
gsq("create feature-a"); commit("a.txt", "a1")
commit("a.txt", "a2") # second commit on feature-a, so the squash differs from any one commit
gsq("create feature-b"); commit("b.txt", "b1")
# squash-merge feature-a into main and delete it (as a squash-merge PR would):
# main gains one combined commit, and feature-a's own commits are gone from any ref.
setup("git checkout -q main")
setup("git merge --squash feature-a >/dev/null 2>&1 && git commit -qm squash-feature-a")
setup("git branch -D feature-a")
setup("git checkout -q feature-b")
run("sync")
show("feature-b stackParent", "git config --get branch.feature-b.stackParent")
show("feature-b behind main", "git rev-list --count feature-b..main")
show("feature-b commits above main", "git rev-list --count main..feature-b")
puts "feature-b contains a1: #{`cd #{$repo} && git log --oneline feature-b | grep -c ' a1$' || true`.strip}"
puts "feature-b contains a2: #{`cd #{$repo} && git log --oneline feature-b | grep -c ' a2$' || true`.strip}"
puts "feature-b contains b1: #{`cd #{$repo} && git log --oneline feature-b | grep -c ' b1$' || true`.strip}"
show("feature-b stackBase == main tip",
     'test "$(git config --get branch.feature-b.stackBase)" = "$(git rev-parse main)" && echo yes || echo no')

# A branch whose own commits already sit in its parent, with the parent advanced
# past it (a base branch merged into trunk, then trunk moved on): it has commits
# in `base..branch` but none above the parent, so `rebase --onto <parent> <base>`
# would re-apply commits the parent already has and conflict. sync must instead
# fast-forward it to the parent -- never enter a rebase.
section "sync fast-forwards a branch fully merged into its parent"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
# Fold feat-a into main (fast-forward), then advance main so feat-a is a strict
# ancestor of main with no commits of its own above it.
setup("git checkout -q main")
setup("git merge -q --ff-only feat-a")
commit("m.txt", "m1")
setup("git checkout -q feat-a")
run("sync")
show("feat-a behind main", "git rev-list --count feat-a..main")
show("feat-a commits above main", "git rev-list --count main..feat-a")
show("feat-a stackBase == main tip",
     'test "$(git config --get branch.feat-a.stackBase)" = "$(git rev-parse main)" && echo yes || echo no')
show("HEAD", "git branch --show-current")

# A branch that predates stackBase (its config has stackParent but no stackBase)
# must still restack correctly: `restack` falls back to the live merge-base of
# the branch and its parent, then re-records the base.
section "restack falls back to merge-base when stackBase is unrecorded"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
setup("git config --unset branch.feat-b.stackBase") # simulate a pre-stackBase branch
# advance feat-a so feat-b falls behind and a real restack happens
setup("git checkout -q feat-a"); commit("a2.txt", "a2")
setup("git checkout -q feat-b")
run("restack")
show("feat-b behind feat-a", "git rev-list --count feat-b..feat-a")
show("feat-b commits above feat-a", "git rev-list --count feat-a..feat-b")
puts "feat-b contains a2: #{`cd #{$repo} && git log --oneline feat-b | grep -c ' a2$' || true`.strip}"
puts "feat-b contains b1: #{`cd #{$repo} && git log --oneline feat-b | grep -c ' b1$' || true`.strip}"
show("feat-b stackBase == feat-a tip (re-recorded)",
     'test "$(git config --get branch.feat-b.stackBase)" = "$(git rev-parse feat-a)" && echo yes || echo no')

# A branch whose recorded stackBase has gone stale: git-stack only re-records the
# base when it moves the branch itself, so a manual `git rebase` (or a `git pull`)
# leaves the recorded base pointing far below the branch's real fork point. Here
# feat-b is manually rebased onto feat-a -- absorbing feat-a's `s2` commit -- while
# its stackBase stays pinned at feat-a's *original* tip. feat-a then advances with a
# conflicting `s3`. `sync` must replay only feat-b's own `b1`, not re-apply the `s2`
# that is already in feat-a: rebasing from the stale base would re-apply `s2` and
# conflict against `s3`. resolve_stack_base clamps the stale base forward to the
# live merge-base so only `b1` is replayed.
section "sync clamps a stale stackBase to the merge-base instead of re-applying parent commits"
new_repo
gsq("create feat-a"); commit("shared.txt", "s1")
gsq("create feat-b"); commit("b.txt", "b1")
# advance feat-a, then move feat-b onto it with a plain git rebase (not git-stack),
# so feat-b now contains s2 but its recorded stackBase is left at the old feat-a tip.
setup("git checkout -q feat-a"); commit("shared.txt", "s2"); commit("a.txt", "a1")
setup("git checkout -q feat-b && git rebase -q feat-a")
# advance feat-a once more with a commit that conflicts with the stale range's s2
setup("git checkout -q feat-a"); commit("shared.txt", "s3")
setup("git checkout -q feat-b")
run("sync")
show("feat-b behind feat-a", "git rev-list --count feat-b..feat-a")
show("feat-b commits above feat-a", "git rev-list --count feat-a..feat-b")
puts "feat-b contains b1: #{`cd #{$repo} && git log --oneline feat-b | grep -c ' b1$' || true`.strip}"
puts "feat-b contains s3: #{`cd #{$repo} && git log --oneline feat-b | grep -c ' s3$' || true`.strip}"
show("feat-b stackBase == feat-a tip (re-anchored)",
     'test "$(git config --get branch.feat-b.stackBase)" = "$(git rev-parse feat-a)" && echo yes || echo no')

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
