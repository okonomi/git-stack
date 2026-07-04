# Snapshot: down walks to the parent (then the trunk); up walks to a child.
require_relative "support/harness"

new_repo("up_down")
cmd_create(["feat-a"]); commit("a.txt", "a1")
cmd_create(["feat-b"]); commit("b.txt", "b1")

cmd_down([])
puts "after-down="  + git_state("git branch --show-current")

cmd_down([])
puts "after-down2=" + git_state("git branch --show-current")

system("git checkout -q feat-a")
cmd_up(["feat-b"])
puts "after-up="    + git_state("git branch --show-current")
