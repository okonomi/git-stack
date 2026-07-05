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
def color_enabled?
  nc = ENV["NO_COLOR"]
  return false if !nc.nil? && nc != ""

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

def require_repo
  die("not a git repository") unless git_ok("git rev-parse --git-dir")
end

def current_branch
  b = git_out("git symbolic-ref --quiet --short HEAD")
  die("you are in 'detached HEAD' state; check out a branch first") if b.empty?
  b
end

# The current branch, or "" when detached (never dies).
def current_branch_or_empty
  git_out("git symbolic-ref --quiet --short HEAD")
end

def branch_exists?(name)
  git_ok("git show-ref --verify --quiet refs/heads/#{sh(name)}")
end

# Count of commits reachable from `to` but not `from` (git rev-list from..to).
def commit_count(range_from, range_to)
  n = git_out("git rev-list --count #{sh(range_from)}..#{sh(range_to)}")
  n.empty? ? 0 : n.to_i
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

  system("git", "config", "stack.trunk", trunk)
  trunk
end

# The cached trunk without triggering detection (empty when unset).
def trunk_cached
  git_out("git config --get stack.trunk")
end

# --- stack metadata ---------------------------------------------------------

def get_parent(branch)
  git_out("git config --get branch.#{sh(branch)}.stackParent")
end

def set_parent(branch, parent)
  system("git", "config", "branch.#{branch}.stackParent", parent)
end

def clear_parent(branch)
  git_ok("git config --unset branch.#{sh(branch)}.stackParent")
end

# Return every branch that records `parent` as its parent.
#
# Note: git lowercases the variable-name portion of a config key, so the
# stored key is `branch.<name>.stackparent` even though we write `stackParent`.
def children_of(parent)
  out = `git config --get-regexp '^branch\\..*\\.stackparent$' 2>/dev/null`
  names = []
  out.split("\n").each do |line|
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

# Walk down from `branch` to the root of its stack (the branch whose parent is
# the trunk or is untracked). Returns the root branch name.
def stack_root(branch, trunk)
  loop do
    parent = get_parent(branch)
    break if parent.empty? || parent == trunk
    break unless branch_exists?(parent)

    branch = parent
  end
  branch
end

# --- tree rendering ---------------------------------------------------------

# Recursively print the subtree rooted at `branch` with indent `prefix`.
def print_subtree(branch, prefix, cur)
  marker = " "
  name_style = C_RESET
  if branch == cur
    marker = "*"
    name_style = "#{C_GREEN}#{C_BOLD}"
  end

  extra = ""
  parent = get_parent(branch)
  parent = trunk_cached if parent.empty?
  if !parent.empty? && branch_exists?(parent)
    # Count commits this branch is ahead of / behind its parent.
    ahead = commit_count(parent, branch)
    behind = commit_count(branch, parent)
    if behind > 0
      extra = "#{C_YELLOW}(needs restack: #{behind} behind)#{C_RESET}"
    elsif ahead > 0
      extra = "#{C_DIM}(#{ahead} commit(s))#{C_RESET}"
    end
  end

  puts "#{prefix}#{marker} #{name_style}#{branch}#{C_RESET} #{extra}"

  children_of(branch).each do |child|
    print_subtree(child, "#{prefix}  ", cur)
  end
end

# --- subcommands ------------------------------------------------------------

def cmd_init(args)
  trunk = args.empty? ? "" : args[0]
  if trunk.empty?
    trunk = trunk_branch
    info "trunk is '#{trunk}' (auto-detected)"
    return
  end
  die("branch '#{trunk}' does not exist") unless branch_exists?(trunk)
  system("git", "config", "stack.trunk", trunk)
  info "trunk set to '#{trunk}'"
end

