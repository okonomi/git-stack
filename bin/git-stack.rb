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
# The bottom of every stack rests on a trunk (main/master, and optionally
# others like a git-flow `develop`). Trunks are stored as the multi-valued
# `stack.trunk` git config key (auto-detected on first use).
#
# This is a Ruby port of the original bash script, written in the subset of
# Ruby that Spinel's AOT compiler accepts so that `spin build` turns it into a
# standalone native `git-stack` binary. It also runs unchanged under CRuby.
#
# See `git stack help` for the list of subcommands.

# Both resolve in both worlds: CRuby's stdlib, and the equivalent packages
# pre-installed with Spinel (spliced into the program at compile time).
require "optparse"
require "set"

PROG = "git stack"
VERSION = "0.1.0"

# The Spinel revision this binary was compiled with, shown by `git stack
# version`. A Spinel-compiled binary can't introspect its compiler's revision
# at run time (the only build signal it exposes is RUBY_DESCRIPTION ==
# "spinel", with no revision), so it is stamped in at build time: the Homebrew
# formula rewrites this line with the actual `spinel --version` before
# `spin build` (see Formula/git-stack.rb).
#
# It is intentionally left empty here -- a placeholder for that stamp, not a
# hand-maintained revision. A build that doesn't stamp it (a plain
# `spin build`) reports "unknown" instead of a stale pinned value.
SPINEL_REF = ""

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
  # `.to_s` (identity for the String this always receives) keeps Spinel's
  # return type independent of `text`: `return text` ties them together, and
  # the `bold(green(branch))` nesting in tree_name then feeds paint's return
  # back into this parameter -- a constraint cycle that locks the whole
  # colour-helper family to untyped once any transiently-untyped value
  # (cmd_tree's `trunks.each` block variable) passes through it.
  return text.to_s unless USE_COLOR

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

# Run `git <subcmd>` with its stdout/stderr passing through to the terminal;
# return true on success (exit 0). Unlike git_ok, nothing is redirected away,
# so git's own progress/status messages (e.g. "Switched to branch") stay
# visible -- use this for the interactive commands whose output the user
# should see. The `$? == 0` is read on its own line because Spinel drops the
# boolean when a bare `system` call is a method's trailing expression.
def git_run(subcmd)
  system("git #{subcmd}")
  $? == 0
end

# Check out `branch`, or die with a consistent message.
#
# Uses git_run (not git_ok) so git's own "Switched to branch" message reaches
# the terminal instead of being redirected away.
def checkout!(branch)
  die("failed to check out '#{branch}'") unless git_run("checkout #{sh(branch)}")
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

# Trunks are the branches every stack ultimately rests on. A repo can have
# more than one (e.g. git-flow's `main` and `develop`); they are stored as a
# multi-valued `stack.trunk` git config key. The first configured trunk is the
# "primary" one -- the default base a branch falls back to when it needs a
# trunk (an untracked branch's implied parent, or reparenting a branch whose
# parent was merged and deleted).

# Every configured trunk, in config order (empty list when none is set yet).
def configured_trunks
  out = git_out("config --get-all stack.trunk")
  list = []
  out.split("\n").each do |line|
    name = line.strip
    next if name.empty?

    list << name
  end
  list
end

# Replace the trunk list with exactly `trunks`.
def set_trunks(trunks)
  # --unset-all exits non-zero when the key is absent; that's expected, we
  # only need any old values gone before adding the new ones.
  git_ok("config --unset-all stack.trunk")
  trunks.each do |trunk|
    git_ok("config --add stack.trunk #{sh(trunk)}")
  end
end

