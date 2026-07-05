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

section "version shows the program version"
run("version")

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
