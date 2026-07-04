#!/usr/bin/env bash
#
# Dependency-free test suite for git-stack.
# Each test runs in a throwaway git repository under a temp dir.
#
# Usage: test/run.sh

set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# Defaults to the Ruby script under CRuby; override to exercise another build:
#   GIT_STACK="$HERE/../build/bin/git-stack" test/run.sh   # spinel binary
GIT_STACK="${GIT_STACK:-ruby $HERE/../bin/git-stack.rb}"

PASS=0
FAIL=0

# assert <description> <expected> <actual>
assert() {
	local desc=$1 expected=$2 actual=$3
	if [ "$expected" = "$actual" ]; then
		PASS=$((PASS + 1))
		printf '  ok   %s\n' "$desc"
	else
		FAIL=$((FAIL + 1))
		printf '  FAIL %s\n' "$desc"
		printf '        expected: %q\n' "$expected"
		printf '        actual:   %q\n' "$actual"
	fi
}

# assert_contains <description> <needle> <haystack>
assert_contains() {
	local desc=$1 needle=$2 haystack=$3
	if [[ "$haystack" == *"$needle"* ]]; then
		PASS=$((PASS + 1))
		printf '  ok   %s\n' "$desc"
	else
		FAIL=$((FAIL + 1))
		printf '  FAIL %s\n' "$desc"
		printf '        expected to contain: %q\n' "$needle"
		printf '        in:                  %q\n' "$haystack"
	fi
}

# Create a fresh repo with a single commit on `main` and cd into it.
new_repo() {
	local dir
	dir=$(mktemp -d)
	cd "$dir" || exit 1
	git init -q -b main
	git config user.email test@example.com
	git config user.name "Test"
	git config commit.gpgsign false
	echo base > file.txt
	git add file.txt
	git commit -qm base
}

# Word-split GIT_STACK so it can carry an interpreter prefix ("ruby foo.rb").
# shellcheck disable=SC2086
gs() { $GIT_STACK "$@"; }

commit() { # commit <file> <message>
	echo "$2" > "$1"
	git add "$1"
	git commit -qm "$2"
}

export NO_COLOR=1

# --- tests ------------------------------------------------------------------

test_init_autodetect() {
	echo "test: init auto-detects main"
	new_repo
	gs init >/dev/null 2>&1
	assert "trunk stored as main" "main" "$(git config --get stack.trunk)"
}

test_create_records_parent() {
	echo "test: create records parent and checks out branch"
	new_repo
	gs create feat-a >/dev/null 2>&1
	assert "on new branch" "feat-a" "$(git branch --show-current)"
	assert "parent is main" "main" "$(git config --get branch.feat-a.stackParent)"
}

test_create_rejects_existing() {
	echo "test: create rejects an existing branch"
	new_repo
	git branch dup
	local out
	out=$(gs create dup 2>&1) && true
	assert_contains "error mentions already exists" "already exists" "$out"
}

test_tree_shows_stack() {
	echo "test: tree renders the whole stack"
	new_repo
	gs create feat-a >/dev/null 2>&1; commit a.txt a1
	gs create feat-b >/dev/null 2>&1; commit b.txt b1
	local out
	out=$(gs tree 2>&1)
	assert_contains "tree shows trunk" "main (trunk)" "$out"
	assert_contains "tree shows feat-a" "feat-a" "$out"
	assert_contains "tree shows feat-b" "feat-b" "$out"
	assert_contains "current branch marked" "* feat-b" "$out"
}

test_up_down_navigation() {
	echo "test: up/down navigate the stack"
	new_repo
	gs create feat-a >/dev/null 2>&1; commit a.txt a1
	gs create feat-b >/dev/null 2>&1; commit b.txt b1
	gs down >/dev/null 2>&1
	assert "down moves to parent" "feat-a" "$(git branch --show-current)"
	gs down >/dev/null 2>&1
	assert "down again moves to trunk" "main" "$(git branch --show-current)"
	git checkout -q feat-a
	gs up >/dev/null 2>&1
	assert "up moves to child" "feat-b" "$(git branch --show-current)"
}

test_up_ambiguous() {
	echo "test: up with multiple children requires a choice"
	new_repo
	gs create feat-a >/dev/null 2>&1; commit a.txt a1
	gs create feat-b >/dev/null 2>&1
	git checkout -q feat-a
	gs create feat-c >/dev/null 2>&1
	git checkout -q feat-a
	local out rc
	out=$(gs up 2>&1); rc=$?
	assert "up is ambiguous (non-zero exit)" "1" "$rc"
	assert_contains "lists both children" "feat-b" "$out"
	gs up feat-c >/dev/null 2>&1
	assert "up <name> disambiguates" "feat-c" "$(git branch --show-current)"
}

test_restack_propagates() {
	echo "test: restack replays descendants onto updated parent"
	new_repo
	gs create feat-a >/dev/null 2>&1; commit a.txt a1
	gs create feat-b >/dev/null 2>&1; commit b.txt b1
	# add a new commit on feat-a, leaving feat-b behind
	git checkout -q feat-a
	commit a2.txt a2
	git checkout -q feat-b
	gs restack >/dev/null 2>&1
	# feat-b must now contain the a2 commit in its history
	local has_a2
	has_a2=$(git log --oneline feat-b | grep -c ' a2$' || true)
	assert "feat-b now contains a2" "1" "$has_a2"
	# feat-b should be 0 behind feat-a
	assert "feat-b not behind feat-a" "0" "$(git rev-list --count feat-b..feat-a)"
	# ended up back on feat-b
	assert "restack restores branch" "feat-b" "$(git branch --show-current)"
}

test_restack_conflict_aborts() {
	echo "test: restack aborts cleanly on conflict"
	new_repo
	gs create feat-a >/dev/null 2>&1
	echo "from-a" > shared.txt; git add shared.txt; git commit -qm a-shared
	gs create feat-b >/dev/null 2>&1
	echo "from-b" > shared.txt; git add shared.txt; git commit -qm b-shared
	# create a conflicting change on feat-a
	git checkout -q feat-a
	echo "changed-a" > shared.txt; git add shared.txt; git commit -qm a-conflict
	git checkout -q feat-b
	local out rc
	out=$(gs restack 2>&1); rc=$?
	assert "restack fails on conflict" "1" "$rc"
	assert_contains "reports the conflict" "conflict" "$out"
	# repository must not be left mid-rebase
	assert "no rebase in progress" "0" "$(git status | grep -c 'rebase in progress' || true)"
}

test_parent_get_set() {
	echo "test: parent shows and sets the parent"
	new_repo
	gs create feat-a >/dev/null 2>&1
	gs create feat-b >/dev/null 2>&1
	assert "parent reports feat-a" "feat-a" "$(gs parent 2>/dev/null)"
	git branch other main
	gs parent other >/dev/null 2>&1
	assert "parent updated to other" "other" "$(git config --get branch.feat-b.stackParent)"
}

test_untrack() {
	echo "test: untrack removes metadata"
	new_repo
	gs create feat-a >/dev/null 2>&1
	gs untrack >/dev/null 2>&1
	assert "parent metadata removed" "" "$(git config --get branch.feat-a.stackParent || true)"
}

# --- run --------------------------------------------------------------------

for t in \
	test_init_autodetect \
	test_create_records_parent \
	test_create_rejects_existing \
	test_tree_shows_stack \
	test_up_down_navigation \
	test_up_ambiguous \
	test_restack_propagates \
	test_restack_conflict_aborts \
	test_parent_get_set \
	test_untrack
do
	"$t"
done

echo
echo "-------------------------------------"
printf 'passed: %d   failed: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
