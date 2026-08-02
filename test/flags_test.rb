# frozen_string_literal: true
#
# version, the global flags, and the arity/flag checks every command shares.
# See test/support/helper.rb for how the harness works and how to regenerate the snapshot.

require_relative "support/helper"

section "version shows the program version"
new_repo
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
# was (see drop_test.rb's "drop --delete removes the branch ref after
# splicing" section) (issue #83).
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
