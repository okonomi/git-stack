# frozen_string_literal: true
#
# init: detecting the trunk, and validating the trunks it is handed.
# See test/support/helper.rb for how the harness works and how to regenerate the snapshot.

require_relative "support/helper"

section "init auto-detects the trunk"
new_repo
run("init")
show("stack.trunk", "git config --get stack.trunk")

# `origin/HEAD` is a symbolic ref like any other, so the sections below point it at a
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
