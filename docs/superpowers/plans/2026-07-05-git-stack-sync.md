# git stack sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `git stack sync` command that reparents branches whose parent
was deleted (merged-and-deleted workflow) onto trunk and restacks them, and
fix `git stack tree` so it no longer silently hides those orphaned branches.

**Architecture:** `restack_subtree` (the recursive rebase walker already used
by `git stack restack`) gains a `heal_orphans` flag. When true, it reparents
onto trunk any branch whose recorded parent no longer exists, before doing
its normal rebase-if-behind check. `cmd_restack` calls it with
`heal_orphans: false` (unchanged behavior); a new `cmd_sync` calls it with
`heal_orphans: true`. Separately, `cmd_tree` and `print_subtree` gain an
`orphan_roots` lookup so orphaned branches show up in the tree (as extra
roots, annotated) instead of vanishing.

**Tech Stack:** Ruby (Spinel-compatible subset — this script is AOT-compiled
by `spin build`; avoid any Ruby feature not already used elsewhere in
`bin/git-stack.rb`). Tests are a snapshot-based transcript diff
(`test/cli_test.rb` vs `test/cli_test.rb.expected`), run via
`ruby test/cli_test.rb` (CRuby) or `spin test` (compiled).

## Global Constraints

- Only use Ruby constructs already present elsewhere in `bin/git-stack.rb`
  (string `.split`, `.sub`, `.index`, backticks/`system` for git calls,
  heredocs) — the file must stay compilable by Spinel (`spin build`).
- No new dependencies.
- Existing `git stack restack` behavior and its snapshot output must not
  change (existing sections in `test/cli_test.rb.expected` stay byte-for-byte
  identical except where this plan explicitly adds new sections).
- Snapshot expectations are regenerated with `spin test --regen` (or
  `ruby test/cli_test.rb > test/cli_test.rb.expected`) — never hand-edited.
- Colour codes (`C_YELLOW`, `C_CYAN`, etc.) are already suppressed by
  `NO_COLOR=1` in the test harness, so new `info`/`extra` strings appear
  as plain text in snapshots.

---

### Task 1: `git stack sync` reparents orphaned branches and restacks

**Files:**
- Modify: `bin/git-stack.rb` (`restack_subtree`, `cmd_restack`, new `cmd_sync`, `main` dispatch, `cmd_help`)
- Test: `test/cli_test.rb` (new scenarios), `test/cli_test.rb.expected` (regenerated)

**Interfaces:**
- Produces: `cmd_sync(args)` — top-level subcommand handler, same shape as `cmd_restack(args)`.
- Produces: `restack_subtree(branch, scan, visited, trunk, heal_orphans)` — new signature (was `restack_subtree(branch, scan, visited)`). `heal_orphans` is a boolean; when true, a branch whose recorded parent doesn't exist gets reparented onto `trunk` via `set_parent` before the existing rebase-if-behind logic runs.
- Consumes: existing helpers `parent_from`, `branch_exists?`, `set_parent`, `commit_count`, `git_ok`, `children_from`, `stack_root`, `scan_stack_config`, `trunk_branch`, `current_branch`, `sh`, `info`, `die` — no signature changes to any of these.

- [ ] **Step 1: Add a snapshot scenario that exercises `sync` on an orphaned branch (red)**

  Append to `test/cli_test.rb`, right after the existing `"restack leaves an untracked branch alone"` section (after line 205):

  ```ruby
  section "sync reparents an orphaned branch onto trunk and restacks it"
  new_repo
  gsq("create feat-a"); commit("a.txt", "a1")
  gsq("create feat-b"); commit("b.txt", "b1")
  # simulate "merge feat-a into main, then delete it"
  setup("git checkout -q main")
  setup("git merge -q --no-edit feat-a")
  setup("git branch -d feat-a")
  setup("git checkout -q feat-b")
  run("sync")
  show("branch.feat-b.stackParent", "git config --get branch.feat-b.stackParent")
  show("feat-b behind main", "git rev-list --count feat-b..main")
  show("HEAD", "git branch --show-current")

  section "sync heals a multi-level orphan chain in one pass"
  new_repo
  gsq("create feat-a"); commit("a.txt", "a1")
  gsq("create feat-b"); commit("b.txt", "b1")
  gsq("create feat-c"); commit("c.txt", "c1")
  # merge and delete both feat-a and feat-b, leaving feat-c's parent chain
  # (feat-c -> feat-b -> feat-a -> main) with two missing links
  setup("git checkout -q main")
  setup("git merge -q --no-edit feat-b") # feat-b already contains feat-a's commit
  setup("git branch -d feat-a")
  setup("git branch -d feat-b")
  setup("git checkout -q feat-c")
  run("sync")
  show("branch.feat-c.stackParent", "git config --get branch.feat-c.stackParent")
  show("feat-c behind main", "git rev-list --count feat-c..main")

  section "sync reports a conflict the same way restack does"
  new_repo
  gsq("create feat-a")
  setup("echo from-a > shared.txt && git add shared.txt && git commit -qm a-shared")
  gsq("create feat-b")
  setup("echo from-b > shared.txt && git add shared.txt && git commit -qm b-shared")
  setup("git checkout -q main")
  setup("git merge -q --no-edit feat-a")
  setup("git branch -d feat-a")
  setup("echo changed-a > shared.txt && git add shared.txt && git commit -qm main-conflict")
  setup("git checkout -q feat-b")
  run("sync")
  ```

  Notes on the setup: `git merge --no-edit feat-a` into `main` simulates the
  PR merge; `git branch -d feat-a` only succeeds (without `-D`) because the
  branch is now fully merged into the checked-out branch (`main`) — this is
  what makes the scenario realistic and keeps `-d` (not `-D`).

