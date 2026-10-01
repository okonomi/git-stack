# frozen_string_literal: true
#
# github mode, the other way: asking GitHub to merge a stack, and `sync` taking
# in what GitHub did to it.
# See test/support/helper.rb for how the harness works and how to regenerate the snapshot.
#
# test/support/fake-gh stands in for `gh`; a local bare repository is the
# remote, and a second clone plays GitHub rewriting branches server-side.

require_relative "support/helper"

$fake = "#{$root}/test/support/fake-gh"
ENV["GIT_STACK_GH"] = $fake

def origin
  "#{$repo}-origin.git"
end

def other
  "#{$repo}-other"
end

def fake(args)
  setup("#{$fake} --fake #{args}")
end

def gh_state
  puts gval("#{$fake} --fake state")
end

# The `gh api` calls made since the last look, then forgotten.
def gh_calls
  puts gval("cat \"$FAKE_GH/log\" 2>/dev/null; rm -f \"$FAKE_GH/log\"")
end

# main -> feat-a -> feat-b in github mode, submitted: pull requests #1 and #2 in
# GitHub stack #3.
def submitted_stack
  new_repo
  ENV["FAKE_GH"] = `mktemp -d`.strip
  setup("git init -q --bare -b main #{origin}")
  setup("git remote add origin #{origin}")
  setup("git push -q -u origin main")
  gsq("create feat-a"); commit("a.txt", "a1")
  gsq("create feat-b"); commit("b.txt", "b1")
  gsq("mode github")
  gsq("submit")
  setup("rm -f \"$FAKE_GH/log\"")
end

# What GitHub does when #1 merges: squash feat-a onto main, rebase feat-b onto
# the new main and retarget it, delete feat-a's branch.
def github_merges_bottom
  setup("git clone -q #{origin} #{other}")
  setup("(cd #{other} && git config user.email gh@example.com && git config user.name GitHub && " \
        "git merge -q --squash origin/feat-a && git commit -qm 'a1 (#1)' && git push -q origin main && " \
        "git checkout -q -b feat-b origin/feat-b && git rebase -q --onto main origin/feat-a && " \
        "git push -q -f origin feat-b && git push -q origin --delete feat-a)")
  fake("merge 1")
end

section "merge asks GitHub to merge the current branch's pull request, and returns"
submitted_stack
run("merge")
gh_calls

section "merge refuses while a branch up to here has unpushed commits"
submitted_stack
setup("git checkout -q feat-a"); commit("a2.txt", "a2")
setup("git checkout -q feat-b")
run("merge")

section "merge reports GitHub refusing it"
submitted_stack
fake("merge-status failed 'Required status check \"ci\" is failing'")
run("merge")

section "merge needs a github stack and a pull request"
submitted_stack
gsq("mode local")
run("merge")
gsq("mode github")
gsq("create feat-c"); commit("c.txt", "c1")
run("merge")

section "sync takes in a merge: drops the merged branch, follows GitHub's rebase"
submitted_stack
github_merges_bottom
run("sync")
show("feat-a parent (dropped)", "git config --get branch.feat-a.stackParent || echo none")
show("feat-a still a branch", "git rev-parse --verify --quiet refs/heads/feat-a >/dev/null && echo yes || echo no")
show("feat-b parent", "git config --get branch.feat-b.stackParent")
show("feat-b == origin/feat-b", 'test "$(git rev-parse feat-b)" = "$(git rev-parse origin/feat-b)" && echo yes || echo no')
show("feat-b stackPushed == tip", 'test "$(git config --get branch.feat-b.stackPushed)" = "$(git rev-parse feat-b)" && echo yes || echo no')
# `mode github` turned stack.trunkUpstream on, so the stack restacks onto, and
# its base is recorded at, the trunk GitHub merged into -- not the stale local main.
show("feat-b base == origin/main", 'test "$(git config --get branch.feat-b.stackBase)" = "$(git rev-parse origin/main)" && echo yes || echo no')
run("tree")

section "sync leaves a branch with unpushed commits, and the branches above it"
submitted_stack
gsq("create feat-c"); commit("c.txt", "c1")
gsq("submit")
github_merges_bottom
setup("git checkout -q feat-b"); commit("b2.txt", "b2")
run("sync")
show("feat-b behind origin/feat-b", "git rev-list --count feat-b..origin/feat-b")
show("feat-c parent", "git config --get branch.feat-c.stackParent")

section "sync moves a branch checked out in another worktree from there"
submitted_stack
github_merges_bottom
setup("git checkout -q feat-a")
setup("git worktree add -q #{$repo}-wt feat-b")
run("sync")
show("worktree HEAD == origin/feat-b", "test \"$(git -C #{$repo}-wt rev-parse HEAD)\" = \"$(git rev-parse origin/feat-b)\" && echo yes || echo no")

section "sync does not restack a github stack onto a trunk that moved"
submitted_stack
setup("git checkout -q main"); commit("m.txt", "m2")
setup("git checkout -q feat-b")
run("sync")
show("feat-a behind main", "git rev-list --count feat-a..main")
