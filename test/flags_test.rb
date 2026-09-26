# frozen_string_literal: true
#
# version, the global flags, and the arity/flag checks every command shares.
# See test/support/helper.rb for how the harness works and how to regenerate the snapshot.

require_relative "support/helper"

section "version shows the program version"
new_repo
run("version")

# No `new_repo` here or in the next section: both run in the repo built above,
# so reordering sections, or inserting one between, changes the repo they use.
section "global flags are parsed with optparse"
run("-v")
run("--version")
run("-h")

section "an unknown flag is rejected"
run("--bogus")

# Arity and command-level flags are one rule, checked before the repo is
# touched -- the last two shows prove nothing was created or moved. `--delete`
# is lifted out of argv before the command is known, so without an owner check
# every command accepted it (#83).
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

# An empty argument names no branch, so counting it would reject command lines
# the commands handle; `git stack down "$maybe_unset"` is the ordinary way in.
section "an empty argument is not counted as a positional"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
run("tree ''")
run("drop '' feat-a")
show("feat-b stackParent", "git config --get branch.feat-b.stackParent")
