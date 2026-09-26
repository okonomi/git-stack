# frozen_string_literal: true
#
# Harness shared by the snapshot tests in test/*_test.rb. Under test/support/ so
# that neither `spin test`'s `test/*.rb` glob nor CI's `test/*_test.rb` picks it
# up as a test.
#
# Each test file drives git-stack through scenarios in throwaway repositories and
# prints a transcript of every command's output and exit status. `spin test`
# diffs it against the committed `test/<name>_test.rb.expected`; the snapshot is
# the only oracle. After an intentional behaviour change, regenerate it:
#
#     spin test --regen
#     ruby test/sync_test.rb > test/sync_test.rb.expected   # one file, CRuby only
#
# GIT_STACK points the tests at another build (default: bin/git-stack.rb under
# CRuby):
#
#     GIT_STACK="$PWD/build/bin/git-stack" ruby test/sync_test.rb
#
# Written in the same Spinel subset as bin/git-stack.rb: backticks and `system`,
# no File/Dir/tmpdir.

# Captured up front, because each scenario cd's into its own repo.
$root = `pwd`.strip

# Fixed dates so commits hash reproducibly: the conflict message prints a base
# SHA, and the CRuby and Spinel runs must match byte for byte. `system` passes
# this environment on to every git commit below.
ENV["GIT_AUTHOR_DATE"] = "2001-02-03T04:05:06 +0000"
ENV["GIT_COMMITTER_DATE"] = "2001-02-03T04:05:06 +0000"

$gs = ENV["GIT_STACK"]
$gs = "ruby #{$root}/bin/git-stack.rb" if $gs.nil? || $gs == ""
# The transcript must not depend on the terminal.
$gs = "NO_COLOR=1 #{$gs}"

$repo = ""

# --- helpers ----------------------------------------------------------------

def section(title)
  puts ""
  puts "### #{title}"
end

# Run a shell command in the current repo, discarding output: state a later
# git-stack command reveals.
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