- [ ] **Step 2: Run the transcript under current code and confirm it does NOT show reparenting (red)**

  Run: `ruby test/cli_test.rb | grep -A6 'sync reparents'`

  Expected (today, before any implementation change): `git stack sync` is
  currently a bare alias for `cmd_restack`, so the output shows
  `restacking stack rooted at feat-b` followed immediately by `done.` with
  **no** reparenting message, and `branch.feat-b.stackParent` still prints
  `feat-a` (stale) rather than `main`. This confirms the feature doesn't
  exist yet.

  Also check: `ruby test/cli_test.rb | grep -A4 'multi-level orphan chain'`
  should show `branch.feat-c.stackParent` still printing the stale `feat-b`
  (today's `restack_subtree` has no way to know it should point at `main`
  once both intermediate branches are gone).

- [ ] **Step 3: Update `restack_subtree` to accept `heal_orphans` and reparent onto trunk**

  Replace the existing function (currently `bin/git-stack.rb:398-425`):

  ```ruby
  # Rebase `branch` onto its parent, then recurse into its children.
  #
  # A branch with no recorded parent is untracked and is left untouched -- we
  # do *not* fall back to rebasing it onto the trunk. `visited` guards
  # against cyclic parent chains so the recursion always terminates.
  #
  # When `heal_orphans` is true (used by `git stack sync`), a branch whose
  # recorded parent no longer exists (e.g. it was merged and deleted) is
  # reparented onto `trunk` before the rebase check runs. When false (used by
  # `git stack restack`), such a branch is left untouched, same as before.
  def restack_subtree(branch, scan, visited, trunk, heal_orphans)
    return if visited[branch]
    visited[branch] = true

    parent = parent_from(scan, branch)

    if heal_orphans && !parent.empty? && !branch_exists?(parent)
      info "'#{branch}': parent '#{parent}' no longer exists; reparenting onto trunk '#{trunk}'"
      die("failed to reparent '#{branch}'") unless set_parent(branch, trunk)
      parent = trunk
    end

    if !parent.empty? && branch_exists?(parent)
      behind = commit_count(branch, parent)
      if behind > 0
        info "restacking #{C_CYAN}#{branch}#{C_RESET} onto #{C_CYAN}#{parent}#{C_RESET}"
        unless git_ok("git rebase #{sh(parent)} #{sh(branch)}")
          git_ok("git rebase --abort")
          verb = heal_orphans ? "sync" : "restack"
          die("conflict while rebasing '#{branch}' onto '#{parent}'.\n" \
              "Resolve it manually with:\n" \
              "    git checkout #{branch} && git rebase #{parent}\n" \
              "then re-run '#{PROG} #{verb}'.")
        end
      end
    end

    children_from(scan, branch).each do |child|
      restack_subtree(child, scan, visited, trunk, heal_orphans)
    end
  end
  ```

- [ ] **Step 4: Update `cmd_restack` to pass the new arguments (unchanged behavior)**

  Replace the existing function (currently `bin/git-stack.rb:427-441`):

  ```ruby
  def cmd_restack(_args)
    original = current_branch
    trunk = trunk_branch
    root = stack_root(original, trunk)

    info "restacking stack rooted at #{C_CYAN}#{root}#{C_RESET}"
    scan = scan_stack_config
    restack_subtree(root, scan, {}, trunk, false)

    unless git_ok("git checkout #{sh(original)}")
      die("restack completed, but returning to '#{original}' failed;\n" \
          "you are now on '#{current_branch_or_empty}'. Check out '#{original}' manually.")
    end
    info "#{C_GREEN}done.#{C_RESET}"
  end
  ```

