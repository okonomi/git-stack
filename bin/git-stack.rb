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

# --- output helpers ---------------------------------------------------------

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

C_RESET  = USE_COLOR ? "\033[0m"  : ""
C_DIM    = USE_COLOR ? "\033[2m"  : ""
C_BOLD   = USE_COLOR ? "\033[1m"  : ""
C_GREEN  = USE_COLOR ? "\033[32m" : ""
C_YELLOW = USE_COLOR ? "\033[33m" : ""
C_CYAN   = USE_COLOR ? "\033[36m" : ""
C_RED    = USE_COLOR ? "\033[31m" : ""

def die(msg)
  $stderr.puts "#{C_RED}error:#{C_RESET} #{msg}"
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

# Run a git command, discarding its output; return true on success (exit 0).
def git_ok(cmd)
  system("#{cmd} >/dev/null 2>&1")
  $? == 0
end

# Capture the trimmed stdout of a git command (empty string on failure).
def git_out(cmd)
  `#{cmd} 2>/dev/null`.strip
end

# Check out `branch`, or die with a consistent message.
#
# Uses array-form `system` (not git_ok) so git's own "Switched to branch"
# message reaches the terminal instead of being redirected away.
def checkout!(branch)
  die("failed to check out '#{branch}'") unless system("git", "checkout", branch)
end

def require_repo
  die("not a git repository") unless git_ok("git rev-parse --git-dir")
end

# The current branch, or "" when detached (never dies).
def current_branch_or_empty
  git_out("git symbolic-ref --quiet --short HEAD")
end

def current_branch
  b = current_branch_or_empty
  die("you are in 'detached HEAD' state; check out a branch first") if b.empty?
  b
end

def branch_exists?(name)
  git_ok("git show-ref --verify --quiet refs/heads/#{sh(name)}")
end

# Count of commits reachable from `to` but not `from` (git rev-list from..to).
def commit_count(range_from, range_to)
  git_out("git rev-list --count #{sh(range_from)}..#{sh(range_to)}").to_i
end

def set_trunk(trunk)
  system("git", "config", "stack.trunk", trunk)
end

# Print the trunk branch, detecting and caching it on first use.
def trunk_branch
  trunk = git_out("git config --get stack.trunk")
  return trunk unless trunk.empty?

  # Auto-detect: prefer the remote's default branch, then main/master.
  head = git_out("git symbolic-ref --quiet --short refs/remotes/origin/HEAD")
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
  git_out("git config --get branch.#{sh(branch)}.stackParent")
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
  git_ok("git config --unset branch.#{sh(branch)}.stackParent")
end

# One scan of git config listing every `branch.<name>.stackParent` entry.
#
# The tree and restack recursions call `children_from` at every node; capturing
# the scan once and threading it through the recursion avoids re-spawning `git`
# per node (an O(N^2) subprocess blow-up on a stack of N branches).
def scan_stack_config
  `git config --get-regexp '^branch\\..*\\.stackparent$' 2>/dev/null`
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

# The prefix marker and name colour for `branch` when rendering the tree:
# highlighted if it's the checked-out branch, `default_style` otherwise.
def marker_and_style(branch, cur, default_style)
  return ["*", "#{C_GREEN}#{C_BOLD}"] if branch == cur

  [" ", default_style]
end

# Recursively print the subtree rooted at `branch` with indent `prefix`.
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
  die("failed to create branch '#{name}'") unless git_ok("git checkout -b #{sh(name)}")
  die("created branch '#{name}' but failed to record its parent") unless set_parent(name, parent)
  info "created #{C_GREEN}#{name}#{C_RESET} on top of #{C_CYAN}#{parent}#{C_RESET}"
end

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

def cmd_version(_args)
  puts "#{PROG} #{VERSION}"
end

def cmd_help(_args)
  puts <<~HELP
    #{C_BOLD}#{PROG}#{C_RESET} -- manage stacked branches with plain git

    #{C_BOLD}USAGE#{C_RESET}
        #{PROG} <command> [args]

    #{C_BOLD}COMMANDS#{C_RESET}
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
        version               Show the git-stack version.
        help                  Show this help.

    #{C_BOLD}EXAMPLE#{C_RESET}
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