def cmd_create(args)
  name = args.empty? ? "" : args[0]
  die("usage: #{PROG} create <branch-name>") if name.empty?
  die("branch '#{name}' already exists") if branch_exists?(name)

  parent = current_branch
  die("failed to create branch '#{name}'") unless git_ok("git checkout -b #{sh(name)}")
  set_parent(name, parent)
  info "created #{C_GREEN}#{name}#{C_RESET} on top of #{C_CYAN}#{parent}#{C_RESET}"
end

def cmd_tree(_args)
  trunk = trunk_branch
  cur = current_branch_or_empty

  # The trunk is the visual root; its children are the stack roots.
  marker = " "
  style = C_CYAN
  if trunk == cur
    marker = "*"
    style = "#{C_GREEN}#{C_BOLD}"
  end
  puts "#{marker} #{style}#{trunk}#{C_RESET} #{C_DIM}(trunk)#{C_RESET}"

  children_of(trunk).each do |child|
    print_subtree(child, "  ", cur)
  end
end

def cmd_parent(args)
  branch = current_branch
  new_parent = args.empty? ? "" : args[0]
  if new_parent.empty?
    p = get_parent(branch)
    p = trunk_branch if p.empty?
    puts p
    return
  end
  die("branch '#{new_parent}' does not exist") unless branch_exists?(new_parent)
  die("a branch cannot be its own parent") if new_parent == branch
  set_parent(branch, new_parent)
  info "parent of '#{branch}' set to '#{new_parent}'"
end

def cmd_track(args)
  branch = current_branch
  parent = args.empty? ? "" : args[0]
  parent = trunk_branch if parent.empty?
  die("branch '#{parent}' does not exist") unless branch_exists?(parent)
  die("a branch cannot be its own parent") if parent == branch
  set_parent(branch, parent)
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
  parent = get_parent(branch)
  parent = trunk if parent.empty?
  die("already at the bottom of the stack") if parent == branch
  die("parent branch '#{parent}' no longer exists") unless branch_exists?(parent)
  system("git", "checkout", parent)
end

def cmd_up(args)
  branch = current_branch
  want = args.empty? ? "" : args[0]

  children = children_of(branch)
  die("no branch stacked on top of '#{branch}'") if children.empty?

  unless want.empty?
    children.each do |child|
      if child == want
        system("git", "checkout", want)
        return
      end
    end
    die("'#{want}' is not stacked directly on '#{branch}'")
  end

  if children.length == 1
    system("git", "checkout", children[0])
    return
  end

  info "'#{branch}' has multiple children; pick one:"
  children.each do |child|
    info "  #{PROG} up #{child}"
  end
  exit 1
end

# Rebase `branch` onto its parent, then recurse into its children.
def restack_subtree(branch)
  parent = get_parent(branch)
  parent = trunk_branch if parent.empty?

  if branch_exists?(parent)
    behind = commit_count(branch, parent)
    if behind > 0
      info "restacking #{C_CYAN}#{branch}#{C_RESET} onto #{C_CYAN}#{parent}#{C_RESET}"
      unless git_ok("git rebase #{sh(parent)} #{sh(branch)}")
        git_ok("git rebase --abort")
        die("conflict while rebasing '#{branch}' onto '#{parent}'.\n" \
            "Resolve it manually with:\n" \
            "    git checkout #{branch} && git rebase #{parent}\n" \
            "then re-run '#{PROG} restack'.")
      end
    end
  end

  children_of(branch).each do |child|
    restack_subtree(child)
  end
end

def cmd_restack(_args)
  original = current_branch
  trunk = trunk_branch
  root = stack_root(original, trunk)

  info "restacking stack rooted at #{C_CYAN}#{root}#{C_RESET}"
  restack_subtree(root)

  git_ok("git checkout #{sh(original)}")
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
  when "restack", "sync"      then cmd_restack(rest)
  when "version", "--version", "-v" then cmd_version(rest)
  when "help", "-h", "--help" then cmd_help(rest)
  else
    die("unknown command '#{cmd}' (try '#{PROG} help')")
  end
end

main(ARGV)