- [ ] **Step 5: Add `cmd_sync`**

  Insert immediately after `cmd_restack`:

  ```ruby
  def cmd_sync(_args)
    original = current_branch
    trunk = trunk_branch
    root = stack_root(original, trunk)

    info "syncing stack rooted at #{C_CYAN}#{root}#{C_RESET}"
    scan = scan_stack_config
    restack_subtree(root, scan, {}, trunk, true)

    unless git_ok("git checkout #{sh(original)}")
      die("sync completed, but returning to '#{original}' failed;\n" \
          "you are now on '#{current_branch_or_empty}'. Check out '#{original}' manually.")
    end
    info "#{C_GREEN}done.#{C_RESET}"
  end
  ```

- [ ] **Step 6: Split the `restack`/`sync` dispatch and add `sync` to help text**

  In `main` (currently `bin/git-stack.rb:498`), replace:

  ```ruby
  when "restack", "sync"      then cmd_restack(rest)
  ```

  with:

  ```ruby
  when "restack"              then cmd_restack(rest)
  when "sync"                 then cmd_sync(rest)
  ```

  In `cmd_help`'s `COMMANDS` section (currently `bin/git-stack.rb:454-465`),
  add a line right after `restack`, matching the existing column alignment
  (description text starts at the same column as every other entry):

  ```ruby
        restack               Rebase the whole stack so each branch sits on its parent.
        sync                  Reparent branches whose parent was deleted (e.g. merged via a PR) onto trunk, then restack.
        version               Show the git-stack version.
  ```

- [ ] **Step 7: Run the transcript and confirm the new sections now show healing (green)**

  Run: `ruby test/cli_test.rb | grep -A8 'sync reparents'`

  Expected: output includes
  `'feat-b': parent 'feat-a' no longer exists; reparenting onto trunk 'main'`,
  then `restacking feat-b onto main` (only if `feat-b` has commits `main`
  doesn't — it does, since `feat-a`'s commit is now in `main` via merge and
  `feat-b` has its own `b1` commit on top), then `done.`.
  `branch.feat-b.stackParent` shows `main`. `feat-b behind main` shows `0`.
  `HEAD` shows `feat-b`.

  Run: `ruby test/cli_test.rb | grep -A6 'sync reports a conflict'`

  Expected: output includes the reparent message, then
  `error: conflict while rebasing 'feat-b' onto 'main'.` followed by
  `then re-run 'git stack sync'.` and `[exit 1]`.

  Run: `ruby test/cli_test.rb | grep -A4 'multi-level orphan chain'`

  Expected: `branch.feat-c.stackParent` now shows `main` (not the stale
  `feat-b`) and `feat-c behind main` shows `0` — both intermediate orphans
  (`feat-a`, `feat-b`) were healed in the single `sync` call via recursion.

  If any of these don't match, fix the implementation (not the test) before
  proceeding.

- [ ] **Step 8: Regenerate and lock in the snapshot**

  Run: `ruby test/cli_test.rb > test/cli_test.rb.expected`

  Then diff it to make sure only the three new sections were added and
  nothing else moved: `git diff test/cli_test.rb.expected`

  Expected: the diff shows only additions for the three new `### sync ...`
  sections; every pre-existing line is untouched.

- [ ] **Step 9: Commit**

  ```bash
  git add bin/git-stack.rb test/cli_test.rb test/cli_test.rb.expected
  git commit -m "$(cat <<'EOF'
  Add git stack sync to reparent orphaned branches and restack

  When a stacked branch's parent is merged and deleted, git stack restack
  silently leaves its children pointed at the now-missing parent. `git
  stack sync` detects that case, reparents onto trunk, and restacks --
  turning a manual `parent`+`restack` dance into one command.
  EOF
  )"
  ```

---

### Task 2: `git stack tree` shows orphaned branches instead of hiding them

**Files:**
- Modify: `bin/git-stack.rb` (`cmd_tree`, `print_subtree`, new `orphan_roots`)
- Test: `test/cli_test.rb` (new scenario), `test/cli_test.rb.expected` (regenerated)

**Interfaces:**
- Produces: `orphan_roots(scan)` — returns a sorted array of branch names whose recorded parent is non-empty but no longer exists (parsed from a pre-captured `scan_stack_config` result, same style as `children_from`).
- Consumes: `scan_stack_config`, `branch_exists?`, `print_subtree`, `children_from` (all unchanged).

