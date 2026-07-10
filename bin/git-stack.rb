#!/usr/bin/env ruby
# frozen_string_literal: true
#
# git-stack -- manage stacked branches with plain git.
#
# A "stack" is a chain of branches where each branch records a parent.
# The parent relationship is stored in git config as:
#
#     branch.<name>.stackParent = <parent-branch>
#
# The bottom of every stack rests on the trunk (main/master), which is
# stored as `stack.trunk` in git config (auto-detected on first use).
#
# This is a Ruby port of the original bash script, written in the subset of
# Ruby that Spinel's AOT compiler accepts so that `spin build` turns it into a
# standalone native `git-stack` binary. It also runs unchanged under CRuby.
#
# See `git stack help` for the list of subcommands.

PROG = "git stack"
VERSION = "0.1.0"

# The Spinel revision this binary is built with, shown by `git stack version`.
# A Spinel-compiled binary can't introspect its compiler's revision at run time
# (the only build signal it exposes is RUBY_DESCRIPTION == "spinel", with no
# revision), so it is recorded here at build time instead: the Homebrew formula
# rewrites this line with the actual `spinel --version` before `spin build`, so
# the installed binary reports its true toolchain (including a --HEAD Spinel).
#
# This committed value is the fallback for builds that don't stamp it (a plain
# `spin build`, or running under CRuby). Keep it in sync with SPINEL_REF in
# .github/workflows/ci.yml, .claude/hooks/session-start.sh, and the `revision`
# in Formula/spinel.rb -- the places that pin the Spinel we build against.
SPINEL_REF = "ee8bcf9fac98dcc500dbeaef8623c82abd1ba834"

# --- output helpers ---------------------------------------------------------

# All terminal decoration goes through this section. Nothing outside it should
# emit a raw ANSI escape or pair a colour with its reset by hand; callers name
# the *intent* (`green(name)`, `bold("USAGE")`) and the reset -- and the
# colour-disabled case -- are handled here in one place.

# Colours are enabled only when writing to a terminal (and NO_COLOR is unset).
#
# Per the NO_COLOR spec (https://no-color.org/), the mere *presence* of the
# variable disables colour, regardless of its value -- including an empty
# string.
def color_enabled?
  return false unless ENV["NO_COLOR"].nil?

  # Spinel resolves `.tty?` on the STDOUT constant, but not on the $stdout
  # global (it dispatches on `unknown` and raises); use the constant.
  STDOUT.tty?
end

USE_COLOR = color_enabled?

# Wrap `text` in the SGR sequence `code` (e.g. "32", "1"), resetting after.
# When colour is disabled this is the identity function, so callers never
# touch escape codes or the matching reset themselves.
def paint(code, text)
  return text unless USE_COLOR

  "\033[#{code}m#{text}\033[0m"
end

def bold(text)
  paint("1", text)
end

def dim(text)
  paint("2", text)
end

def green(text)
  paint("32", text)
end

def yellow(text)
  paint("33", text)
end

def cyan(text)
  paint("36", text)
end

def red(text)
  paint("31", text)
end

def die(msg)
  $stderr.puts "#{red("error:")} #{msg}"
  exit 1
end

def info(msg)
  $stderr.puts msg
end

# --- shell / git helpers ----------------------------------------------------

