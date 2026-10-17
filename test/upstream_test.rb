# frozen_string_literal: true
#
# stack.trunkUpstream: restacking a trunk's children onto the trunk's upstream,
# and `sync` fetching it first.
# See test/support/helper.rb for how the harness works and how to regenerate the snapshot.
#
# The remote is a bare repository beside the scenario's repo, and a second clone
# of it plays the teammate who pushes to main.

require_relative "support/helper"

def origin
  "#{$repo}-origin.git"
end

def other
  "#{$repo}-other"
end

# Give the repo an `origin` that main tracks.
def add_origin
  setup("git init -q --bare -b main #{origin}")
  setup("git remote add origin #{origin}")
  setup("git push -q -u origin main")
end

# Push a commit to origin's main from another clone, as a teammate would.
def push_from_other(file, msg)
  setup("git clone -q #{origin} #{other}")
  setup("(cd #{other} && git config user.email o@example.com && git config user.name Other && " \
        "echo #{msg} > #{file} && git add #{file} && git commit -qm #{msg} && git push -q origin main)")
end

# main pushed one commit ahead, then the local main set back: origin/main is
# ahead of main, as after a teammate's merge that was fetched but not pulled.
def advance_origin_only(file, msg)
  setup("git checkout -q main")
  commit(file, msg)
  # Spelled out: with a tag named `main`, a bare `main` refspec is ambiguous.
  setup("git push -q origin refs/heads/main:refs/heads/main")
  setup("git reset -q --hard HEAD~1")
end

section "without stack.trunkUpstream, restack stays on the local trunk"
new_repo
add_origin
gsq("create feat-a"); commit("a.txt", "a1")
advance_origin_only("m.txt", "m2")
setup("git checkout -q feat-a")
run("restack")
show("feat-a behind origin/main", "git rev-list --count feat-a..origin/main")

section "with stack.trunkUpstream, restack replays a trunk child onto origin/main"
new_repo
add_origin
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
advance_origin_only("m.txt", "m2")
setup("git config stack.trunkUpstream true")
setup("git checkout -q feat-b")
run("restack")
show("feat-a behind origin/main", "git rev-list --count feat-a..origin/main")
show("feat-b behind feat-a", "git rev-list --count feat-b..feat-a")
show("feat-a base == origin/main", 'test "$(git config --get branch.feat-a.stackBase)" = "$(git rev-parse origin/main)" && echo yes || echo no')
show("feat-a parent (still the trunk's name)", "git config --get branch.feat-a.stackParent")
show("local main behind origin/main (untouched)", "git rev-list --count main..origin/main")

section "tree measures a trunk child against the upstream and says so on the trunk"
new_repo
add_origin
gsq("create feat-a"); commit("a.txt", "a1")
advance_origin_only("m.txt", "m2")
setup("git config stack.trunkUpstream true")
setup("git checkout -q feat-a")
run("tree")

section "a trunk child with no commits is fast-forwarded to the upstream"
new_repo
add_origin
gsq("create feat-a")
advance_origin_only("m.txt", "m2")
setup("git config stack.trunkUpstream true")
setup("git checkout -q feat-a")
run("restack")
show("feat-a == origin/main", 'test "$(git rev-parse feat-a)" = "$(git rev-parse origin/main)" && echo yes || echo no')

section "sync fetches the trunk's remote first"
new_repo
add_origin
gsq("create feat-a"); commit("a.txt", "a1")
setup("git config stack.trunkUpstream true")
push_from_other("o.txt", "o1")
run("sync")
show("feat-a contains o1", "git log --oneline feat-a | grep -c ' o1$'")
show("local main has o1 (untouched)", "git log --oneline main | grep -c ' o1$' || true")

section "sync without stack.trunkUpstream does not fetch"
new_repo
add_origin
gsq("create feat-a"); commit("a.txt", "a1")
push_from_other("o.txt", "o1")
run("sync")
show("origin/main has o1", "git log --oneline origin/main | grep -c ' o1$' || true")

section "restack does not fetch, even with stack.trunkUpstream"
new_repo
add_origin
gsq("create feat-a"); commit("a.txt", "a1")
setup("git config stack.trunkUpstream true")
push_from_other("o.txt", "o1")
run("restack")
show("origin/main has o1", "git log --oneline origin/main | grep -c ' o1$' || true")

section "a failed fetch warns and restacks onto what was fetched last"
new_repo
add_origin
gsq("create feat-a"); commit("a.txt", "a1")
advance_origin_only("m.txt", "m2")
setup("git config stack.trunkUpstream true")
setup("git remote set-url origin #{$repo}-no-such-remote.git")
setup("git checkout -q feat-a")
run("sync")
show("feat-a behind origin/main", "git rev-list --count feat-a..origin/main")

section "a trunk with no upstream keeps the local branch"
new_repo
gsq("create feat-a"); commit("a.txt", "a1")
setup("git checkout -q main"); commit("m.txt", "m2")
setup("git config stack.trunkUpstream true")
setup("git checkout -q feat-a")
run("sync")
show("feat-a behind main", "git rev-list --count feat-a..main")
run("tree")

section "an upstream that was never fetched falls back to the local branch"
new_repo
add_origin
gsq("create feat-a"); commit("a.txt", "a1")
setup("git config branch.main.merge refs/heads/not-fetched")
setup("git config stack.trunkUpstream true")
run("restack")

section "drop reconnects children onto the trunk's upstream"
new_repo
add_origin
gsq("create feat-a"); commit("a.txt", "a1")
gsq("create feat-b"); commit("b.txt", "b1")
advance_origin_only("m.txt", "m2")
setup("git config stack.trunkUpstream true")
run("drop feat-a")
show("feat-b parent", "git config --get branch.feat-b.stackParent")
show("feat-b behind origin/main", "git rev-list --count feat-b..origin/main")

section "a trunk named like a tag still resolves its own upstream"
new_repo
add_origin
setup("git tag main")
gsq("create feat-a"); commit("a.txt", "a1")
advance_origin_only("m.txt", "m2")
setup("git config stack.trunkUpstream true")
setup("git checkout -q feat-a")
run("restack")
show("feat-a behind origin/main", "git rev-list --count feat-a..origin/main")

section "a value git cannot read as a boolean is refused"
new_repo
gsq("create feat-a")
setup("git config stack.trunkUpstream maybe")
run("restack")

section "stack.defaultSync github reads an unset stack.trunkUpstream as true"
new_repo
add_origin
gsq("create feat-a"); commit("a.txt", "a1")
setup("git config stack.defaultSync github")
run("tree")
setup("git config stack.trunkUpstream false")
run("tree")