- [ ] **Step 1: Add a snapshot scenario proving today's silent drop (red)**

  Append to `test/cli_test.rb`, after the three `sync` sections added in Task 1:

  ```ruby
  section "tree shows a branch whose parent was deleted, then sync fixes it"
  new_repo
  gsq("create feat-a"); commit("a.txt", "a1")
  gsq("create feat-b"); commit("b.txt", "b1")
  setup("git checkout -q main")
  setup("git merge -q --no-edit feat-a")
  setup("git branch -d feat-a")
  setup("git checkout -q feat-b")
  run("tree")
  gsq("sync")
  run("tree")
  ```

- [ ] **Step 2: Run the transcript and confirm `feat-b` is missing from the first `tree` (red)**

  Run: `ruby test/cli_test.rb | grep -A4 'tree shows a branch'`

  Expected (today): the first `git stack tree` output shows only
  `main (trunk)` with no children at all -- `feat-b` does not appear,
  confirming the display bug described in the spec.

- [ ] **Step 3: Add the `orphan_roots` helper**

  Insert right after `children_of` (currently ending at `bin/git-stack.rb:186`):

  ```ruby
  # Branches whose recorded parent is non-empty but no longer a real branch
  # (its parent was merged and deleted). Treated as extra roots by `tree` so
  # they're always visible instead of silently disappearing; `git stack sync`
  # is what actually repairs them.
  def orphan_roots(scan)
    names = []
    scan.split("\n").each do |line|
      next if line.empty?

      space = line.index(" ")
      next if space.nil?

      key = line[0...space]
      value = line[(space + 1)..-1]
      next if value.empty?
      next if branch_exists?(value)

      name = key.sub(/^branch\./, "").sub(/\.stackparent$/, "")
      names << name
    end
    names.sort
  end
  ```

- [ ] **Step 4: Render orphan roots in `cmd_tree`**

  Replace the existing function (currently `bin/git-stack.rb:322-334`):

  ```ruby
  def cmd_tree(_args)
    trunk = trunk_branch
    cur = current_branch_or_empty
    scan = scan_stack_config

    # The trunk is the visual root; its children are the stack roots.
    marker, style = marker_and_style(trunk, cur, C_CYAN)
    puts "#{marker} #{style}#{trunk}#{C_RESET} #{C_DIM}(trunk)#{C_RESET}"

    children_from(scan, trunk).each do |child|
      print_subtree(child, "  ", cur, trunk, scan)
    end

    orphan_roots(scan).each do |child|
      print_subtree(child, "  ", cur, trunk, scan)
    end
  end
  ```

- [ ] **Step 5: Annotate orphaned branches in `print_subtree`**

  Replace the existing function (currently `bin/git-stack.rb:268-290`):

  ```ruby
  def print_subtree(branch, prefix, cur, trunk, scan)
    marker, name_style = marker_and_style(branch, cur, C_RESET)

    extra = ""
    parent = parent_from(scan, branch)
    parent = trunk if parent.empty?
    if !parent.empty? && branch_exists?(parent)
      # Count commits this branch is ahead of / behind its parent.
      ahead = commit_count(parent, branch)
      behind = commit_count(branch, parent)
      if behind > 0
        extra = "#{C_YELLOW}(needs restack: #{behind} behind)#{C_RESET}"
      elsif ahead > 0
        extra = "#{C_DIM}(#{ahead} commit(s))#{C_RESET}"
      end
    elsif !parent.empty?
      extra = "#{C_YELLOW}(parent '#{parent}' missing; run `#{PROG} sync`)#{C_RESET}"
    end

    puts "#{prefix}#{marker} #{name_style}#{branch}#{C_RESET} #{extra}"

    children_from(scan, branch).each do |child|
      print_subtree(child, "#{prefix}  ", cur, trunk, scan)
    end
  end
  ```

- [ ] **Step 6: Run the transcript and confirm both `tree` calls now behave correctly (green)**

  Run: `ruby test/cli_test.rb | grep -A6 'tree shows a branch'`

  Expected: the first `git stack tree` now shows
  ``` \`feat-b\` (parent 'feat-a' missing; run `git stack sync`) ``` nested
  under `main (trunk)`; the second `git stack tree` (after `sync` ran) shows
  a clean `main (trunk)` → `feat-b` with no annotation (or a normal
  `(N commit(s))` marker if ahead).

- [ ] **Step 7: Regenerate and lock in the snapshot**

  Run: `ruby test/cli_test.rb > test/cli_test.rb.expected`

  Run: `git diff test/cli_test.rb.expected` and confirm the diff only adds
  the new `### tree shows a branch...` section.