# Quote a single argument for safe interpolation into a shell command.
def sh(arg)
  "'" + arg.gsub(/'/, "'\\''") + "'"
end

# Run `git <subcmd>`, discarding its output; return true on success (exit 0).
def git_ok(subcmd)
  system("git #{subcmd} >/dev/null 2>&1")
  $? == 0
end

# Capture the trimmed stdout of `git <subcmd>` (empty string on failure).
def git_out(subcmd)
  `git #{subcmd} 2>/dev/null`.strip
end

# Check out `branch`, or die with a consistent message.
#
# Uses array-form `system` (not git_ok) so git's own "Switched to branch"
# message reaches the terminal instead of being redirected away.
def checkout!(branch)
  die("failed to check out '#{branch}'") unless system("git", "checkout", branch)
end

def require_repo
  die("not a git repository") unless git_ok("rev-parse --git-dir")
end

# The current branch, or "" when detached (never dies).
def current_branch_or_empty
  git_out("symbolic-ref --quiet --short HEAD")
end

def current_branch
  b = current_branch_or_empty
  die("you are in 'detached HEAD' state; check out a branch first") if b.empty?
  b
end

# Spawns a `git` subprocess per call. Fine for the one-off checks scattered
# through this file, but do NOT call this inside a per-node loop over a
# stack -- use the pre-captured `existing_branches` set there instead (see
# `print_subtree`/`restack_subtree` for the pattern).
def branch_exists?(name)
  git_ok("show-ref --verify --quiet refs/heads/#{sh(name)}")
end

# Count of commits reachable from `to` but not `from` (git rev-list from..to).
def commit_count(range_from, range_to)
  git_out("rev-list --count #{sh(range_from)}..#{sh(range_to)}").to_i
end

# [behind, ahead] commit counts between `branch` and `parent`, in a single
# `git rev-list --left-right --count` call instead of two separate
# `commit_count` calls -- half the subprocess cost per tree node.
def ahead_behind(parent, branch)
  out = git_out("rev-list --left-right --count #{sh(parent)}...#{sh(branch)}")
  parts = out.split("\t")
  return [0, 0] if parts.length != 2

  [parts[0].to_i, parts[1].to_i]
end

def set_trunk(trunk)
  system("git", "config", "stack.trunk", trunk)
end

# Print the trunk branch, detecting and caching it on first use.
def trunk_branch
  trunk = git_out("config --get stack.trunk")
  return trunk unless trunk.empty?

  # Auto-detect: prefer the remote's default branch, then main/master.
  head = git_out("symbolic-ref --quiet --short refs/remotes/origin/HEAD")
  if !head.empty?
    trunk = head.sub(/^origin\//, "")
  elsif branch_exists?("main")
    trunk = "main"
  elsif branch_exists?("master")
    trunk = "master"
  else
    die("cannot determine trunk branch; run '#{PROG} init <branch>'")
  end

  set_trunk(trunk)
  trunk
end

# --- stack metadata ---------------------------------------------------------

def get_parent(branch)
  git_out("config --get branch.#{sh(branch)}.stackParent")
end

# Record `parent` as the parent of `branch`; return true on success.
#
# The result is bound to a local before returning: Spinel drops the boolean
# when a `system` call is a function's bare trailing expression.
def set_parent(branch, parent)
  ok = system("git", "config", "branch.#{branch}.stackParent", parent)
  ok
end

def clear_parent(branch)
  git_ok("config --unset branch.#{sh(branch)}.stackParent")
end

# One scan of git config listing every `branch.<name>.stackParent` entry.
#
# The tree and restack recursions call `children_from` at every node; capturing
# the scan once and threading it through the recursion avoids re-spawning `git`
# per node (an O(N^2) subprocess blow-up on a stack of N branches).
def scan_stack_config
  `git config --get-regexp '^branch\\..*\\.stackparent$' 2>/dev/null`
end

# Set of every local branch name, fetched with a single `git` subprocess.
#
# `tree` calls `branch_exists?` for every node it renders; on a stack of N
# branches that means N extra `git show-ref` subprocesses (each a shell +
# git fork/exec, ~10ms). Capturing the full branch list once and checking
# it in memory removes that per-node cost, mirroring how `scan_stack_config`
# avoids re-spawning `git config` per node.
def existing_branches
  out = `git for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null`
  set = {}
  out.split("\n").each do |name|
    next if name.empty?

    set[name] = true
  end
  set
end

# Sorted list of branches that record `parent` as their parent, parsed from a
# pre-captured `scan_stack_config` result -- no subprocess of its own.
#
# Note: git lowercases the variable-name portion of a config key, so the
# stored key is `branch.<name>.stackparent` even though we write `stackParent`.
def children_from(scan, parent)
  names = []
  scan.split("\n").each do |line|
    next if line.empty?

    space = line.index(" ")
    next if space.nil?

    key = line[0...space]
    value = line[(space + 1)..-1]
    next unless value == parent

    name = key.sub(/^branch\./, "").sub(/\.stackparent$/, "")
    names << name
  end
  names.sort
end

# Return every branch that records `parent` as its parent (single lookup).
def children_of(parent)
  children_from(scan_stack_config, parent)
end

# Branches whose recorded parent is non-empty but no longer a real branch
# (its parent was merged and deleted). Treated as extra roots by `tree` so
# they're always visible instead of silently disappearing; `git stack sync`
# is what actually repairs them.
#
# `branches` is a pre-captured `existing_branches` set so this needs no
# subprocess of its own.
def orphan_roots(scan, branches)
  names = []
  scan.split("\n").each do |line|
    next if line.empty?

    space = line.index(" ")
    next if space.nil?

    key = line[0...space]
    value = line[(space + 1)..-1]
    next if value.empty?
    next if branches[value]

    name = key.sub(/^branch\./, "").sub(/\.stackparent$/, "")
    names << name
  end
  names.sort
end

# The parent recorded for `branch`, parsed from a pre-captured
# `scan_stack_config` result -- no subprocess of its own (mirrors get_parent).
def parent_from(scan, branch)
  key = "branch.#{branch}.stackparent"
  scan.split("\n").each do |line|
    next if line.empty?

    space = line.index(" ")
    next if space.nil?

    next unless line[0...space] == key

    return line[(space + 1)..-1]
  end
  ""
end

# The parent used for display and navigation: the recorded parent, or the
# trunk when none is recorded.
def effective_parent(branch, trunk)
  parent = get_parent(branch)
  parent.empty? ? trunk : parent
end

# Walk down from `branch` to the root of its stack (the branch whose parent is
# the trunk or is untracked). Returns the root branch name.
#
# `seen` guards against cyclic parent chains (e.g. A -> B -> A) left over from
# older versions or hand-edited config, so we terminate instead of hanging.
def stack_root(branch, trunk)
  seen = {}
  loop do
    seen[branch] = true
    parent = get_parent(branch)
    break if parent.empty? || parent == trunk
    break unless branch_exists?(parent)
    break if seen[parent]

    branch = parent
  end
  branch
end

# True if making `new_parent` the parent of `branch` would create a cycle --
# that is, `branch` already lies on `new_parent`'s chain of ancestors.
def would_cycle?(branch, new_parent, trunk)
  seen = {}
  cur = new_parent
  loop do
    return true if cur == branch
    break if cur.empty? || cur == trunk
    break if seen[cur]
    break unless branch_exists?(cur)

    seen[cur] = true
    cur = get_parent(cur)
  end
  false
end

# Validate that `candidate` can become the parent of `branch`: it must exist,
# must not be `branch` itself, and must not create a cycle. `verb` customizes
# the cycle-error wording for the calling command.
def validate_new_parent!(branch, candidate, trunk, verb)
  die("branch '#{candidate}' does not exist") unless branch_exists?(candidate)
  die("a branch cannot be its own parent") if candidate == branch
  die("'#{candidate}' is downstream of '#{branch}'; #{verb} would create a cycle") if would_cycle?(branch, candidate, trunk)
end

# --- tree rendering ---------------------------------------------------------

# The tree row marker for `branch`: "*" when it's the checked-out branch.
def tree_marker(branch, cur)
  branch == cur ? "*" : " "
end

# `branch` coloured for a tree row: highlighted (bold green) when it's the
# checked-out branch, otherwise painted with `default_code` (an SGR code
# string, or "" for no colour).
def tree_name(branch, cur, default_code)
  return bold(green(branch)) if branch == cur
  return branch if default_code.empty?

  paint(default_code, branch)
end

# Recursively print the subtree rooted at `branch` with indent `prefix`.
#
# `branches` is a pre-captured `existing_branches` set, threaded through the
# recursion for the same reason `scan` is: avoids re-spawning `git` per node.
def print_subtree(branch, prefix, cur, trunk, scan, branches)
  extra = ""
  parent = parent_from(scan, branch)
  parent = trunk if parent.empty?
  if !parent.empty? && branches[parent]
    # Ahead+behind in one `git rev-list --left-right` call rather than two
    # separate `commit_count` calls.
    behind, ahead = ahead_behind(parent, branch)
    if behind > 0
      extra = yellow("(needs restack: #{behind} behind)")
    elsif ahead > 0
      extra = dim("(#{ahead} commit(s))")
    end
  elsif !parent.empty?
    extra = yellow("(parent '#{parent}' missing; run `#{PROG} sync`)")
  end

  puts "#{prefix}#{tree_marker(branch, cur)} #{tree_name(branch, cur, "")} #{extra}"

  children_from(scan, branch).each do |child|
    print_subtree(child, "#{prefix}  ", cur, trunk, scan, branches)
  end
end

# --- subcommands ------------------------------------------------------------

# The first CLI argument, or "" when none was given.
def arg0(args)
  args.empty? ? "" : args[0]
end

def cmd_init(args)
  trunk = arg0(args)
  if trunk.empty?
    trunk = trunk_branch
    info "trunk is '#{trunk}' (auto-detected)"
    return
  end
  die("branch '#{trunk}' does not exist") unless branch_exists?(trunk)
  set_trunk(trunk)
  info "trunk set to '#{trunk}'"
end

def cmd_create(args)
  name = arg0(args)
  die("usage: #{PROG} create <branch-name>") if name.empty?
  die("branch '#{name}' already exists") if branch_exists?(name)

  parent = current_branch
  die("failed to create branch '#{name}'") unless git_ok("checkout -b #{sh(name)}")
  die("created branch '#{name}' but failed to record its parent") unless set_parent(name, parent)
  info "created #{green(name)} on top of #{cyan(parent)}"
end

def cmd_tree(_args)
  trunk = trunk_branch
  cur = current_branch_or_empty
  scan = scan_stack_config
  branches = existing_branches

  # The trunk is the visual root; its children are the stack roots.
  puts "#{tree_marker(trunk, cur)} #{tree_name(trunk, cur, "36")} #{dim("(trunk)")}"

  children_from(scan, trunk).each do |child|
    print_subtree(child, "  ", cur, trunk, scan, branches)
  end

  orphan_roots(scan, branches).each do |child|
    print_subtree(child, "  ", cur, trunk, scan, branches)
  end
end

def cmd_parent(args)
  branch = current_branch
  new_parent = arg0(args)
  if new_parent.empty?
    puts effective_parent(branch, trunk_branch)
    return
  end
  validate_new_parent!(branch, new_parent, trunk_branch, "setting it as parent")
  die("failed to set parent of '#{branch}'") unless set_parent(branch, new_parent)
  info "parent of '#{branch}' set to '#{new_parent}'"
end

def cmd_track(args)
  branch = current_branch
  trunk = trunk_branch
  parent = arg0(args)
  parent = trunk if parent.empty?
  validate_new_parent!(branch, parent, trunk, "tracking it")
  die("failed to track '#{branch}'") unless set_parent(branch, parent)
  info "tracking '#{branch}' on top of '#{parent}'"
end

def cmd_untrack(_args)
  branch = current_branch
  clear_parent(branch)
  info "'#{branch}' is no longer tracked in a stack"
end

def cmd_down(_args)
  branch = current_branch
  trunk = trunk_branch
  parent = effective_parent(branch, trunk)
  die("already at the bottom of the stack") if parent == branch
  die("parent branch '#{parent}' no longer exists") unless branch_exists?(parent)
  checkout!(parent)
end

def cmd_up(args)
  branch = current_branch
  want = arg0(args)

  children = children_of(branch)
  die("no branch stacked on top of '#{branch}'") if children.empty?

  unless want.empty?
    die("'#{want}' is not stacked directly on '#{branch}'") unless children.include?(want)
    checkout!(want)
    return
  end

  if children.length == 1
    checkout!(children[0])
    return
  end

  info "'#{branch}' has multiple children; pick one:"
  children.each do |child|
    info "  #{PROG} up #{child}"
  end
  exit 1
end

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
#
# `branches` is a pre-captured `existing_branches` set, threaded through the
# recursion so existence checks don't spawn a `git` subprocess per node --
# safe because neither restack nor sync creates or deletes branch refs
# mid-traversal (sync only rewrites `stackParent` config, and rebase updates
# a branch's history in place without removing the ref).
def restack_subtree(branch, scan, visited, trunk, heal_orphans, branches)
  return if visited[branch]
  visited[branch] = true

  parent = parent_from(scan, branch)

  if heal_orphans && !parent.empty? && !branches[parent]
    info "'#{branch}': parent '#{parent}' no longer exists; reparenting onto trunk '#{trunk}'"
    die("failed to reparent '#{branch}'") unless set_parent(branch, trunk)
    parent = trunk
  end

  if !parent.empty? && branches[parent]
    behind = commit_count(branch, parent)
    if behind > 0
      info "restacking #{cyan(branch)} onto #{cyan(parent)}"
      unless git_ok("rebase #{sh(parent)} #{sh(branch)}")
        git_ok("rebase --abort")
        verb = heal_orphans ? "sync" : "restack"
        die("conflict while rebasing '#{branch}' onto '#{parent}'.\n" \
            "Resolve it manually with:\n" \
            "    git checkout #{branch} && git rebase #{parent}\n" \
            "then re-run '#{PROG} #{verb}'.")
      end
    end
  end

  children_from(scan, branch).each do |child|
    restack_subtree(child, scan, visited, trunk, heal_orphans, branches)
  end
end

def cmd_restack(_args)
  original = current_branch
  trunk = trunk_branch
  root = stack_root(original, trunk)

  info "restacking stack rooted at #{cyan(root)}"
  scan = scan_stack_config
  branches = existing_branches
  restack_subtree(root, scan, {}, trunk, false, branches)

  unless git_ok("checkout #{sh(original)}")
    die("restack completed, but returning to '#{original}' failed;\n" \
        "you are now on '#{current_branch_or_empty}'. Check out '#{original}' manually.")
  end
  info green("done.")
end

def cmd_sync(_args)
  original = current_branch
  trunk = trunk_branch
  root = stack_root(original, trunk)

  info "syncing stack rooted at #{cyan(root)}"
  scan = scan_stack_config
  branches = existing_branches
  restack_subtree(root, scan, {}, trunk, true, branches)

  unless git_ok("checkout #{sh(original)}")
    die("sync completed, but returning to '#{original}' failed;\n" \
        "you are now on '#{current_branch_or_empty}'. Check out '#{original}' manually.")
  end
  info green("done.")
end

def cmd_version(_args)
  puts "#{PROG} #{VERSION}"
  # Match `spinel --version`, which prints its 12-char short revision.
  puts "built with spinel #{SPINEL_REF[0...12]}"
end

def cmd_help(_args)
  puts <<~HELP
    #{bold(PROG)} -- manage stacked branches with plain git

    #{bold("USAGE")}
        #{PROG} <command> [args]

    #{bold("COMMANDS")}
        init [branch]         Set (or auto-detect) the trunk branch.
        create <name>         Create <name> stacked on the current branch. (alias: b)
        tree                  Show the stack as a tree. (aliases: ls, list)
        up [child]            Check out the branch stacked on the current one.
        down                  Check out the current branch's parent.
        parent [branch]       Show or set the parent of the current branch.
        track [parent]        Track the current branch on top of [parent] (or trunk).
        untrack               Stop tracking the current branch in a stack.
        restack               Rebase the whole stack so each branch sits on its parent.
        sync                  Reparent branches whose parent was deleted (e.g. merged via a PR) onto trunk, then restack.
        version               Show the git-stack version and the Spinel build revision.
        help                  Show this help.

    #{bold("EXAMPLE")}
        git checkout main
        #{PROG} create feature-a      # main -> feature-a
        #{PROG} create feature-b      # feature-a -> feature-b
        #{PROG} tree                  # inspect the stack
        # ... amend feature-a ...
        #{PROG} restack               # replay feature-b on the new feature-a

    Parent relationships are stored in git config (branch.<name>.stackParent).
  HELP
end

# --- dispatch ---------------------------------------------------------------

def main(argv)
  cmd = argv.empty? ? "help" : argv[0]
  rest = argv.empty? ? [] : argv[1..-1]

  repo_optional = cmd == "version" || cmd == "--version" || cmd == "-v" ||
                  cmd == "help" || cmd == "-h" || cmd == "--help"
  require_repo unless repo_optional

  case cmd
  when "init"                 then cmd_init(rest)
  when "create", "b", "branch" then cmd_create(rest)
  when "tree", "ls", "list"   then cmd_tree(rest)
  when "up", "next"           then cmd_up(rest)
  when "down", "prev"         then cmd_down(rest)
  when "parent"               then cmd_parent(rest)
  when "track"                then cmd_track(rest)
  when "untrack"              then cmd_untrack(rest)
  when "restack"              then cmd_restack(rest)
  when "sync"                 then cmd_sync(rest)
  when "version", "--version", "-v" then cmd_version(rest)
  when "help", "-h", "--help" then cmd_help(rest)
  else
    die("unknown command '#{cmd}' (try '#{PROG} help')")
  end
end

main(ARGV)
