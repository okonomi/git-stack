# frozen_string_literal: true
#
# Snapshot test program for git-stack, run by `spin test`.
#
# `spin test` compiles this file with Spinel and diffs its stdout against the
# committed snapshot in `test/cli_test.rb.expected` (regenerate that snapshot
# from CRuby with `spin test --regen`). A non-zero exit or any diff fails the
# test, so every check prints a stable `ok`/`FAIL` line and we exit non-zero if
# anything failed.
#
# It also runs unchanged under CRuby, so you can drive it without Spinel:
#
#     ruby test/cli_test.rb
#
# Each test runs in a throwaway git repository under a temp dir. git-stack is
# exercised as a black box; by default we run the Ruby script under CRuby, but
# point GIT_STACK at another build to test that one instead:
#
#     GIT_STACK="$PWD/build/bin/git-stack" ruby test/cli_test.rb   # spinel binary
#
# This is written in the same Spinel-accepted subset of Ruby as bin/git-stack.rb
# (shelling out via backticks and `system` rather than using File/Dir/tmpdir).

# The repo root is the directory we are launched from (`spin test` and
# `ruby test/cli_test.rb` both run from the project root). We capture it up
# front because each test cd's into a throwaway repo before invoking git-stack.
$root = `pwd`.strip

$gs = ENV["GIT_STACK"]
$gs = "ruby #{$root}/bin/git-stack.rb" if $gs.nil? || $gs == ""
# Disable colour so the tree/error output is stable regardless of the terminal.
$gs = "NO_COLOR=1 #{$gs}"

$repo = ""
$rc = "0"
$pass = 0
$fail = 0

# --- assertions -------------------------------------------------------------

# assert <description> <expected> <actual>
def assert(desc, expected, actual)
  if expected == actual
    $pass = $pass + 1
    puts "  ok   #{desc}"
  else
    $fail = $fail + 1
    puts "  FAIL #{desc}"
    puts "        expected: #{expected}"
    puts "        actual:   #{actual}"
  end
end

# assert_contains <description> <needle> <haystack>
def assert_contains(desc, needle, haystack)
  if !haystack.index(needle).nil?
    $pass = $pass + 1
    puts "  ok   #{desc}"
  else
    $fail = $fail + 1
    puts "  FAIL #{desc}"
    puts "        expected to contain: #{needle}"
    puts "        in:                  #{haystack}"
  end
end

# --- repo / command helpers -------------------------------------------------

# Run a shell command inside the current throwaway repo, discarding output.
def setup(cmd)
  system("cd #{$repo} && #{cmd} >/dev/null 2>&1")
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

# Run git-stack, capturing combined stdout+stderr and recording the exit code
# (as "0" or "1") in $rc.
def gs(args)
  out = `cd #{$repo} && #{$gs} #{args} 2>&1`
  $rc = ($? == 0) ? "0" : "1"
  out
end

# Run git-stack, discarding its output (for commands whose effect we assert on).
def gsq(args)
  setup("#{$gs} #{args}")
end

# Capture the trimmed stdout of a command run inside the repo.
def gval(cmd)
  `cd #{$repo} && #{cmd} 2>/dev/null`.strip
end

# --- tests ------------------------------------------------------------------

def test_init_autodetect
  puts "test: init auto-detects main"
  new_repo
  gsq("init")
  assert("trunk stored as main", "main", gval("git config --get stack.trunk"))
end

def test_create_records_parent
  puts "test: create records parent and checks out branch"
  new_repo
  gsq("create feat-a")
  assert("on new branch", "feat-a", gval("git branch --show-current"))
  assert("parent is main", "main", gval("git config --get branch.feat-a.stackParent"))
end

def test_create_rejects_existing
  puts "test: create rejects an existing branch"
  new_repo
  setup("git branch dup")
  out = gs("create dup")
  assert_contains("error mentions already exists", "already exists", out)
end

def test_tree_shows_stack
  puts "test: tree renders the whole stack"
  new_repo
  gsq("create feat-a"); commit("a.txt", "a1")
  gsq("create feat-b"); commit("b.txt", "b1")
  out = gs("tree")
  assert_contains("tree shows trunk", "main (trunk)", out)
  assert_contains("tree shows feat-a", "feat-a", out)
  assert_contains("tree shows feat-b", "feat-b", out)
  assert_contains("current branch marked", "* feat-b", out)
