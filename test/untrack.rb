# Snapshot: untrack removes the branch's stored parent metadata.
require_relative "support/harness"

new_repo("untrack")
cmd_create(["feat-a"])
cmd_untrack([])

# The key is now unset, so git config prints nothing: the value is empty.
puts "parent.feat-a=[" + git_state("git config --get branch.feat-a.stackParent") + "]"
