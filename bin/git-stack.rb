#!/usr/bin/env ruby
# frozen_string_literal: true
#
# git-stack -- manage stacked branches with plain git.
#
# A "stack" is a chain of branches where each branch records a parent and the
# commit its parent sat at when the branch was stacked. Both are stored in git
# config as:
#
#     branch.<name>.stackParent = <parent-branch>
#     branch.<name>.stackBase   = <sha>
#
# stackBase pins where the branch's own commits begin, so `restack` replays
# exactly those commits with `git rebase --onto <parent> <base>`. This matters
# when a parent is squash-merged into trunk and deleted: a plain rebase would
# re-apply the parent's already-merged commits (their patch-ids no longer match
# after squashing, so git can't drop them) and conflict, whereas `--onto` skips
# everything below the recorded base.
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

# Every git call goes through one of the three wrappers below. Pick by
# answering two questions in order:
#
#   1. Do you need the command's OUTPUT, or just whether it SUCCEEDED?
#        output   -> git_out  (returns the trimmed stdout as a String)
#        success  -> a bool wrapper; go to question 2
#   2. (bool only) Should git's output be shown to the user, or swallowed?
#        swallow  -> git_ok   (quiet; the common case for internal checks)
#        show     -> git_run  (git's own messages reach the terminal)
#
# git_run is the rare one -- reach for it only when git's own message is the
# point (currently just `checkout!`, for "Switched to branch").

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
# `print_tree_row`/`restack_subtree` for the pattern).
def branch_exists?(name)
  git_ok("show-ref --verify --quiet refs/heads/#{sh(name)}")
end

# Count of commits reachable from `to` but not `from` (git rev-list from..to).
def commit_count(range_from, range_to)
  git_out("rev-list --count #{sh(range_from)}..#{sh(range_to)}").to_i
end