end

def test_up_down_navigation
  puts "test: up/down navigate the stack"
  new_repo
  gsq("create feat-a"); commit("a.txt", "a1")
  gsq("create feat-b"); commit("b.txt", "b1")
  gsq("down")
  assert("down moves to parent", "feat-a", gval("git branch --show-current"))
  gsq("down")
  assert("down again moves to trunk", "main", gval("git branch --show-current"))
  setup("git checkout -q feat-a")
  gsq("up")
  assert("up moves to child", "feat-b", gval("git branch --show-current"))
end

def test_up_ambiguous
  puts "test: up with multiple children requires a choice"
  new_repo
  gsq("create feat-a"); commit("a.txt", "a1")
  gsq("create feat-b")
  setup("git checkout -q feat-a")
  gsq("create feat-c")
  setup("git checkout -q feat-a")
  out = gs("up")
  assert("up is ambiguous (non-zero exit)", "1", $rc)
  assert_contains("lists both children", "feat-b", out)
  gsq("up feat-c")
  assert("up <name> disambiguates", "feat-c", gval("git branch --show-current"))
end

def test_restack_propagates
  puts "test: restack replays descendants onto updated parent"
  new_repo
  gsq("create feat-a"); commit("a.txt", "a1")
  gsq("create feat-b"); commit("b.txt", "b1")
  # add a new commit on feat-a, leaving feat-b behind
  setup("git checkout -q feat-a")
  commit("a2.txt", "a2")
  setup("git checkout -q feat-b")
  gsq("restack")
  # feat-b must now contain the a2 commit in its history
  has_a2 = `cd #{$repo} && git log --oneline feat-b | grep -c ' a2$' || true`.strip
  assert("feat-b now contains a2", "1", has_a2)
  # feat-b should be 0 behind feat-a
  assert("feat-b not behind feat-a", "0", gval("git rev-list --count feat-b..feat-a"))
  # ended up back on feat-b
  assert("restack restores branch", "feat-b", gval("git branch --show-current"))
end

def test_restack_conflict_aborts
  puts "test: restack aborts cleanly on conflict"
  new_repo
  gsq("create feat-a")
  setup("echo from-a > shared.txt && git add shared.txt && git commit -qm a-shared")
  gsq("create feat-b")
  setup("echo from-b > shared.txt && git add shared.txt && git commit -qm b-shared")
  # create a conflicting change on feat-a
  setup("git checkout -q feat-a")
  setup("echo changed-a > shared.txt && git add shared.txt && git commit -qm a-conflict")
  setup("git checkout -q feat-b")
  out = gs("restack")
  assert("restack fails on conflict", "1", $rc)
  assert_contains("reports the conflict", "conflict", out)
  # repository must not be left mid-rebase
  norebase = `cd #{$repo} && git status | grep -c 'rebase in progress' || true`.strip
  assert("no rebase in progress", "0", norebase)
end

def test_parent_get_set
  puts "test: parent shows and sets the parent"
  new_repo
  gsq("create feat-a")
  gsq("create feat-b")
  assert("parent reports feat-a", "feat-a", gs("parent").strip)
  setup("git branch other main")
  gsq("parent other")
  assert("parent updated to other", "other", gval("git config --get branch.feat-b.stackParent"))
end

def test_untrack
  puts "test: untrack removes metadata"
  new_repo
  gsq("create feat-a")
  gsq("untrack")
  assert("parent metadata removed", "", gval("git config --get branch.feat-a.stackParent"))
end

# --- run --------------------------------------------------------------------

test_init_autodetect
test_create_records_parent
test_create_rejects_existing
test_tree_shows_stack
test_up_down_navigation
test_up_ambiguous
test_restack_propagates
test_restack_conflict_aborts
test_parent_get_set
test_untrack

puts ""
puts "-------------------------------------"
puts "passed: #{$pass}   failed: #{$fail}"

exit 1 if $fail > 0