# Auto-detect a single trunk: prefer the remote's default branch, then
# main/master. Dies when none can be determined.
def detect_trunk
  head = git_out("symbolic-ref --quiet --short refs/remotes/origin/HEAD")
  if !head.empty?
    trunk = head.sub(/^origin\//, "")
  elsif branch_exists?("main")
    trunk = "main"
  elsif branch_exists?("master")
    trunk = "master"
  else
    die("cannot determine trunk branch; run '#{PROG} init <branch>'")
    trunk = "" # unreachable: die exits
  end
  trunk
end

# Every trunk, auto-detecting and caching one on first use.
def trunk_branches
  list = configured_trunks
  return list unless list.empty?

  trunk = detect_trunk
  # `.to_s` (identity for the String this always is) gives the array literal
  # a concrete String element type. Seeding it with a user-defined method's
  # return -- still an unresolved inference variable at this point -- passes
  # that transiently-untyped element through set_trunks' block into sh's
  # parameter, locking sh onto the boxed untyped slow path (same failure mode
  # as paint's, see there).
  set_trunks([trunk.to_s])
  [trunk]
end

# The primary trunk -- the default base a branch falls back to (the first
# configured trunk).
#
# The first value is picked with an accumulator loop rather than indexing
# `trunk_branches` with `[0]`: this result flows into `checkout` and
# `git config`, and Spinel mistypes an array element read there as a
# compile-time constant, breaking the native build.
def primary_trunk
  first = ""
  configured_trunks.each do |trunk|
    first = trunk if first.empty?
  end
  return first unless first.empty?

  detected = detect_trunk
  # `.to_s` for the same reason as in trunk_branches: keep sh off the
  # untyped slow path.
  set_trunks([detected.to_s])
  detected
end

# True when `branch` is one of the configured trunks.
def is_trunk?(branch, trunks)
  trunks.include?(branch)
end

# --- stack metadata ---------------------------------------------------------

def get_parent(branch)
  git_out("config --get branch.#{sh(branch)}.stackParent")
end

# Record `parent` as the parent of `branch`; return true on success.
def set_parent(branch, parent)
  git_ok("config branch.#{sh(branch)}.stackParent #{sh(parent)}")
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
  git_out("config --get-regexp '^branch\\..*\\.stackparent$'")
end

# Set of every local branch name, fetched with a single `git` subprocess.
#
# `tree` calls `branch_exists?` for every node it renders; on a stack of N
# branches that means N extra `git show-ref` subprocesses (each a shell +
# git fork/exec, ~10ms). Capturing the full branch list once and checking
# it in memory removes that per-node cost, mirroring how `scan_stack_config`
# avoids re-spawning `git config` per node.
def existing_branches
  out = git_out("for-each-ref --format='%(refname:short)' refs/heads/")
  set = Set.new
  out.split("\n").each do |name|
    next if name.empty?

    set.add(name)
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
    next if branches.include?(value)

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
def stack_root(branch, trunks)
  seen = Set.new
  loop do
    seen.add(branch)
    parent = get_parent(branch)
    break if parent.empty? || is_trunk?(parent, trunks)
    break unless branch_exists?(parent)
    break if seen.include?(parent)

    branch = parent
  end
  branch
end

# True if making `new_parent` the parent of `branch` would create a cycle --
# that is, `branch` already lies on `new_parent`'s chain of ancestors.
def would_cycle?(branch, new_parent, trunks)
  seen = Set.new
  cur = new_parent
  loop do
    return true if cur == branch
    break if cur.empty? || is_trunk?(cur, trunks)
    break if seen.include?(cur)
    break unless branch_exists?(cur)

    seen.add(cur)
    cur = get_parent(cur)
  end
  false
end

# Validate that `candidate` can become the parent of `branch`: it must exist,
# must not be `branch` itself, and must not create a cycle. `verb` customizes
# the cycle-error wording for the calling command.
def validate_new_parent!(branch, candidate, trunks, verb)
  die("branch '#{candidate}' does not exist") unless branch_exists?(candidate)
  die("a branch cannot be its own parent") if candidate == branch
  die("'#{candidate}' is downstream of '#{branch}'; #{verb} would create a cycle") if would_cycle?(branch, candidate, trunks)
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
  if !parent.empty? && branches.include?(parent)
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
  if args.empty?
    trunks = trunk_branches
    info "trunk(s): #{trunks.join(", ")}"
    return
  end
  args.each do |trunk|
    die("branch '#{trunk}' does not exist") unless branch_exists?(trunk)
  end
  set_trunks(args)
  info "trunk set to #{args.join(", ")}"
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
  trunks = trunk_branches
  cur = current_branch_or_empty
  scan = scan_stack_config
  branches = existing_branches
  primary = trunks[0]

  # Each trunk is a visual root; its children are the stack roots resting on it.
  trunks.each do |trunk|
    puts "#{tree_marker(trunk, cur)} #{tree_name(trunk, cur, "36")} #{dim("(trunk)")}"

    children_from(scan, trunk).each do |child|
      print_subtree(child, "  ", cur, primary, scan, branches)
    end
  end

  orphan_roots(scan, branches).each do |child|
    print_subtree(child, "  ", cur, primary, scan, branches)
  end
end

def cmd_parent(args)
  branch = current_branch
  new_parent = arg0(args)
  if new_parent.empty?
    puts effective_parent(branch, primary_trunk)
    return
  end
  validate_new_parent!(branch, new_parent, trunk_branches, "setting it as parent")
  die("failed to set parent of '#{branch}'") unless set_parent(branch, new_parent)
  info "parent of '#{branch}' set to '#{new_parent}'"
end

def cmd_track(args)
  branch = current_branch
  trunks = trunk_branches
  parent = arg0(args)
  parent = trunks[0] if parent.empty?
  validate_new_parent!(branch, parent, trunks, "tracking it")
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
  parent = effective_parent(branch, primary_trunk)
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
  return if visited.include?(branch)
  visited.add(branch)

  parent = parent_from(scan, branch)

  if heal_orphans && !parent.empty? && !branches.include?(parent)
    info "'#{branch}': parent '#{parent}' no longer exists; reparenting onto trunk '#{trunk}'"
    die("failed to reparent '#{branch}'") unless set_parent(branch, trunk)
    parent = trunk
  end

  if !parent.empty? && branches.include?(parent)
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
  # An explicit nil: with the recursive `each` as the bare trailing
  # expression, the return type refers back to the method's own (not yet
  # resolved) type and Spinel widens it to untyped (slow path).
  nil
end

def cmd_restack(_args)
  original = current_branch
  trunks = trunk_branches
  root = stack_root(original, trunks)

  info "restacking stack rooted at #{cyan(root)}"
  scan = scan_stack_config
  branches = existing_branches
  restack_subtree(root, scan, Set.new, trunks[0], false, branches)

  unless git_ok("checkout #{sh(original)}")
    die("restack completed, but returning to '#{original}' failed;\n" \
        "you are now on '#{current_branch_or_empty}'. Check out '#{original}' manually.")
  end
  info green("done.")
end

def cmd_sync(_args)
  original = current_branch
  trunks = trunk_branches
  root = stack_root(original, trunks)

  info "syncing stack rooted at #{cyan(root)}"
  scan = scan_stack_config
  branches = existing_branches
  restack_subtree(root, scan, Set.new, trunks[0], true, branches)

  unless git_ok("checkout #{sh(original)}")
    die("sync completed, but returning to '#{original}' failed;\n" \
        "you are now on '#{current_branch_or_empty}'. Check out '#{original}' manually.")
  end
  info green("done.")
end

def cmd_version(_args)
  puts "#{PROG} #{VERSION}"
  # Only the Spinel-compiled binary was "built with" Spinel; run as a plain
  # Ruby script there is no build toolchain to report. Spinel is the only
  # engine whose RUBY_DESCRIPTION is "spinel" (CRuby names its own version),
  # so key on that.
  return unless RUBY_DESCRIPTION == "spinel"

  # SPINEL_REF is stamped at build time; an un-stamped build leaves it empty.
  # The 12-char slice matches `spinel --version`'s short rev.
  rev = SPINEL_REF.empty? ? "unknown" : SPINEL_REF[0...12]
  puts "built with spinel #{rev}"
end

def cmd_help(_args)
  puts <<~HELP
    #{bold(PROG)} -- manage stacked branches with plain git

    #{bold("USAGE")}
        #{PROG} <command> [args]

    #{bold("COMMANDS")}
        init [branch...]      Set (or auto-detect) the trunk branch(es).
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

# Parse the global flags (-h/--help, -v/--version) out of `argv` with
# OptionParser, returning the command they map to ("help"/"version"), or ""
# when no flag was given. Flags are removed from `argv` in place and may
# appear anywhere (`tree -v` prints the version), as usual for optparse.
#
# Spinel's optparse package is an exact-match subset of CRuby's: no option
# clustering (`-hv`), no long-option abbreviation (`--ver`), no `--`
# terminator -- so registered flags must be spelled out in full -- and its
# `parse!` leaves an unknown flag in argv instead of raising. The leftover
# check below reports such a flag with the same message CRuby's
# InvalidOption carries, keeping the script and the compiled binary aligned.
def parse_global_flags(argv)
  cmd = ""
  parser = OptionParser.new
  parser.on("-h", "--help") { |_| cmd = "help" }
  parser.on("-v", "--version") { |_| cmd = "version" }
  begin
    parser.parse!(argv)
  rescue OptionParser::ParseError => e
    die(e.message)
  end
  argv.each do |arg|
    die("invalid option: #{arg}") if arg.start_with?("-")
  end
  cmd
end

def main(argv)
  cmd = parse_global_flags(argv)
  rest = []
  if cmd.empty?
    cmd = argv.empty? ? "help" : argv[0]
    rest = argv.empty? ? [] : argv[1..-1]
  end

  repo_optional = cmd == "version" || cmd == "help"
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
  when "version"              then cmd_version(rest)
  when "help"                 then cmd_help(rest)
  else
    die("unknown command '#{cmd}' (try '#{PROG} help')")
  end
  # An explicit nil: as the bare trailing expression the case would be the
  # return value, and its branches' mixed types (nil from most cmd_*
  # handlers, Array[String] from cmd_tree) widen to untyped (slow path).
  nil
end

main(ARGV)
