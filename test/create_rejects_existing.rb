# Snapshot: create refuses to clobber a branch that already exists.
#
# The first create succeeds (its progress line is captured); the second is the
# last action -- it prints an error to stderr and exits non-zero. `spin test`
# merges stderr into the captured output and ignores the exit status, so both
# lines are pinned by the snapshot.
require_relative "support/harness"

new_repo("create_rejects_existing")
cmd_create(["feat-a"])
cmd_create(["feat-a"])