# [behind, ahead] commit counts between `branch` and `parent`, in a single
# `git rev-list --left-right --count` call instead of two separate
# `commit_count` calls.
#
# `tree` no longer calls this per node -- it batches every node's counts into
# one `git for-each-ref` (see scan_ahead_behind) and only falls back here on
# git too old for that atom. It is still the per-branch path for `restack`'s
# up-to-date check (via commit_count) and remains correct for one-off use.
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
  return head.sub(/^origin\//, "") unless head.empty?
  return "main" if branch_exists?("main")
  return "master" if branch_exists?("master")

  die("cannot determine trunk branch; run '#{PROG} init <branch>'")
  "" # unreachable: die exits, but every path must still yield a String
end

# Every trunk, auto-detecting and caching one on first use.
def trunk_branches
  list = configured_trunks
  return list unless list.empty?

  trunk = detect_trunk
  set_trunks([trunk])
  [trunk]
end

# The primary trunk -- the default base a branch falls back to: the first
# configured trunk, auto-detected and cached on first use exactly as
# `trunk_branches` does it (this reads that list rather than repeating its
# detect-and-persist fallback, so the two can't disagree on what the trunk is).
def primary_trunk
  trunk_branches[0]
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

# The recorded stack base of `branch`: the SHA its parent sat at when the
# branch was stacked. "" when none is recorded (a branch predating stackBase,
# or one whose merge-base could not be determined at reparent time).
def get_base(branch)
  git_out("config --get branch.#{sh(branch)}.stackBase")
end

# Record `sha` as the stack base of `branch` -- the point its own commits
# begin, replayed from by `git rebase --onto`. Return true on success.
def set_base(branch, sha)
  git_ok("config branch.#{sh(branch)}.stackBase #{sh(sha)}")
end

def clear_base(branch)
  git_ok("config --unset branch.#{sh(branch)}.stackBase")
end

# Record the stack base when (re)parenting an EXISTING branch (`parent`/`track`).
# Unlike `create`, the branch may already have diverged from its new parent, so
# the base is the merge-base of `branch` and `parent`, not the parent's tip.
# When they share no common ancestor (unrelated histories) leave stackBase unset
# and warn -- `restack` then falls back to a fresh merge-base at replay time.
def record_reparent_base(branch, parent)
  base = git_out("merge-base #{sh(branch)} #{sh(parent)}")
  if base.empty?
    info "warning: no common ancestor of '#{branch}' and '#{parent}'; stack base not recorded"
    return
  end
  set_base(branch, base)
  nil
end

# Point `branch` at `parent` and re-anchor its stack base, as one step. These
# two always belong together: a branch left pointing at a new parent with a base
# from the old one replays the wrong range at restack time (and breaks outright
# if the old base's history is later deleted). `err` is the message to die with
# when the parent can't be recorded, so each command keeps its own wording.
#
# `restack_subtree` deliberately does NOT come through here -- it records the
# base itself, from the parent's tip, after a successful rebase.
def reparent!(branch, parent, err)
  die(err) unless set_parent(branch, parent)
  record_reparent_base(branch, parent)
  nil
end

# Drop every stack key for `branch`. Parent and base are cleared as a unit, so a
# branch can never keep a base pointing into a stack it no longer belongs to.
def untrack!(branch)
  clear_parent(branch)
  clear_base(branch)
  nil
end

# One scan of git config listing every `branch.<name>.stackParent` entry.
#
# The tree and restack recursions look up a node's children at every step;
# StackContext parses this scan once up front so the recursion reads it in
# memory instead of re-spawning `git` per node (an O(N^2) subprocess blow-up on
# a stack of N branches).
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

# Return every branch that records `parent` as its parent. Builds a throwaway
# StackContext (a single config scan, no ahead/behind git walk) -- the one-shot
# path used by `up`, distinct from the shared context `tree`/`restack`/`sync`
# build once and thread through their recursion.
def children_of(parent)
  StackContext.build_topology.children_of(parent)
end

# The single home of the "a branch with no recorded parent rests on the trunk"
# rule. Every path that resolves an effective parent funnels through here: the
# single-command `parent`/`down` (`effective_parent`, one `git` subprocess) and
# the in-memory tree/count traversal (`StackContext#effective_parent_of`, off the
# pre-captured config snapshot). Keeping it in one place is the whole point --
# display, counts, and navigation can no longer drift on what a branch's parent
# effectively is (the rule used to sit, copied, in three separate spots).
#
# Threading one rule through both the subprocess wrappers and the StackContext
# methods unifies their branch-name parameters with its result, which pulls the
# `git`-wrapper family (`sh`, `checkout!`, `branch_exists?`, `ahead_behind`) and
# `StackContext#branch?` onto Spinel's untyped slow path. Those five signatures
# are pinned back to concrete types by the hand-written seed in rbs/ (fed to the
# compiler via `--rbs`, which `spin` and the CI golden check pass) -- so the
# binary stays on the fast path and the emitted golden gains no new untyped. See
# rbs/git-stack.rbs.
def effective_parent_rule(parent, trunk)
  parent.empty? ? trunk : parent
end

# The parent used for display and navigation, resolved with one `git` subprocess:
# the recorded parent, or the trunk when none is recorded. The single-command
# path for `parent`/`down`.
def effective_parent(branch, trunk)
  effective_parent_rule(get_parent(branch), trunk)
end

# Walk down from `branch` to the root of its stack (the branch whose parent is
# the trunk or is untracked). Returns the root branch name.
#
# Reads the pre-captured `ctx` instead of spawning `git config` + `git show-ref`
# per level (the two-subprocess-per-node pattern `branch_exists?` warns against):
# its callers build a StackContext for the traversal that follows anyway, and it
# already holds the parent map and branch set this walk needs.
#
# `seen` guards against cyclic parent chains (e.g. A -> B -> A) left over from
# older versions or hand-edited config, so we terminate instead of hanging.
def stack_root(ctx, branch, trunks)
  seen = Set.new
  loop do
    seen.add(branch)
    parent = ctx.parent_of(branch)
    break if parent.empty? || is_trunk?(parent, trunks)
    break unless ctx.branch?(parent)
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

# How many branches per batched `git for-each-ref` in scan_ahead_behind.
#
# Each batch's captured output must stay well under Spinel's ~4 KB backtick
# cap (a compiled binary's backticks read a single ~4 KB chunk, silently
# dropping the rest -- verified against the toolchain). A batch emits at most
# CHUNK rows of at most CHUNK+1 numeric columns, so its bytes grow as CHUNK^2;
# 12 keeps a batch comfortably small (~2 KB worst case) while still turning one
# git call into a dozen branches' worth of counts.
AHEAD_BEHIND_CHUNK = 12

# The distinct parents in `group` (up to AHEAD_BEHIND_CHUNK "<branch>\t<parent>"
# lines), newline-joined -- one entry per `%(ahead-behind:<parent>)` atom column
# the batch's for-each-ref will emit. Kept newline-PACKED as a String, scanned
# with `.each` block variables and never indexed as an Array[String] (whose
# element reads Spinel widens to untyped; see scan_ahead_behind).
def ahead_behind_bases(group)
  bases = ""
  group.split("\n").each do |pl|
    next if pl.empty?

    tab = pl.index("\t")
    next if tab.nil?

    parent = pl[(tab + 1)..-1]
    known = false
    bases.split("\n").each do |b|
      known = true if b == parent
    end
    bases = "#{bases}#{parent}\n" unless known
  end
  bases
end

# The `refs/heads/...` argument tail for the batch's for-each-ref: every branch
# named in `group`, shell-quoted and space-joined. Same string-packed, never
# Array[String]-indexed idiom as ahead_behind_bases (see scan_ahead_behind).
def ahead_behind_refs(group)
  refs = ""
  group.split("\n").each do |pl|
    next if pl.empty?

    tab = pl.index("\t")
    next if tab.nil?

    branch = pl[0...tab]
    refs = "#{refs} refs/heads/#{sh(branch)}"
  end
  refs
end

# Read one batch's for-each-ref `output` back into "<branch>\t<behind>\t<ahead>"
# lines. Each row is "<branch>\t<col0>\t<col1>..."; the branch's own parent (from
# `group`) selects which `bases` column carries its "<ahead> <behind>" pair. All
# string slicing plus `.each` block variables -- no Array[String] indexing (see
# scan_ahead_behind).
def ahead_behind_readback(output, group, bases)
  result = ""
  output.split("\n").each do |row|
    next if row.empty?

    tab = row.index("\t")
    next if tab.nil?

    branch = row[0...tab]
    rest = row[(tab + 1)..-1]

    # This branch's parent (from the group), then that parent's column number.
    parent = ""
    group.split("\n").each do |pl|
      ptab = pl.index("\t")
      next if ptab.nil?

      parent = pl[(ptab + 1)..-1] if pl[0...ptab] == branch
    end
    next if parent.empty?

    idx = -1
    n = 0
    bases.split("\n").each do |b|
      next if b.empty?

      idx = n if b == parent
      n += 1
    end
    next if idx < 0

    # The idx-th tab-separated ahead-behind column ("<ahead> <behind>").
    col = ""
    c = 0
    rest.split("\t").each do |f|
      col = f if c == idx
      c += 1
    end
    next if col.empty?

    # The atom prints "<ahead> <behind>"; the consumer wants [behind, ahead].
    ab = col.split(" ")
    next if ab.length != 2

    result = "#{result}#{branch}\t#{ab[1].to_i}\t#{ab[0].to_i}\n"
  end
  result
end

# One batch of scan_ahead_behind: `group` is up to AHEAD_BEHIND_CHUNK
# "<branch>\t<parent>" lines. Runs a single `git for-each-ref` listing those
# branches, with one `%(ahead-behind:<parent>)` atom per distinct parent in the
# group, then reads back each branch's own parent column. Returns
# "<branch>\t<behind>\t<ahead>" lines (empty on git older than 2.41, where the
# atom is unknown and the call fails -- print_tree_row then falls back per node).
def ahead_behind_chunk(group)
  refs = ahead_behind_refs(group)
  return "" if refs.empty?

  bases = ahead_behind_bases(group)
  fmt = "%(refname:short)"
  bases.split("\n").each do |b|
    next if b.empty?

    fmt = "#{fmt}\t%(ahead-behind:#{b})"
  end

  out = git_out("for-each-ref --format=#{sh(fmt)}#{refs}")
  ahead_behind_readback(out, group, bases)
end

# Parse a `scan_ahead_behind` result string once into a name -> "behind\tahead"
# index, so each node's lookup is O(1) instead of re-splitting and re-scanning
# the whole result per node (an O(N^2) blow-up on a stack of N branches, mirroring
# the one StackContext's parent/child indexes remove for the config scan).
#
# The counts are kept as the packed "<behind>\t<ahead>" string they already
# arrive in, not as an `Array[Integer]` value: a hash whose values are read back
# out stays a concrete `Hash[String, String]` in Spinel's emitted signatures,
# whereas an array-valued hash widens to untyped (the same reason `ab` itself
# stays a String rather than an `Array[String]`; see scan_ahead_behind).
# `StackContext#ahead_behind_of` unpacks the pair back into a fresh `Array[Integer]`.
def ahead_behind_index(ab)
  index = {}
  ab.split("\n").each do |line|
    next if line.empty?

    fields = line.split("\t")
    next if fields.length != 3

    index[fields[0]] = "#{fields[1]}\t#{fields[2]}"
  end
  index
end

# One snapshot of the stack, captured up front and threaded through the tree /
# restack / sync recursions in place of the loose `index` / `branches` /
# `ab_index` triple those used to pass around by hand.
#
# It bundles the git state a traversal reads repeatedly:
#
#   @parents   branch -> recorded parent           (from the config scan)
#   @branches  the set of existing local branches   (existing_branches)
#   @children  parent -> "<child>\n<child>\n..."    (`@parents` inverted)
#   @ab        branch -> "<behind>\t<ahead>"        (ahead_behind_index)
#   @trunk     the primary trunk a parentless branch falls back to (`build`'s arg)
#
# `@trunk` is what lets the in-memory traversal resolve a parentless branch to
# the trunk through the shared `effective_parent_rule`, the same rule the
# single-command `parent`/`down` path uses -- so the tree's display, its
# ahead/behind counts, and navigation never disagree on a branch's parent.
#
# `@children` is newline-PACKED, and that packing is what makes it a field at
# all: the child relationship is `@parents` inverted, and holding it as the
# `Hash[String, Array[String]]` an array value would force widens to
# `Hash[String, untyped]` (Spinel has no tag for it) -- pollution that used to
# bleed through `children_of` into every traversal. Packed, it is a concrete
# `Hash[String, String]`, exactly like `@ab`, so it is built once by
# `index_children` at `load` time rather than re-inverted on every `order` /
# `children_of` call. Callers read a row back with `.split("\n")` into a fresh
# `Array[String]`; that split is where the concrete element type is
# (re)introduced. `order` walks it to yield a stack's traversal order;
# `children_of` reads one node's row.
#
# Every lookup is in memory, so a whole traversal costs the two or three `git`
# calls `build` makes up front rather than a subprocess per node. Splitting the
# old `[parents, children]` Array into named fields also drops the
# `index[0]` / `index[1]` positional reads Spinel widened to untyped.
#
# Build it once per command with `build` (with ahead/behind counts, for `tree`)
# or `build_topology` (topology only, for restack/sync, which navigate the
# stack but never render counts and so skip the ahead/behind git walk).
class StackContext
  def initialize
    @parents = {}
    @branches = Set.new
    @children = {}
    @ab = {}
    @trunk = ""
    # Explicit nil: without it the trailing `@trunk = ""` assignment would be
    # the initializer's value and Spinel infers `initialize` as returning
    # String. Pinning it to nil keeps the emitted signature `() -> nil`.
    nil
  end

  # Full snapshot including ahead/behind counts, for `tree`. The `scan` is parsed
  # exactly once (into `@parents`); the ahead/behind walk then builds its branch
  # pairs from `@parents`, not by re-parsing the raw config a second time.
  def self.build(trunk)
    ctx = new
    ctx.load(scan_stack_config)
    ctx.load_ahead_behind(trunk)
    ctx
  end

  # Topology and branch existence only -- no ahead/behind git walk. For
  # restack/sync (which never render counts) and the one-shot `children_of`.
  def self.build_topology
    ctx = new
    ctx.load(scan_stack_config)
    ctx
  end

  # Parse one `scan_stack_config` string into the parent and child indexes and
  # capture the existing-branch set. Note: git lowercases the variable-name
  # portion of a config key, so the stored key is `branch.<name>.stackparent`
  # even though we write `stackParent`.
  def load(scan)
    @branches = existing_branches
    scan.split("\n").each do |line|
      next if line.empty?

      space = line.index(" ")
      next if space.nil?

      key = line[0...space]
      value = line[(space + 1)..-1]
      name = key.sub(/^branch\./, "").sub(/\.stackparent$/, "")
      @parents[name] = value
    end
    index_children
    nil
  end

  # Invert `@parents` into the packed `@children` index, once per context. The
  # traversal looks up a node's children at every step, so this is built here
  # rather than re-derived per `order` / `children_of` call (`tree` alone drives
  # one walk per trunk and one per orphan root).
  def index_children
    @parents.each do |name, value|
      next if value.empty?

      row = @children[value]
      @children[value] = row.nil? ? "#{name}\n" : "#{row}#{name}\n"
    end
    nil
  end

  # Record the fallback trunk and populate the ahead/behind index from a batched
  # `git for-each-ref` walk (see `scan_ahead_behind`). `@trunk` is set first
  # because `scan_ahead_behind` reads it (through `effective_parent_of`) to know
  # where a parentless branch rests.
  def load_ahead_behind(trunk)
    @trunk = trunk
    @ab = ahead_behind_index(scan_ahead_behind)
    nil
  end

  # The parent recorded for `branch`, or "" when none is recorded.
  def parent_of(branch)
    parent = @parents[branch]
    parent.nil? ? "" : parent
  end

  # The effective parent of `branch` for display, navigation, and counts: its
  # recorded parent, or `@trunk` when none is recorded. The in-memory entry point
  # to the shared `effective_parent_rule` -- `print_tree_row` and
  # `scan_ahead_behind` both resolve through here, so the tree's display and its
  # counts read a branch's parent the exact same way the single-command path does
  # (see `effective_parent_rule` for the seed that keeps this off the slow path).
  def effective_parent_of(branch)
    effective_parent_rule(parent_of(branch), @trunk)
  end

  # Precompute [behind, ahead] for every branch against its effective parent in a
  # HANDFUL of batched `git for-each-ref` calls, instead of one `git rev-list` per
  # tree node (an O(N) subprocess blow-up -- the dominant cost of a large tree,
  # since every other lookup was already collapsed into a single `git` call).
  #
  # It reads the `@parents` snapshot `load` already built rather than re-parsing
  # the raw config scan a second time: one `"<branch>\t<parent>"` line per branch
  # whose effective parent exists as a branch, each resolved through the same
  # `effective_parent_of` the per-node tree render uses, so the counts computed
  # here and the parent shown there can never disagree.
  #
  # `git for-each-ref`'s `%(ahead-behind:<base>)` atom reports "<ahead> <behind>"
  # for every listed ref against <base> in one graph walk. Each branch rests on
  # its own parent, so we process branches in chunks of AHEAD_BEHIND_CHUNK: one
  # call per chunk, listing that chunk's refs with one atom per distinct parent in
  # it, then reading back each branch's own parent column. That is ~N/12 git calls
  # instead of N -- and, crucially, bounds each call's output so it never trips the
  # ~4 KB backtick cap that a single all-branches-by-all-parents call (O(N^2)
  # output) would blow past on a stack of more than a couple dozen branches.
  #
  # Returns one `"<branch>\t<behind>\t<ahead>"` line per branch, parsed back by
  # `ahead_behind_index` into `@ab` and read via `ahead_behind_of`. Tabs are safe
  # separators: git refnames cannot contain control characters, and the atom's own
  # output is just two space-separated numbers.
  #
  # The atom requires git 2.41+. On older git `for-each-ref` fails, a chunk yields
  # nothing, and `print_tree_row` falls back to the per-node `ahead_behind` for its
  # branches -- so the tree still renders correctly (just without the batching
  # win). A branch whose name breaks the atom's `)`-terminated argument fails the
  # same closed way, only for its own chunk.
  def scan_ahead_behind
    # "<branch>\t<parent>" lines for branches whose effective parent exists as a
    # branch. Held as one string and processed with the same string-slicing idiom
    # as the config scan itself -- deliberately NOT as an Array[String], whose
    # element reads Spinel widens to untyped (and that widening bleeds into the
    # emitted Set signatures; see test/git-stack.rbs.expected).
    pairs = ""
    @parents.each do |name, value|
      next unless @branches.include?(name)

      parent = effective_parent_of(name)
      next if parent.empty? || !@branches.include?(parent)

      pairs = "#{pairs}#{name}\t#{parent}\n"
    end

    # One batched `git for-each-ref` per AHEAD_BEHIND_CHUNK branches, so each
    # call's captured output stays well under Spinel's ~4 KB backtick cap.
    result = ""
    count = 0
    group = ""
    pairs.split("\n").each do |pl|
      next if pl.empty?

      group = "#{group}#{pl}\n"
      count += 1
      if count == AHEAD_BEHIND_CHUNK
        result = "#{result}#{ahead_behind_chunk(group)}"
        group = ""
        count = 0
      end
    end
    result = "#{result}#{ahead_behind_chunk(group)}" unless group.empty?
    result
  end

  # Sorted list of branches that record `branch` as their parent (empty when
  # none do). Reads one row of the packed `@children` index and splits it into
  # a concrete `Array[String]`; the `.sort` both orders siblings deterministically
  # and pins the element type (a poly array would raise on `sort` at run time).
  #
  # The row is a String (`index_children` packs each value as one), but a `.to_s`
  # guards the split: newer Spinel can widen `@children` to `Hash[String,
  # untyped]`, handing back a boxed poly whose `.split` result types as
  # `unknown` -- and `.each` on `unknown` is a compile-time-baked
  # `NoMethodError` ("undefined method 'each' for unknown"). `.to_s` re-narrows
  # it to a concrete String so the split stays `Array[String]`. It is a no-op
  # under the pinned Spinel, where the value is already a String.
  def children_of(branch)
    row = @children[branch]
    return [] if row.nil?

    names = []
    row.to_s.split("\n").each do |name|
      names << name unless name.empty?
    end
    names.sort
  end

  # The whole subtree rooted at `root`, in DFS pre-order (each parent before its
  # children, siblings sorted), packed one `"<depth>\t<branch>"` line per node
  # with `root` itself at depth 0. This replaces the old per-node `children_of`
  # recursion that `tree` and `restack` drove: they now split this once and loop
  # flat, so the indent (tree) or nothing (restack) is a single `Integer` depth
  # instead of a threaded prefix string, and the cycle guard lives here once.
  def order(root)
    walk_order(root, 0, Set.new, "")
  end

  # The same pre-order walk as `order`, with the depth dropped: just the branch
  # names, `root` first. For the callers that traverse a subtree but never
  # render it (`restack_subtree`), so the packed `"<depth>\t<branch>"` line
  # format has exactly one decoder (`print_order`) instead of two that must
  # agree. The split introduces the concrete element type, as in `children_of`.
  def order_branches(root)
    names = []
    order(root).split("\n").each do |line|
      next if line.empty?

      tab = line.index("\t")
      next if tab.nil?

      names << line[(tab + 1)..-1]
    end
    names
  end

  # Append `branch` (at `depth`) and its descendants to `acc` in pre-order,
  # reading children from the packed `@children` index. `visited` guards against
  # cyclic parent chains (A -> B -> A from hand-edited config) so the walk
  # terminates and emits each branch at most once. `acc` is threaded and returned
  # rather than mutated in place; the interpolation keeps its type a concrete
  # String.
  def walk_order(branch, depth, visited, acc)
    return acc if visited.include?(branch)
    visited.add(branch)
    acc = "#{acc}#{depth}\t#{branch}\n"

    row = @children[branch]
    return acc if row.nil?

    # `.to_s` before the split for the same reason as `children_of`: newer
    # Spinel can widen this index to `Hash[String, untyped]`, and `.split` on
    # the boxed poly it hands back types as `unknown`, which bakes a
    # `NoMethodError` ("undefined method 'each' for unknown") at the `.each`.
    # Re-narrowing to a String keeps the split `Array[String]`; no-op under the
    # pinned Spinel.
    row.to_s.split("\n").sort.each do |child|
      next if child.empty?

      acc = walk_order(child, depth + 1, visited, acc)
    end
    acc
  end

  # True when `name` is an existing local branch.
  def branch?(name)
    @branches.include?(name)
  end

  # [behind, ahead] for `branch` from the ahead/behind index -- a single `Hash`
  # lookup. Returns the sentinel [-1, -1] when `branch` has no entry (e.g. git
  # too old for the batched atom, so the index was empty, or a context built
  # without counts), signalling `print_tree_row` to fall back to a per-node
  # `ahead_behind`. The pair is rebuilt into a fresh literal so the return type
  # stays a plain `Array[Integer]`, off Spinel's untyped slow path.
  def ahead_behind_of(branch)
    packed = @ab[branch]
    return [-1, -1] if packed.nil?

    fields = packed.split("\t")
    return [-1, -1] if fields.length != 2

    [fields[0].to_i, fields[1].to_i]
  end

  # Branches whose recorded parent is non-empty but no longer a real branch
  # (its parent was merged and deleted). Treated as extra roots by `tree` so
  # they're always visible instead of silently disappearing; `git stack sync`
  # is what actually repairs them.
  def orphan_roots
    names = []
    @parents.each do |name, value|
      next if value.empty?
      next if @branches.include?(value)

      names << name
    end
    names.sort
  end
end

# Print one tree row for `branch`, indented two spaces per `depth`.
#
# One node of the traversal, no recursion of its own: `cmd_tree` drives the
# order with `ctx.order` and calls this per line. `ctx` is the pre-built
# StackContext, so every parent / branch-existence / ahead-behind lookup is in
# memory and rendering the whole tree costs no `git` per node. The fallback
# trunk lives in `ctx`, so the effective parent is resolved through
# `effective_parent_of` (the same rule the counts were computed against) rather
# than a trunk threaded in alongside.
def print_tree_row(branch, depth, cur, ctx)
  extra = ""
  parent = ctx.effective_parent_of(branch)
  if !parent.empty? && ctx.branch?(parent)
    # Counts come from the single batched `git for-each-ref` (see
    # scan_ahead_behind), looked up in memory. The sentinel guards the git-too-
    # old case, where the index is empty and we fall back to a per-node call.
    behind, ahead = ctx.ahead_behind_of(branch)
    if behind < 0
      behind, ahead = ahead_behind(parent, branch)
    end
    if behind > 0
      extra = yellow("(needs restack: #{behind} behind)")
    elsif ahead > 0
      extra = dim("(#{ahead} commit(s))")
    end
  elsif !parent.empty?
    extra = yellow("(parent '#{parent}' missing; run `#{PROG} sync`)")
  end

  puts "#{"  " * depth}#{tree_marker(branch, cur)} #{tree_name(branch, cur, "")} #{extra}"
  nil
end

# Print the subtree `ctx.order(root)` produced, offset `base` levels deep.
# `tree` calls this once per trunk (base 0, and skipping the depth-0 root, which
# it prints itself with the trunk styling) and once per orphan root (base 1, so
# an orphaned stack renders at the same indent a trunk's children would).
def print_order(root, base, skip_root, cur, ctx)
  ctx.order(root).split("\n").each do |line|
    next if line.empty?

    tab = line.index("\t")
    next if tab.nil?

    depth = line[0...tab].to_i
    branch = line[(tab + 1)..-1]
    next if skip_root && depth == 0

    print_tree_row(branch, depth + base, cur, ctx)
  end
  nil
end

# --- subcommands ------------------------------------------------------------

# The first CLI argument, or "" when none was given.
def arg0(args)
  args.empty? ? "" : args[0]
end

# True when `flag` (e.g. "--delete") appears anywhere in `args`. Command-level
# flags reach a subcommand mixed in with its positional arguments (see
# COMMAND_FLAGS / parse_global_flags), so a command reads them by name rather
# than by position.
def has_flag?(args, flag)
  args.include?(flag)
end

# The first non-flag argument in `args`, or "" when there is none -- so a lone
# `drop --delete` (no branch named) still falls back to the current branch. A
# flag like `--delete` may appear before or after the branch name, so the branch
# can't just be `args[0]`.
def first_operand(args)
  name = ""
  args.each do |a|
    name = a if name.empty? && !a.start_with?("-")
  end
  name
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
  # The base is the parent's tip: a freshly created branch has no commits of its
  # own yet, so its stack begins exactly where the parent currently sits.
  set_base(name, git_out("rev-parse #{sh(parent)}"))
  info "created #{green(name)} on top of #{cyan(parent)}"
end

def cmd_tree(_args)
  trunks = trunk_branches
  cur = current_branch_or_empty
  primary = trunks[0]
  # One StackContext captures the whole stack up front -- topology, existing
  # branches, and every node's [behind, ahead] counts (the latter batched into a
  # few `git for-each-ref` calls, replacing one `git rev-list` per node) -- so
  # the loops below read it all in memory instead of re-spawning `git` per node.
  ctx = StackContext.build(primary)

  # Each trunk is a visual root; its children are the stack roots resting on it.
  # `order(trunk)` includes the trunk itself at depth 0, which we skip here --
  # the trunk row is printed with its own (cyan, "(trunk)") styling.
  trunks.each do |trunk|
    puts "#{tree_marker(trunk, cur)} #{tree_name(trunk, cur, "36")} #{dim("(trunk)")}"
    print_order(trunk, 0, true, cur, ctx)
  end

  # Orphaned stacks render as extra roots, indented one level (base 1) so they
  # line up with the stack roots that rest on a trunk.
  ctx.orphan_roots.each do |root|
    print_order(root, 1, false, cur, ctx)
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
  reparent!(branch, new_parent, "failed to set parent of '#{branch}'")
  info "parent of '#{branch}' set to '#{new_parent}'"
end

def cmd_track(args)
  branch = current_branch
  trunks = trunk_branches
  parent = arg0(args)
  parent = trunks[0] if parent.empty?
  validate_new_parent!(branch, parent, trunks, "tracking it")
  reparent!(branch, parent, "failed to track '#{branch}'")
  info "tracking '#{branch}' on top of '#{parent}'"
end

def cmd_untrack(_args)
  branch = current_branch
  untrack!(branch)
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

# Resolve the base commit to feed `git rebase --onto <parent> <base> <branch>`
# for one branch. The base is the commit the branch's own work begins at -- the
# point below which commits belong to the parent and must NOT be replayed.
#
# Prefers the recorded stackBase, but only when it still names a real commit
# that is an ancestor of `branch`: a base that was rewritten, or never an
# ancestor, would replay the wrong range. Otherwise (empty, stale, or not an
# ancestor) it falls back to the current merge-base of `branch` and `parent`.
#
# Returns "" only when even the merge-base is unavailable (unrelated histories,
# or a vanished parent during orphan heal), signalling the caller to fall back
# to a plain `git rebase <parent> <branch>` for backward compatibility.
def resolve_stack_base(branch, parent)
  base = get_base(branch)
  if !base.empty? &&
     git_ok("rev-parse --verify --quiet #{sh(base)}^{commit}") &&
     git_ok("merge-base --is-ancestor #{sh(base)} #{sh(branch)}")
    return base
  end
  return "" if parent.empty?

  git_out("merge-base #{sh(branch)} #{sh(parent)}")
end

# Rebase the whole stack rooted at `root` onto itself, each branch onto its
# parent, in `ctx.order_branches(root)` order (each parent before its children).
#
# The traversal order is fixed up front by `ctx.order_branches`, which also
# carries the cycle guard (a hand-edited A -> B -> A chain terminates and visits
# each branch once), so this is a flat loop over branch names rather than a
# recursion.
#
# `verb` is the subcommand to name when a rebase conflicts ("then re-run '#{PROG}
# <verb>'"). It is passed in rather than derived from `heal_orphans`, which is a
# behaviour knob and not the caller's identity: `drop` heals nothing yet must
# still send the user to `restack`, since its splice is already committed to
# config and re-running `drop` would be wrong.
#
# A branch with no recorded parent is untracked and is left untouched -- we do
# *not* fall back to rebasing it onto the trunk.
#
# When `heal_orphans` is true (used by `git stack sync`), a branch whose
# recorded parent no longer exists (e.g. it was merged and deleted) is
# reparented onto `trunk` before the rebase check runs. When false (used by
# `git stack restack`), such a branch is left untouched, same as before.
# Reparenting rewrites config but not `ctx` -- and an orphan is the root of its
# own subtree, so the pre-computed order still holds.
#
# `ctx` is a pre-captured StackContext (built with `build_topology`, no
# ahead/behind counts) so config parsing and existence checks don't spawn work
# per node -- safe because neither restack nor sync creates or deletes branch
# refs mid-traversal (sync only rewrites `stackParent` config, and rebase
# updates a branch's history in place without removing the ref).
def restack_subtree(root, trunk, heal_orphans, verb, ctx)
  ctx.order_branches(root).each do |branch|
    parent = ctx.parent_of(branch)

    if heal_orphans && !parent.empty? && !ctx.branch?(parent)
      info "'#{branch}': parent '#{parent}' no longer exists; reparenting onto trunk '#{trunk}'"
      die("failed to reparent '#{branch}'") unless set_parent(branch, trunk)
      parent = trunk
    end

    if !parent.empty? && ctx.branch?(parent)
      behind = commit_count(branch, parent)
      if behind == 0
        # Already on the parent's tip: nothing to replay. Self-heal the recorded
        # base to the parent's tip so a later parent advance replays from the
        # right point (this also back-fills branches that predate stackBase).
        set_base(branch, git_out("rev-parse #{sh(parent)}"))
      else
        info "restacking #{cyan(branch)} onto #{cyan(parent)}"
        # Replay only the branch's own commits (those above `base`) onto the
        # parent's tip. A plain `git rebase <parent>` would instead replay every
        # commit in `parent..branch`, re-applying a squash-merged parent's work
        # and conflicting; `--onto` with the recorded base avoids that.
        base = resolve_stack_base(branch, parent)
        if base.empty?
          # No usable base and no merge-base to derive one from: fall back to a
          # plain rebase (backward compat for branches with no recorded base).
          info "'#{branch}': no recorded stack base; rebasing onto '#{parent}'"
          ok = git_ok("rebase #{sh(parent)} #{sh(branch)}")
        else
          ok = git_ok("rebase --onto #{sh(parent)} #{sh(base)} #{sh(branch)}")
        end
        unless ok
          git_ok("rebase --abort")
          recover = base.empty? ? "git rebase #{parent}" : "git rebase --onto #{parent} #{base}"
          die("conflict while rebasing '#{branch}' onto '#{parent}'.\n" \
              "Resolve it manually with:\n" \
              "    git checkout #{branch} && #{recover}\n" \
              "then re-run '#{PROG} #{verb}'.")
        end
        # Rebase succeeded: the branch now sits on the parent's tip, so that
        # becomes its new base.
        set_base(branch, git_out("rev-parse #{sh(parent)}"))
      end
    end
  end
  nil
end

# The shared body of `restack` and `sync`: restack the stack the current branch
# belongs to, then return to it. The two commands are the same walk over the same
# stack and differ only in whether a branch whose parent was deleted is healed
# onto trunk first -- so `heal_orphans` is the only thing they pass, and the
# wording follows from it.
def run_stack_rebase(heal_orphans)
  verb = heal_orphans ? "sync" : "restack"
  gerund = heal_orphans ? "syncing" : "restacking"
  original = current_branch
  trunks = trunk_branches
  # Built before the root walk, which reads the stack's topology out of it
  # rather than re-deriving it with a subprocess per level.
  ctx = StackContext.build_topology
  root = stack_root(ctx, original, trunks)

  info "#{gerund} stack rooted at #{cyan(root)}"
  restack_subtree(root, trunks[0], heal_orphans, verb, ctx)

  unless git_ok("checkout #{sh(original)}")
    die("#{verb} completed, but returning to '#{original}' failed;\n" \
        "you are now on '#{current_branch_or_empty}'. Check out '#{original}' manually.")
  end
  info green("done.")
  nil
end

def cmd_restack(_args)
  run_stack_rebase(false)
end

def cmd_sync(_args)
  run_stack_rebase(true)
end

# Splice `branch` out of the stack graph: reconnect each of its children to
# `branch`'s own parent, untrack `branch`, and restack the moved subtrees. This
# is the first-class "the bottom of my stack merged, re-base the rest" move --
# run *while the merged branch still exists*, so its recorded parent (the true
# grandparent) is still readable and the children reconnect exactly, rather than
# the delete-then-`sync` order which only ever heals onto trunk.
#
# Non-destructive by default: it rewrites stack *config* only and never deletes
# the branch ref (that stays an explicit `git branch -d`). `--delete` is opt-in
# sugar for `git branch -D` after a successful splice. It also does no merge
# detection -- invoking `drop` IS the assertion that the branch is done.
#
# Contrast with `untrack`, which orphans the children; `drop` reconnects them to
# the grandparent. That is the whole difference.
def cmd_drop(args)
  delete = has_flag?(args, "--delete")
  operand = first_operand(args)
  branch = operand.empty? ? current_branch : operand
  trunks = trunk_branches
  die("cannot drop trunk '#{branch}'") if is_trunk?(branch, trunks)
  die("branch '#{branch}' does not exist") unless branch_exists?(branch)

  original = current_branch_or_empty

  # Where the children reconnect: the dropped branch's own parent, or the
  # primary trunk when it sat directly on a trunk (no recorded parent).
  parent = get_parent(branch)
  parent = trunks[0] if parent.empty?

  # Capture the children BEFORE rewriting config -- `branch.<child>.stackParent`
  # is about to change. Each child is reparented exactly as `parent`/`track` do
  # it: set_parent then record_reparent_base, which re-anchors stackBase to
  # merge-base(child, parent) so `restack`'s `--onto` replays from the right
  # point (leaving the old base pointing into the dropped parent's history would
  # replay the wrong range, and break outright if that ref is later deleted).
  moved = children_of(branch)
  moved.each do |child|
    reparent!(child, parent, "failed to reparent '#{child}' onto '#{parent}'")
  end

  # Untrack the dropped branch. Its ref is left intact -- deleting it stays an
  # explicit, separate act unless `--delete` was passed.
  untrack!(branch)
  info "dropped #{green(branch)}; reparented children onto #{cyan(parent)}"

  # Restack each moved subtree onto its new parent. Rebuild the topology first
  # so it reflects the config rewrites above.
  ctx = StackContext.build_topology
  moved.each do |child|
    # "restack", not "drop", on conflict: the splice above is already written to
    # config, so the move to recover with is a restack of the moved subtree.
    restack_subtree(child, trunks[0], false, "restack", ctx)
  end

  if delete
    # You can't delete the branch you're standing on; step onto its former
    # parent first (the restack above may have already moved HEAD to a child).
    git_ok("checkout #{sh(parent)}") if current_branch_or_empty == branch
    die("dropped '#{branch}' but failed to delete its ref") unless git_ok("branch -D #{sh(branch)}")
    info "deleted branch #{green(branch)}"
  end

  # Return to where we started when that branch still exists -- the restack may
  # have left HEAD on a moved child, and `--delete` may have removed `original`.
  if !original.empty? && original != current_branch_or_empty && branch_exists?(original)
    git_ok("checkout #{sh(original)}")
  end
  nil
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
        drop [branch]         Splice [branch] (or the current branch) out of the stack, reconnecting its children to its parent. (--delete also removes the branch)
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

    Stack metadata is stored in git config: branch.<name>.stackParent (the
    parent branch) and branch.<name>.stackBase (the commit the branch's own
    work begins at, so restack can `git rebase --onto <parent> <base>` and
    survive a parent that was squash-merged and deleted).
  HELP
end

# --- dispatch ---------------------------------------------------------------

# Command-level flags a subcommand consumes itself (as opposed to the global
# -h/-v). They ride through `parse_global_flags` untouched by its unknown-flag
# check so the command can read them out of its own args; currently only
# `drop --delete`. Kept explicit so a genuine typo like `--delet` is still
# rejected, and the tolerated set is visible in one place.
COMMAND_FLAGS = ["--delete"].freeze

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
  # Lift command-level flags (COMMAND_FLAGS, e.g. `drop --delete`) out before
  # global parsing: CRuby's `parse!` raises on any long option the parser
  # doesn't register, so an unregistered `--delete` would be reported as an
  # invalid *global* option before it ever reached the subcommand. Pulling them
  # aside here leaves `parse_global_flags` to handle only -h/-v (and still
  # reject genuine typos), then they are re-attached to the subcommand's args.
  flags = []
  cleaned = []
  argv.each do |a|
    if COMMAND_FLAGS.include?(a)
      flags << a
    else
      cleaned << a
    end
  end

  cmd = parse_global_flags(cleaned)
  rest = []
  if cmd.empty?
    cmd = cleaned.empty? ? "help" : cleaned[0]
    rest = cleaned.empty? ? [] : cleaned[1..-1]
  end
  flags.each { |f| rest << f }

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
  when "drop"                 then cmd_drop(rest)
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
