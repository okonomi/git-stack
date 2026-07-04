# Snapshot: parent with no argument prints the current parent; with an
# argument it re-points the branch at a new parent.
require_relative "support/harness"

new_repo("parent_track")
cmd_create(["feat-a"])
cmd_create(["feat-b"])

puts "--- parent (reads feat-a) ---"
cmd_parent([])

system("git branch other main")
cmd_parent(["other"])
puts "parent.feat-b=" + git_state("git config --get branch.feat-b.stackParent")
