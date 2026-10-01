# frozen_string_literal: true
#
# mode: a stack's sync-mode (local or github), where it is recorded, and what
# github mode refuses.
# See test/support/helper.rb for how the harness works and how to regenerate the snapshot.
#
# Nothing here talks to GitHub. GIT_STACK_GH stands in for `gh`: `true` answers
# `gh --version` as an installed gh would.

require_relative "support/helper"

ENV["GIT_STACK_GH"] = "true"

def add_origin
  setup("git init -q --bare -b main #{$repo}-origin.git")
  setup("git remote add origin #{$repo}-origin.git")
end

# main -> feat-a -> feat-b, with a remote.
def linear_repo
  new_repo
  add_origin
  gsq("create feat-a"); commit("a.txt", "a1")
  gsq("create feat-b"); commit("b.txt", "b1")
end

section "mode with no argument shows the current stack's mode"
linear_repo
run("mode")
setup("git config stack.defaultSync github")
run("mode")
setup("git config branch.feat-b.stackSync local")
run("mode")

section "mode github records the mode on every branch of the stack"
linear_repo
setup("git checkout -q main")
gsq("create other"); commit("o.txt", "o1")
setup("git checkout -q feat-a")
run("mode github")
show("feat-a stackSync", "git config --get branch.feat-a.stackSync")
show("feat-b stackSync", "git config --get branch.feat-b.stackSync")
show("other stackSync (other stack)", "git config --get branch.other.stackSync || echo none")
run("tree")

section "mode local switches back"
linear_repo
gsq("mode github")
run("mode local")
show("feat-a stackSync", "git config --get branch.feat-a.stackSync")
run("tree")

section "create inherits the mode"
linear_repo
gsq("mode github")
run("create feat-c")
show("feat-c stackSync", "git config --get branch.feat-c.stackSync")

section "a branching stack cannot be github"
linear_repo
setup("git checkout -q feat-a")
gsq("create feat-x")
run("mode github")
show("feat-a stackSync", "git config --get branch.feat-a.stackSync || echo none")

section "a github stack refuses a branch"
linear_repo
gsq("mode github")
setup("git checkout -q feat-a")
run("create feat-x")
setup("git checkout -q -b loose main")
run("track feat-a")
run("parent feat-a")
setup("git checkout -q feat-b")
run("create feat-c")

section "github needs a remote"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
run("mode github")

section "github needs gh"
linear_repo
setup("git checkout -q feat-a")
ENV["GIT_STACK_GH"] = "/nonexistent/gh"
run("mode github")
ENV["GIT_STACK_GH"] = "true"

section "mode runs from a branch of a stack, and takes local or github"
linear_repo
setup("git checkout -q main")
run("mode")
setup("git checkout -q feat-a")
run("mode gitlab")
setup("git config branch.feat-a.stackSync gitlab")
run("mode")

section "a branch that leaves its stack leaves its mode"
linear_repo
gsq("mode github")
run("drop feat-a")
show("feat-a stackSync", "git config --get branch.feat-a.stackSync || echo none")
show("feat-b stackSync", "git config --get branch.feat-b.stackSync")
