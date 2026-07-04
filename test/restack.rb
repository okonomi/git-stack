# Snapshot: restack replays a descendant onto its updated parent.
require_relative "support/harness"

new_repo("restack")
cmd_create(["feat-a"]); commit("a.txt", "a1")
cmd_create(["feat-b"]); commit("b.txt", "b1")

# Add a new commit on feat-a, leaving feat-b behind.
system("git checkout -q feat-a")
commit("a2.txt", "a2")
system("git checkout -q feat-b")
cmd_restack([])

puts "on="            + git_state("git branch --show-current")
puts "feat-b-has-a2=" + git_state("git log --oneline feat-b | grep -c ' a2$'")
puts "behind="        + git_state("git rev-list --count feat-b..feat-a")
