# Snapshot: init auto-detects the trunk, create records each parent and checks
# out the new branch, and tree renders the whole stack with commit counts.
#
# git-stack's own progress lines (on stderr) are part of the captured snapshot.
require_relative "support/harness"

new_repo("create_and_tree")
cmd_init([])
cmd_create(["feat-a"]); commit("a.txt", "a1")
cmd_create(["feat-b"]); commit("b.txt", "b1")

puts "trunk="          + git_state("git config --get stack.trunk")
puts "on="             + git_state("git branch --show-current")
puts "parent.feat-a="  + git_state("git config --get branch.feat-a.stackParent")
puts "parent.feat-b="  + git_state("git config --get branch.feat-b.stackParent")
puts "--- tree ---"
cmd_tree([])