- [ ] **Step 8: Commit**

  ```bash
  git add bin/git-stack.rb test/cli_test.rb test/cli_test.rb.expected
  git commit -m "$(cat <<'EOF'
  Fix git stack tree to show branches whose parent was deleted

  tree only recursed from trunk's direct children, so a branch whose
  parent was merged and deleted (and thus vanished from that walk)
  disappeared from the tree entirely instead of surfacing as something
  to fix. Render such branches as extra roots with an explicit
  "parent missing" annotation pointing at `git stack sync`.
  EOF
  )"
  ```

---

### Task 3: Document `sync` in the README

**Files:**
- Modify: `README.md`

**Interfaces:** none (documentation only).

- [ ] **Step 1: Add `sync` to the commands table**

  In the `## Commands` table (currently `README.md:83-96`), add a row right
  after `restack`:

  ```markdown
  | `git stack restack`       | Rebase the whole stack so each branch sits on its parent.       |
  | `git stack sync`          | Reparent branches whose parent was deleted (e.g. merged via a PR) onto trunk, then restack. |
  | `git stack version`       | Show the git-stack version.                                    |
  ```

- [ ] **Step 2: Add a merged-branch example to the Walkthrough**

  At the end of the `## Walkthrough` section (currently ending at
  `README.md:120`), before the `git stack tree` flags paragraph, add:

  ```markdown

  Once a branch merges, delete it and let `sync` clean up what was stacked on it:

  \`\`\`sh
  git checkout main && git pull
  git branch -d feature-a         # already merged, safe to delete

  git checkout feature-b
  git stack sync                  # reparents feature-b onto main and restacks it
  \`\`\`
  ```

  (Use literal triple-backtick fences, not escaped, when editing the file.)

- [ ] **Step 3: Proofread and commit**

  Run: `git diff README.md` and read it once to confirm formatting matches
  the surrounding table/list style.

  ```bash
  git add README.md
  git commit -m "$(cat <<'EOF'
  Document git stack sync in the README

  Adds the command to the reference table and shows the
  merge-then-delete-then-sync sequence in the walkthrough.
  EOF
  )"
  ```

---

### Task 4: Full regression pass (CRuby + Spinel)

**Files:** none created/modified — verification only.

**Interfaces:** none.

- [ ] **Step 1: Run the full snapshot diff under CRuby**

  Run: `ruby test/cli_test.rb > /tmp/actual.expected && diff test/cli_test.rb.expected /tmp/actual.expected`

  Expected: no output (files identical).

- [ ] **Step 2: Confirm the script still compiles with Spinel**

  Run: `spin build`

  Expected: exits 0 and produces `build/bin/git-stack` (proves the new code
  — `orphan_roots`, the extra `restack_subtree` parameters, the new `elsif`
  branch — stays inside Spinel's accepted Ruby subset).

- [ ] **Step 3: Run the snapshot test against the compiled binary**

  Run: `spin test`

  Expected: passes (diffs the compiled binary's transcript against the same
  `test/cli_test.rb.expected`, catching any CRuby/Spinel behavioral gap).

- [ ] **Step 4: Manual smoke test of the exact scenario from the original question**

  ```bash
  cd /tmp && rm -rf gs-smoke && mkdir gs-smoke && cd gs-smoke
  git init -q -b main
  git commit --allow-empty -qm base
  ruby $OLDPWD/../git-stack/bin/git-stack.rb create feature-a
  echo a > a.txt && git add a.txt && git commit -qm a1
  ruby $OLDPWD/../git-stack/bin/git-stack.rb create feature-b
  echo b > b.txt && git add b.txt && git commit -qm b1
  git checkout -q main
  git merge -q --no-edit feature-a
  git branch -d feature-a
  git checkout -q feature-b
  ruby $OLDPWD/../git-stack/bin/git-stack.rb tree
  ruby $OLDPWD/../git-stack/bin/git-stack.rb sync
  ruby $OLDPWD/../git-stack/bin/git-stack.rb tree
  ```

  (Adjust the `$OLDPWD/../git-stack` path to wherever the repo actually is
  if it differs from a sibling checkout.)

  Expected: first `tree` shows `feature-b` under `main` with the
  "parent missing" annotation; `sync` prints the reparent + restack info
  lines; second `tree` shows a clean `main -> feature-b` with no annotation.

- [ ] **Step 5: Report results**

  No commit in this task — it's verification only. If any step fails, stop
  and fix the root cause in the relevant Task 1-3 commit (amend or add a
  follow-up commit), then re-run this task from Step 1.
