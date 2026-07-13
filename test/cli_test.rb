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

section "init records multiple trunks and lists them"
new_repo
setup("git branch develop main")
run("init main develop")
show("stack.trunk", "git config --get-all stack.trunk")
run("init")

section "init rejects a non-existent trunk"
new_repo
run("init nope")

section "tree renders each trunk as its own root"
new_repo
setup("git branch develop main")
gsq("init main develop")
setup("git checkout -q main")
gsq("create feat-a"); commit("a.txt", "a1")
setup("git checkout -q develop")
gsq("create feat-d"); commit("d.txt", "d1")
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

section "version shows the program version"
run("version")

section "global flags are parsed with optparse"
run("-v")
run("--version")
run("-h")

section "an unknown flag is rejected"
run("--bogus")

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
