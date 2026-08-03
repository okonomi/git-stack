# frozen_string_literal: true
#
# Harness shared by the snapshot tests in test/*_test.rb, run by `spin test`.
# It lives under test/support/, not test/, so both globs skip it: `spin
# test`'s `test/*.rb` glob and CI's `test/*_test.rb` glob (ci.yml) are
# different patterns, but both non-recursive. It is not itself a test file.
#
# Each test file is a real snapshot test: it drives git-stack through a series
# of scenarios in throwaway git repositories and prints a transcript of
# exactly what each command emits (stdout+stderr) plus its exit status.
# `spin test` compiles each `test/*_test.rb` file with Spinel, runs it, and
# diffs its stdout against the committed snapshot beside it
# (`test/<name>_test.rb.expected`). Any difference -- a changed message, a new
# line, a different exit code -- fails the test.
#
# There are no hand-written expected values here; the snapshot IS the oracle.
# After an intentional behaviour change, refresh it from CRuby with:
#
#     spin test --regen
#
# Each test file also runs unchanged under CRuby, so you can regenerate/inspect
# without Spinel:
#
#     ruby test/sync_test.rb                              # print one transcript
#     ruby test/sync_test.rb > test/sync_test.rb.expected # regenerate that one
#
# By default each test file drives the Ruby script under CRuby; point GIT_STACK
# at another build to snapshot that one instead:
#
#     GIT_STACK="$PWD/build/bin/git-stack" ruby test/sync_test.rb   # spinel binary
#
# This harness and every test file are written in the same Spinel-accepted
# subset of Ruby as bin/git-stack.rb (shelling out via backticks and `system`,
# no File/Dir/tmpdir).

# The repo root is the directory we are launched from (`spin test` and
# `ruby test/<name>_test.rb` both run from the project root). We capture it up
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

