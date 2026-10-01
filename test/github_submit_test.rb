# frozen_string_literal: true
#
# github mode, submit side: opening a pull request per branch and keeping them
# in one GitHub stack.
# See test/support/helper.rb for how the harness works and how to regenerate the snapshot.
#
# test/support/fake-gh stands in for `gh`, holding pull requests and stacks as
# files; `gh_state` prints them. A local bare repository is the remote.

require_relative "support/helper"

$fake = "#{$root}/test/support/fake-gh"
ENV["GIT_STACK_GH"] = $fake

# A fresh repo with a remote, and a fresh fake GitHub behind it.
def github_repo
  new_repo
  ENV["FAKE_GH"] = `mktemp -d`.strip
  setup("git init -q --bare -b main #{$repo}-origin.git")
  setup("git remote add origin #{$repo}-origin.git")
  setup("git push -q -u origin main")
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

# main -> feat-a -> feat-b in github mode.
def github_stack
  github_repo
  gsq("create feat-a"); commit("a.txt", "a1")
  gsq("create feat-b"); commit("b.txt", "b1")
  setup("echo b2 > b2.txt && git add b2.txt && git commit -qm b2")
  gsq("mode github")
end

section "submit opens a pull request per branch, bottom first, and stacks them"
github_stack
run("submit")
gh_state

section "a second submit finds the pull requests and the stack"
github_stack
gsq("submit")
setup("git checkout -q feat-a"); commit("a2.txt", "a2")
gsq("restack")
gh_calls
run("submit")
gh_calls
gh_state

section "submit extends the stack with a new branch on top"
github_stack
gsq("submit")
setup("git checkout -q feat-b")
gsq("create feat-c"); commit("c.txt", "c1")
run("submit")
gh_state

section "submit retargets a pull request whose base is not its parent"
github_stack
fake("pr feat-b main")
run("submit")
gh_state

section "a pull request's body leaves out the commit's trailers"
github_repo
gsq("create feat-a")
setup("printf 'Add a.txt\n\nWhy it is needed.\n\nCo-Authored-By: Someone <someone@example.com>\nSigned-off-by: Test <test@example.com>\n' > .git/msg && " \
      "echo a1 > a.txt && git add a.txt && git commit -q -F .git/msg")
gsq("create feat-b")
setup("echo b1 > b.txt && git add b.txt && git commit -q -m 'Add b.txt' -m 'Refs: not a trailer block' -m 'Closing words.'")
gsq("mode github")
run("submit")
gh_state

section "submit leaves a GitHub stack that does not match, and says so"
github_stack
fake("pr feat-a main")
fake("pr feat-b feat-a")
fake("pr feat-x feat-a")
setup("#{$fake} api -X POST 'repos/{owner}/{repo}/stacks' -F 'pull_requests[]=1' -F 'pull_requests[]=3'")
run("submit")
gh_state

section "a branch with no commits cannot become a pull request"
github_repo
gsq("create feat-a")
gsq("mode github")
run("submit")
show("feat-a on origin", "git --git-dir=#{$repo}-origin.git rev-parse --verify --quiet refs/heads/feat-a || echo none")

section "a failing gh call stops submit with gh's message"
github_stack
fake("fail 'POST repos/{owner}/{repo}/stacks'")
run("submit")
gh_state

section "local mode submit never calls gh"
github_repo
gsq("create feat-a"); commit("a.txt", "a1")
run("submit")
gh_calls

section "mode github stacks the pull requests that already exist"
github_repo
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
gsq("create feat-c"); commit("c.txt", "c1")
fake("pr feat-a main")
fake("pr feat-b feat-a")
run("mode github")
gh_state
