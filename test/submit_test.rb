# frozen_string_literal: true
#
# submit: pushing the current stack, guarded by --force-with-lease.
# See test/support/helper.rb for how the harness works and how to regenerate the snapshot.
#
# The remote is a bare repository beside the scenario's repo, and a second clone
# of it plays the teammate who pushes to the same branches.

require_relative "support/helper"

def origin
  "#{$repo}-origin.git"
end

def other
  "#{$repo}-other"
end

def add_origin
  setup("git init -q --bare -b main #{origin}")
  setup("git remote add origin #{origin}")
  setup("git push -q -u origin main")
end

# A teammate's commit on `branch`, pushed to origin.
def push_from_other(branch, file, msg)
  setup("rm -rf #{other} && git clone -q #{origin} #{other}")
  setup("(cd #{other} && git config user.email o@example.com && git config user.name Other && " \
        "git checkout -q #{branch} && echo #{msg} > #{file} && git add #{file} && " \
        "git commit -qm #{msg} && git push -q origin #{branch})")
end

def remote_tip(branch)
  "git --git-dir=#{origin} rev-parse --verify --quiet refs/heads/#{branch} || echo none"
end

def same_as_remote(branch)
  "test \"$(git rev-parse #{branch})\" = \"$(#{remote_tip(branch)})\" && echo yes || echo no"
end

# main -> feat-a -> feat-b, plus a sibling stack `other-x`, all committed.
def stack_repo
  new_repo
  add_origin
  gsq("create feat-a"); commit("a.txt", "a1")
  gsq("create feat-b"); commit("b.txt", "b1")
  setup("git checkout -q main")
  gsq("create other-x"); commit("x.txt", "x1")
  setup("git checkout -q feat-b")
end

section "submit pushes every branch of the current stack, parents first"
stack_repo
run("submit")
show("feat-a on origin", same_as_remote("feat-a"))
show("feat-b on origin", same_as_remote("feat-b"))
show("other-x on origin (other stack)", remote_tip("other-x"))
show("feat-b upstream", "git rev-parse --abbrev-ref feat-b@{upstream}")
show("feat-a stackPushed == tip", 'test "$(git config --get branch.feat-a.stackPushed)" = "$(git rev-parse feat-a)" && echo yes || echo no')
show("HEAD", "git branch --show-current")

section "submit force-pushes over its own last push"
stack_repo
gsq("submit")
setup("git checkout -q feat-a")
setup("echo a2 > a.txt && git commit -qa --amend -m a1-amended")
gsq("restack")
run("submit")
show("feat-a on origin", same_as_remote("feat-a"))
show("feat-b on origin", same_as_remote("feat-b"))

section "submit refuses to overwrite a branch someone else pushed to"
stack_repo
gsq("submit")
push_from_other("feat-a", "t.txt", "theirs")
setup("git checkout -q feat-a")
setup("echo a2 > a.txt && git commit -qa --amend -m a1-amended")
gsq("restack")
run("submit")
show("origin feat-a has their commit", "git --git-dir=#{origin} log --oneline feat-a | grep -c ' theirs$'")
show("feat-b on origin", same_as_remote("feat-b"))

section "a branch pushed outside git-stack leases against its remote-tracking ref"
stack_repo
setup("git push -q -u origin feat-a")
setup("git checkout -q feat-a")
setup("echo a2 > a.txt && git commit -qa --amend -m a1-amended")
run("submit")
show("feat-a on origin", same_as_remote("feat-a"))

section "an unrecorded branch whose remote moved since the last fetch is not pushed"
stack_repo
setup("git push -q -u origin feat-a")
push_from_other("feat-a", "t.txt", "theirs")
setup("git checkout -q feat-a")
setup("echo a2 > a.txt && git commit -qa --amend -m a1-amended")
run("submit")
show("origin feat-a has their commit", "git --git-dir=#{origin} log --oneline feat-a | grep -c ' theirs$'")

section "an unrecorded branch is not pushed over commits fetched but not integrated"
stack_repo
setup("git push -q -u origin feat-a")
push_from_other("feat-a", "t.txt", "theirs")
setup("git fetch -q origin")
setup("git checkout -q feat-a")
setup("echo a2 > a.txt && git commit -qa --amend -m a1-amended")
run("submit")
show("origin feat-a has their commit", "git --git-dir=#{origin} log --oneline feat-a | grep -c ' theirs$'")

section "submit pushes to remote.pushDefault when it is set"
stack_repo
setup("git init -q --bare -b main #{$repo}-fork.git")
setup("git remote add fork #{$repo}-fork.git")
setup("git config remote.pushDefault fork")
setup("git checkout -q feat-a")
run("submit")
show("feat-a on fork", 'test "$(git rev-parse feat-a)" = "$(git --git-dir=' + "#{$repo}-fork.git" + ' rev-parse feat-a)" && echo yes || echo no')
show("feat-a on origin", remote_tip("feat-a"))

section "submit needs a remote"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
run("submit")

section "submit runs from a branch of a stack, not a trunk or an anchor"
new_repo
add_origin
setup("git branch wt-x")
gsq("anchor wt-x")
run("submit")
setup("git checkout -q wt-x")
run("submit")
