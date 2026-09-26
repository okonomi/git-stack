# frozen_string_literal: true
#
# init: detecting the trunk, and validating the trunks it is handed.
# See test/support/helper.rb for how the harness works and how to regenerate the snapshot.

require_relative "support/helper"

section "init auto-detects the trunk"
new_repo
run("init")
show("stack.trunk", "git config --get stack.trunk")

# From here on, `origin/HEAD` points at a remote-tracking ref directly rather
# than a clone: detection reads only that symref, and a real remote would put a
# second repo's path into the snapshot.

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

# Nothing looks wrong when this breaks: the remote's answer is discarded and
# detection falls through to main, as if there were no `origin/HEAD` at all.
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

# A failed `init` writes nothing; the second show is the list surviving (#83).
section "init rejects a duplicate trunk name"
new_repo
setup("git branch develop main")
gsq("init main develop")
run("init main develop main")
show("stack.trunk (unchanged)", "git config --get-all stack.trunk | tr '\\n' ' '")
