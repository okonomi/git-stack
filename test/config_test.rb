# frozen_string_literal: true
#
# config writes: waiting out a config lock another git holds, and giving up on
# one left behind.
# See test/support/helper.rb for how the harness works and how to regenerate the snapshot.

require_relative "support/helper"

section "a config lock left behind is reported, not removed"
new_repo
gsq("init")
setup("touch .git/config.lock")
run("create feat-a")
show("lock still there", "test -e .git/config.lock && echo yes || echo no")

section "a config lock released during the retries is waited out"
new_repo
gsq("init")
setup("touch .git/config.lock")
setup("(sleep 0.3; rm -f .git/config.lock) &")
run("create feat-a")
show("feat-a parent", "git config --get branch.feat-a.stackParent")
show("feat-a base == main", 'test "$(git config --get branch.feat-a.stackBase)" = "$(git rev-parse main)" && echo yes || echo no')

section "a failed unset is not mistaken for the lock"
new_repo
gsq("create feat-a")
gsq("untrack")
# Both keys are gone now, so both unsets fail; neither may wait or die.
run("untrack")
