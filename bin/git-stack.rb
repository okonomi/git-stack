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
# version`. A compiled binary can't introspect its compiler's revision at run
# time, so the Homebrew formula stamps this line with the real `spinel
# --version` before `spin build` (see Formula/git-stack.rb). Left empty here as
# a placeholder; an un-stamped build reports "unknown".
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

  # The STDOUT constant, not the `$stdout` global: equivalent here, and the
  # piped (not-a-tty) path is the only one the snapshot tests can cover.
  STDOUT.tty?
end

USE_COLOR = color_enabled?

# Wrap `text` in the SGR sequence `code` (e.g. "32", "1"), resetting after.
# When colour is disabled this is the identity function, so callers never
# touch escape codes or the matching reset themselves.
def paint(code, text)
  # `.to_s` keeps Spinel's return type independent of `text`: `return text`
  # would tie them together, and the `bold(green(branch))` nesting in tree_name
  # then locks the whole colour-helper family to untyped.
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
  "'" + arg.to_s.gsub("'") { "'\\''" } + "'"
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
# so git's own messages (e.g. "Switched to branch") stay visible -- use this
# for the interactive commands whose output the user should see.
#
# The `$? == 0` is read on its own line, not as a trailing `system` call:
# Spinel drops the boolean when a bare `system` is a method's last expression.
# (Every wrapper that returns a status this way relies on the same rule.)
def git_run(subcmd)
  system("git #{subcmd}")
  $? == 0
end

# Capture the FULL stdout of `git <subcmd>`, however large, by routing it
# through a temp file (`File.read` has no cap) instead of a backtick.
#
# THE ~4 KB CAP. A Spinel-compiled binary's backtick keeps only the first ~4 KB
# and silently drops the rest (the same cap AHEAD_BEHIND_CHUNK stays under).
# Harmless for output bounded by construction (one SHA, one config value), but
# two scans grow with the repository -- the local branch list and the
# stack-config dump -- and truncating those yields a WRONG answer, not a smaller
# one: every branch past the cut reads as "does not exist", so `tree` shows live
# parents as missing, `restack` skips them, and `sync` reparents those healthy
# branches onto trunk, destroying the stack. This helper is where those two
# scans avoid the cap; downstream comments point back here.
#
# THE TEMP FILE. Created by us with O_EXCL at an unpredictable path (pid + random
# suffix), not left to the shell's `>` at a guessable one. On a shared /tmp
# (TMPDIR unset under cron/CI/sudo) a guessable `git-stack-scan-<pid>` let a
# hostile local user pre-place a symlink the redirect would follow -- clobbering
# a victim's file, or swapping the scan between write and read to inject a forged
# branch/stackParent dump that `sync` then executes as real rewrites and rebases.
# O_EXCL refuses to open through any pre-placed entry, so we only write a fresh
# file we own; the random suffix also stops concurrent runs colliding.
#
# `empty_ok` marks the ONE command whose non-zero exit is a legitimate empty
# result: `git config --get-regexp` exits non-zero when no key matches ("no
# branch tracked yet"). Every other caller passes false, so any non-zero status
# is a genuine I/O failure and dies (see the fail-closed note below).
def git_out_full(subcmd, empty_ok)
  dir = ENV["TMPDIR"]
  dir = "/tmp" if dir.nil? || dir.empty?

  path = ""
  file = nil
  attempts = 0
  while file.nil?
    attempts += 1
    die("could not create a private scan file under #{dir}") if attempts > 100
    candidate = "#{dir}/git-stack-scan-#{Process.pid}-#{rand(1_000_000_000)}"
    begin
      file = File.open(candidate, File::WRONLY | File::CREAT | File::EXCL, 0600)
      path = candidate
    rescue SystemCallError
      file = nil
    end
  end
  file.close

  # Fail closed: a partial/empty scan is a WRONG answer (see header). If git or
  # the redirect fails, an empty file that exits 0 is indistinguishable from "no
  # branches", and sync would then reparent the dropped branches onto trunk. So
  # unless git exited 0, clean up and die -- except for `empty_ok` callers, whose
  # non-zero exit is a real "no match". Any non-zero counts (not just exit 1):
  # only `$? == 0` reads identically under CRuby and Spinel. Own line, per git_run.
  system("git #{subcmd} > #{sh(path)} 2>/dev/null")
  ok = $? == 0
  out = File.read(path)
  File.delete(path)
  die("scan failed: git #{subcmd}") unless ok || empty_ok
  out.strip
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

# Spawns a `git` subprocess per call. Fine for one-off checks, but do NOT call
# it in a per-node loop over a stack -- use the pre-captured `existing_branches`
# set there instead (see `print_tree_row`/`restack_subtree`).
def branch_exists?(name)
  git_ok("show-ref --verify --quiet refs/heads/#{sh(name)}")
end

# [behind, ahead] commit counts between `branch` and `parent`, in a single
# `git rev-list --left-right --count` call: behind is commits parent has that
# branch lacks, ahead is commits branch has that parent lacks.
#
# The per-branch path, for `restack`'s up-to-date check and as `tree`'s fallback
# when git is too old for the batched `for-each-ref` atom (see scan_ahead_behind).
def ahead_behind(parent, branch)
  out = git_out("rev-list --left-right --count #{sh(parent)}...#{sh(branch)}")
  parts = out.split("\t")
  return [0, 0] if parts.length != 2

  [parts[0].to_i, parts[1].to_i]
end

# Trunks are the branches every stack ultimately rests on. A repo can have
# more than one (e.g. git-flow's `main` and `develop`); they are stored as a
# multi-valued `stack.trunk` git config key. The first configured trunk is the
# "primary" one -- the trunk a branch falls back to when its own cannot be
# determined (see `containing_trunk`).

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
#
# Every candidate must exist as a LOCAL branch, `origin/HEAD`'s included --
# a trunk is a local branch everywhere else in this file, so a name with no
# local ref is a dead end (persisted, rendered as a phantom trunk row, then
# rejected by every `track`/`parent`). `origin/HEAD` pointing at a branch the
# clone lacks is ordinary (merged and cleaned up, or never checked out), so we
# fall through to main/master rather than trust it.
def detect_trunk
  head = git_out("symbolic-ref --quiet --short refs/remotes/origin/HEAD")
  name = head.sub(/^origin\//, "")
  return name if !name.empty? && branch_exists?(name)
  return "main" if branch_exists?("main")
  return "master" if branch_exists?("master")

  die("cannot determine trunk branch; run '#{PROG} init <branch>'")
  "" # unreachable: die exits, but every path must still yield a String
end

# The configured trunks that still exist, announcing each name that doesn't.
# One `git` call per configured trunk -- one in nearly every repo, never a
# per-node loop -- so `branch_exists?` is the right check here.
#
# `select` rather than an `each`/`<<` accumulator: it keeps `configured`'s
# element type, where a fresh `[]` fed from a block parameter would come back
# `Array[untyped]` and widen everything the trunk list reaches. It is also the
# one poly-array method here that Spinel resolves only on a concrete receiver,
# which `configured_trunks` is -- see rbs/git-stack.rbs and the doctor step in CI.
def live_trunks(configured)
  configured.select do |trunk|
    live = branch_exists?(trunk)
    info "configured trunk '#{trunk}' no longer exists; ignoring it" unless live
    live
  end
end

# Every trunk, auto-detecting and caching one on first use.
#
# Configured names are re-checked against the refs on the way out. `init` and
# `detect_trunk` only ever store a branch that exists, but nothing keeps it
# there: rename or delete the trunk afterwards and the key still names a branch
# that is gone -- a dead end wherever a trunk is used (`detect_trunk` says why
# it refuses to store one), and worse than inert in the heal paths, where `sync`
# and `drop` hand the trunk they picked straight to `set_parent`: a ghost trunk
# REPLACES a branch's real recorded parent with a name nothing can rebase onto,
# the rebase is then skipped, and the run reports success. Every command's trunk
# list comes through here, so the check lives here rather than at each use.
#
# What survives is re-cached, so the announcement prints once rather than per
# command, and an empty list falls through to auto-detect exactly as an unset
# key does -- landing a renamed trunk on its new name rather than dying. A repo
# with nothing left to detect still dies in `detect_trunk`, stale key intact.
def trunk_branches
  configured = configured_trunks
  list = live_trunks(configured)
  unless list.empty?
    # Only when something was actually dropped: the common path reads config
    # and writes nothing.
    set_trunks(list) if list.length != configured.length
    return list
  end

  trunk = detect_trunk
  set_trunks([trunk])
  # Silent on first use (nothing was configured), but a re-detect replaced a
  # configured trunk, so name the one that took over.
  info "trunk set to #{trunk}" unless configured.empty?
  [trunk]
end

# True when `branch` is one of the configured trunks.
def is_trunk?(branch, trunks)
  trunks.include?(branch)
end

# The trunk `branch` rests on, decided by ANCESTRY rather than config.
#
# The three callers -- `track` with no argument, `sync`'s orphan heal, and
# `drop`'s child reconnect -- all face a branch whose parent is unrecorded or
# already deleted, so there is no stack to walk down; the answer has to come
# from history. Each used to name the primary trunk directly, which quietly
# dragged a stack built on `develop` over to `main`.
#
# Trunks are peers, so "the" trunk is the NEAREST one: `<trunk>..<branch>`
# counts the commits `branch` has gained since it left that trunk, and the
# smallest count wins. A branch stacked on `develop` also carries develop's own
# commits over `main`, so `main..<branch>` is the longer range and `develop`
# wins -- which holds whether the trunks are ancestors of the branch or have
# diverged from it, since `A..B` is measured from their merge-base either way.
#
# Ties keep config order, so the primary trunk is the tie-breaker: it answers
# the genuinely ambiguous case (trunks that still point at the same commit)
# with the same default as before. Callers announce the trunk they picked --
# `sync` already did, being the one that rewrites refs.
def containing_trunk(branch, trunks)
  # One trunk is the common repo, and with nothing to compare it against the
  # loop below can only pick it -- so skip the `git` call it would spend first.
  return trunks[0] if trunks.length < 2

  best = trunks[0]
  best_count = -1
  trunks.each do |trunk|
    out = git_out("rev-list --count #{sh(trunk)}..#{sh(branch)}")
    # Empty only when the range failed to resolve (a trunk ref that vanished
    # mid-run); skip it rather than let `"".to_i`'s 0 win every comparison.
    next if out.empty?

    count = out.to_i
    if best_count < 0 || count < best_count
      best = trunk
      best_count = count
    end
  end
  best
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

# Record the stack base when `branch` sits exactly on `parent`'s tip -- freshly
# created (`create`) or just replayed onto it (`restack`). Counterpart to
# `record_reparent_base`: here the tip IS where the branch's commits begin, so
# no merge-base walk is needed.
def record_tip_base(branch, parent)
  set_base(branch, git_out("rev-parse #{sh(parent)}"))
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
# StackContext parses it once up front so the tree/restack recursions read
# children in memory instead of re-spawning `git` per node (O(N^2) otherwise).
#
# Through `git_out_full`, not `git_out`: this output grows with the tracked
# branch count, so a backtick would truncate it (see git_out_full's ~4 KB cap).
def scan_stack_config
  git_out_full("config --get-regexp '^branch\\..*\\.stackparent$'", true)
end

# Set of every local branch name, in one `git` subprocess. Captured once so the
# per-node `branch?` lookup is in memory, not a `git show-ref` per tree node.
#
# Through `git_out_full`: this list grows with the repo, and a truncated set
# makes every branch past the cut answer `branch?` with a confident, wrong
# `false` -- the one lookup the whole traversal trusts (see git_out_full).
#
# Full `%(refname)` stripped of `refs/heads/` ourselves, not `%(refname:short)`:
# when a tag shares a branch's name, `:short` emits `heads/<name>`, so `branch?`
# reads the branch as missing and sync reparents its children onto trunk.
def existing_branches
  out = git_out_full("for-each-ref --format='%(refname)' refs/heads/", false)
  set = Set.new
  out.split("\n").each do |name|
    next if name.empty?

    set.add(name.delete_prefix("refs/heads/"))
  end
  set
end

# Every branch that records `parent` as its parent. Builds a throwaway
# StackContext (one config scan, no ahead/behind walk) -- the one-shot path for
# `up`, distinct from the context `tree`/`restack`/`sync` thread through recursion.
def children_of(parent, trunks)
  StackContext.build_topology(trunks).children_of(parent)
end

# The single home of the "a branch with no recorded parent rests on the trunk"
# rule. Every effective-parent path funnels through here -- the single-command
# `effective_parent` and the in-memory `StackContext#effective_parent_of` -- so
# display, counts, and navigation can't drift (the rule used to sit copied in
# three spots).
#
# Threading one rule through both worlds pulls the `git`-wrapper family (`sh`,
# `checkout!`, `branch_exists?`, `ahead_behind`) and `StackContext#branch?` onto
# Spinel's untyped slow path; the hand-written seed in rbs/ pins them back to
# concrete types (fed via `--rbs`, checked by the CI golden). See rbs/git-stack.rbs.
def effective_parent_rule(parent, trunk)
  parent.empty? ? trunk : parent
end

# The parent used for display and navigation: the recorded parent, or -- when
# none is recorded -- the trunk the branch rests on. The single-command path for
# `parent`/`down`.
#
# Trunks are peers, which this answers in two places. A trunk resolves to itself,
# the self-parent fixed point `down` already reads as "the bottom"; without it a
# secondary trunk, recording no parent, would fall through the rule and report
# `develop`'s parent as `main`. And an untracked branch resolves through
# `containing_trunk`, so a branch built on `develop` walks down to `develop`
# rather than being handed the primary trunk.
#
# The rule itself stays trunk-blind -- it knows only "unrecorded parent means a
# trunk", never which one -- so both answers live here. Its other callers go
# through a `ctx`, where trunks are roots by topology, never lookups.
#
# The trunk is resolved eagerly, for the recorded-parent case too, so this stays
# one call into the shared rule. It is not worth avoiding: `containing_trunk`
# returns before spending a `git` call in a single-trunk repo, and `down`/`parent`
# are one-shot commands, not a per-node traversal.
def effective_parent(branch, trunks)
  return branch if is_trunk?(branch, trunks)

  effective_parent_rule(get_parent(branch), containing_trunk(branch, trunks))
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

# Readers for the `"<left>\t<right>"` lines that several indexes below are
# packed as (see StackContext for why packing beats an Array/nested Hash). Every
# consumer asks for a side by name, so the separator's position is known only here.
#
# A line with no tab answers "" -- which every caller already skips on, so it
# doubles as the malformed-line and empty-trailing-line guard.
def tab_head(line)
  tab = line.index("\t")
  return "" if tab.nil?

  line[0...tab]
end

def tab_tail(line)
  tab = line.index("\t")
  return "" if tab.nil?

  line[(tab + 1)..-1]
end

# How many branches per batched `git for-each-ref` in scan_ahead_behind. A batch
# emits at most CHUNK rows of CHUNK+1 columns, so its bytes grow as CHUNK^2; 12
# keeps it ~2 KB worst case, comfortably under git_out's ~4 KB backtick cap.
AHEAD_BEHIND_CHUNK = 12

# The distinct parents in `group` (up to AHEAD_BEHIND_CHUNK "<branch>\t<parent>"
# lines), newline-joined -- one entry per `%(ahead-behind:<parent>)` atom column
# the batch's for-each-ref emits. Newline-packed, not Array[String] (see
# scan_ahead_behind for the Spinel-widening reason).
def ahead_behind_bases(group)
  bases = ""
  seen = Set.new
  group.split("\n").each do |pl|
    parent = tab_tail(pl)
    next if parent.empty? || seen.include?(parent)

    seen.add(parent)
    bases = "#{bases}#{parent}\n"
  end
  bases
end

# The `refs/heads/...` argument tail for the batch's for-each-ref: every branch
# in `group`, shell-quoted and space-joined. Same packed-String idiom as
# ahead_behind_bases.
def ahead_behind_refs(group)
  refs = ""
  group.split("\n").each do |pl|
    branch = tab_head(pl)
    next if branch.empty?

    refs = "#{refs} refs/heads/#{sh(branch)}"
  end
  refs
end

# branch -> the for-each-ref column carrying that branch's counts, for one
# batch. `bases` lists the distinct parents in the order their `%(ahead-behind:)`
# atoms are appended, so a parent's position in it IS its column number; `group`
# maps each branch to its parent. Built once per batch so the readback's row loop
# is a single hash lookup, not two nested scans.
def ahead_behind_columns(group, bases)
  parent_col = {}
  n = 0
  bases.split("\n").each do |b|
    next if b.empty?

    parent_col[b] = n
    n += 1
  end

  cols = {}
  group.split("\n").each do |pl|
    branch = tab_head(pl)
    next if branch.empty?

    col = parent_col[tab_tail(pl)]
    cols[branch] = col unless col.nil?
  end
  cols
end

# Read one batch's for-each-ref `output` back into "<branch>\t<behind>\t<ahead>"
# lines. Each row is "<branch>\t<col0>\t<col1>..."; `cols` (from
# `ahead_behind_columns`) says which column is this branch's.
def ahead_behind_readback(output, cols)
  result = ""
  output.split("\n").each do |row|
    # `tab_head` is the `%(refname)` column; strip `refs/heads/` back to the
    # short branch name the column map and downstream index are keyed by.
    branch = tab_head(row).delete_prefix("refs/heads/")
    next if branch.empty?

    idx = cols[branch]
    next if idx.nil?

    # The idx-th tab-separated ahead-behind column ("<ahead> <behind>").
    col = ""
    c = 0
    tab_tail(row).split("\t").each do |f|
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
# "<branch>\t<parent>" lines. Runs one `git for-each-ref` over those branches,
# with one `%(ahead-behind:<parent>)` atom per distinct parent, then reads back
# each branch's own parent column. Returns "<branch>\t<behind>\t<ahead>" lines
# (empty on git < 2.41, where the atom fails and print_tree_row falls back per node).
def ahead_behind_chunk(group)
  refs = ahead_behind_refs(group)
  return "" if refs.empty?

  bases = ahead_behind_bases(group)
  # `%(refname)` + strip, not `%(refname:short)`, and full `refs/heads/<parent>`
  # in the atom, not the bare name: a same-named tag would otherwise shadow the
  # branch (dropping its counts, or being resolved as the ahead-behind base).
  fmt = "%(refname)"
  bases.split("\n").each do |b|
    next if b.empty?

    fmt = "#{fmt}\t%(ahead-behind:refs/heads/#{b})"
  end

  out = git_out("for-each-ref --format=#{sh(fmt)}#{refs}")
  ahead_behind_readback(out, ahead_behind_columns(group, bases))
end

# Parse a `scan_ahead_behind` result once into a name -> "behind\tahead" index,
# so each node's lookup is O(1) instead of re-scanning the whole result per node.
# Values stay packed "<behind>\t<ahead>" strings, not Array[Integer]: an
# array-valued hash widens to untyped in Spinel's signatures (see
# scan_ahead_behind). `ahead_behind_of` unpacks back into a fresh Array[Integer].
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
# restack / sync recursions. It bundles the git state a traversal reads
# repeatedly, so every lookup is in memory and a whole traversal costs the two or
# three `git` calls `build` makes up front rather than a subprocess per node:
#
#   @parents   branch -> recorded parent           (config scan, trunks dropped)
#   @branches  the set of existing local branches   (existing_branches)
#   @children  parent -> "<child>\n<child>\n..."    (`@parents` inverted)
#   @ab        branch -> "<behind>\t<ahead>"        (ahead_behind_index)
#   @trunk     the primary trunk a parentless branch falls back to (`trunks[0]`)
#
# `@trunk` lets the in-memory traversal resolve a parentless branch through the
# shared `effective_parent_rule`, so display, counts, and navigation agree.
#
# @children and @ab are newline-PACKED Strings, and that is what makes them
# concrete fields: the `Hash[String, Array[String]]` an array value would force
# widens to `Hash[String, untyped]` (Spinel has no tag for it). Packed, they are
# `Hash[String, String]`; callers `.split("\n")` a row back into a fresh
# `Array[String]`, which is where the concrete element type is (re)introduced.
#
# Build with `build` (with ahead/behind counts, for `tree`) or `build_topology`
# (topology only, for restack/sync, which never render counts).
class StackContext
  def initialize
    @parents = {}
    @branches = Set.new
    @trunks = Set.new
    @children = {}
    @ab = {}
    @trunk = ""
    # Explicit nil so Spinel infers `initialize` as `() -> nil`, not `-> String`
    # from the trailing assignment.
    nil
  end

  # Full snapshot including ahead/behind counts, for `tree`. The scan is parsed
  # once (into `@parents`); the ahead/behind walk then reads `@parents` rather
  # than re-parsing the raw config.
  def self.build(trunks)
    ctx = new
    ctx.load(scan_stack_config, trunks)
    ctx.load_ahead_behind(trunks[0])
    ctx
  end

  # Topology and branch existence only -- no ahead/behind git walk. For
  # restack/sync (which never render counts) and the one-shot `children_of`.
  def self.build_topology(trunks)
    ctx = new
    ctx.load(scan_stack_config, trunks)
    ctx
  end

  # Parse one `scan_stack_config` string into the parent and child indexes and
  # capture the existing-branch set. Note: git lowercases a config key's
  # variable name, so the stored key is `branch.<name>.stackparent`.
  #
  # A trunk's recorded parent is DROPPED here, which is what makes "trunks are
  # roots by topology" true of every context rather than a convention `track` and
  # `parent` merely refuse to break. `branch.<trunk>.stackParent` still exists in
  # the wild -- written before those guards landed, or by hand -- and reading it
  # back would let `restack` rebase a shared trunk onto another trunk (rewriting
  # published history) and make `tree` print the trunk's subtree twice. The
  # single-command `effective_parent` already answers a trunk with itself; this
  # is the same rule for the in-memory traversals.
  def load(scan, trunks)
    @branches = existing_branches
    # Kept as a Set so every graph query below can ask "is this parent a trunk?"
    # (the walk's floor) from the context itself. That list used to be threaded
    # back in as a parameter by each of them -- always the same list the context
    # was built from, and an `Array[String]` parameter is exactly what widens to
    # Spinel's untyped slow path (see rbs/git-stack.rbs).
    @trunks = Set.new(trunks)
    scan.split("\n").each do |line|
      next if line.empty?

      space = line.index(" ")
      next if space.nil?

      key = line[0...space]
      value = line[(space + 1)..-1]
      name = key.sub(/^branch\./, "").sub(/\.stackparent$/, "")
      next if trunk?(name)

      @parents[name] = value
    end
    index_children
    nil
  end

  # True when `name` is one of this context's trunks -- the in-memory twin of
  # the top-level `is_trunk?`, reading the set `load` captured.
  def trunk?(name)
    @trunks.include?(name)
  end

  # True when `name` has a recorded parent, i.e. it is a node of the tracked
  # graph. A trunk answers false (its record is dropped on the way in) and is
  # tested with `trunk?` instead. Distinct from `branch?`: that asks whether the
  # ref exists, this asks whether the stack knows about it.
  def tracked?(name)
    !@parents[name].nil?
  end

  # Invert `@parents` into the packed `@children` index, once per context (the
  # traversal reads children at every step, so it isn't re-derived per call).
  #
  # Rebuilds from empty: rows accumulate with `"#{row}#{name}\n"`, so without the
  # reset a second `load` would append every child again and `children_of` would
  # answer ["a", "a", ...] -- enough for `cmd_up` to see "multiple children"
  # where there's one.
  def index_children
    @children = {}
    @parents.each do |name, value|
      next if value.empty?

      row = @children[value]
      @children[value] = row.nil? ? "#{name}\n" : "#{row}#{name}\n"
    end
    nil
  end

  # Record the fallback trunk, then populate the ahead/behind index from a
  # batched walk (see `scan_ahead_behind`). `@trunk` is set first because
  # `scan_ahead_behind` reads it to know where a parentless branch rests.
  def load_ahead_behind(trunk)
    @trunk = trunk
    @ab = ahead_behind_index(scan_ahead_behind)
    nil
  end

  # The parent recorded for `branch`, or "" when none is recorded -- and always
  # "" for a trunk, whose record `load` drops on the way in.
  def parent_of(branch)
    parent = @parents[branch]
    parent.nil? ? "" : parent
  end

  # The effective parent of `branch`: its recorded parent, or `@trunk` when none
  # is recorded. The in-memory entry point to the shared `effective_parent_rule`,
  # used by `print_tree_row` and `scan_ahead_behind` so display and counts agree.
  def effective_parent_of(branch)
    effective_parent_rule(parent_of(branch), @trunk)
  end

  # Precompute [behind, ahead] for every branch against its effective parent in a
  # HANDFUL of batched `git for-each-ref` calls, instead of one `git rev-list` per
  # tree node -- the dominant cost of a large tree once every other lookup was
  # collapsed to a single `git` call. Reads the `@parents` snapshot, resolving
  # each branch through the same `effective_parent_of` the tree render uses, so
  # counts and displayed parent can't disagree.
  #
  # The `%(ahead-behind:<base>)` atom reports "<ahead> <behind>" for every listed
  # ref against <base> in one graph walk. Branches are processed in chunks of
  # AHEAD_BEHIND_CHUNK (one call each, one atom per distinct parent), which cuts
  # ~N git calls to ~N/12 AND bounds each call's output under the ~4 KB backtick
  # cap that a single O(N^2)-output call would blow past. Returns one
  # `"<branch>\t<behind>\t<ahead>"` line per branch (tabs are safe: refnames have
  # no control chars), parsed back by `ahead_behind_index` into `@ab`.
  #
  # The atom requires git 2.41+; on older git the call fails, a chunk yields
  # nothing, and `print_tree_row` falls back to per-node `ahead_behind`.
  def scan_ahead_behind
    # "<branch>\t<parent>" lines for branches whose effective parent exists. One
    # packed string, NOT an Array[String] -- whose element reads Spinel widens to
    # untyped, bleeding into the emitted Set signatures (test/git-stack.rbs.expected).
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
  # none). Reads one packed `@children` row and splits it into a concrete
  # `Array[String]`; `.sort` orders siblings and pins the element type.
  #
  # The `.to_s` guards the split: newer Spinel can widen `@children` to
  # `Hash[String, untyped]`, whose value `.split`s to `unknown`, and `.each` on
  # `unknown` is a baked-in `NoMethodError`. `.to_s` re-narrows to a String so
  # the split stays `Array[String]`; a no-op under the pinned Spinel.
  def children_of(branch)
    row = @children[branch]
    return [] if row.nil?

    names = []
    row.to_s.split("\n").each do |name|
      names << name unless name.empty?
    end
    names.sort
  end

  # The whole subtree rooted at `root`, DFS pre-order (each parent before its
  # children, siblings sorted), packed one `"<depth>\t<branch>"` line per node
  # with `root` at depth 0. `tree` and `restack` split this once and loop flat
  # (depth is a single `Integer`, not a threaded prefix), and the cycle guard
  # lives here once.
  def order(root)
    walk_order(root, 0, Set.new, "")
  end

  # The two readers of one packed order line ("<depth>\t<branch>", see `order`),
  # naming which side means what so callers don't know where the separator sits.
  # `order_line_branch` answers "" for a tab-less line, which both callers skip --
  # covering the empty trailing line and malformed lines alike.
  def order_line_branch(line)
    tab_tail(line)
  end

  # The depth from one packed order line; 0 for a line with no tab (`""`.to_i),
  # which `order_line_branch` has already rejected by the time this is read.
  def order_line_depth(line)
    tab_head(line).to_i
  end

  # The same pre-order walk as `order`, depth dropped: just branch names, `root`
  # first, for callers that traverse but never render (`restack_subtree`).
  # Decoding what `order` encoded is deliberate -- one shared walk can't disagree
  # with itself about traversal order or the cycle guard.
  def order_branches(root)
    names = []
    order(root).split("\n").each do |line|
      name = order_line_branch(line)
      names << name unless name.empty?
    end
    names
  end

  # Append `branch` (at `depth`) and its descendants to `acc` in pre-order,
  # reading children from packed `@children`. `visited` guards cyclic parent
  # chains (A -> B -> A) so the walk terminates, emitting each branch at most
  # once. `acc` is threaded and returned, not mutated, keeping it a concrete String.
  def walk_order(branch, depth, visited, acc)
    return acc if visited.include?(branch)
    visited.add(branch)
    acc = "#{acc}#{depth}\t#{branch}\n"

    row = @children[branch]
    return acc if row.nil?

    # `.to_s` before the split for the reason spelled out in `children_of`: it
    # re-narrows a `@children` value Spinel may have widened, keeping the split
    # an `Array[String]`. No-op under the pinned Spinel.
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

  # [behind, ahead] for `branch` from the index -- a single `Hash` lookup.
  # Returns the sentinel [-1, -1] when `branch` has no entry (git too old for the
  # atom, or a context built without counts), signalling `print_tree_row` to fall
  # back to per-node `ahead_behind`. Rebuilt into a fresh literal so the return
  # type stays a plain `Array[Integer]`.
  def ahead_behind_of(branch)
    packed = @ab[branch]
    return [-1, -1] if packed.nil?

    fields = packed.split("\t")
    return [-1, -1] if fields.length != 2

    [fields[0].to_i, fields[1].to_i]
  end

  # The extra roots `tree` draws: the top of every tracked stack the walk down
  # from the trunks never reaches. Two shapes end up here.
  #
  #   * The recorded parent was merged and deleted -- the classic orphan, which
  #     `git stack sync` repairs.
  #   * The recorded parent still EXISTS but is untracked, as `untrack` on a
  #     branch with children leaves it. Nothing records that parent, so it is
  #     not a trunk's child; and it is not missing either, so the orphan rule
  #     did not catch it. Everything above it dropped out of `tree` without a
  #     word while `restack` went on rebasing onto it (issue #58).
  #
  # Every branch climbs to its own root (`detached_root`) rather than being
  # tested where it sits, which is what makes the answer independent of how the
  # branches are named: a stack is emitted once, at its top, even when a child
  # sorts ahead of it. A root whose own parent is a trunk is exactly a branch
  # the trunk walk already draws, so it is dropped here rather than drawn a
  # second time -- the duplicate-row shape the 4 KB truncation bug produced (see
  # test/binary_test.sh). Emitting a root marks its whole subtree covered, which
  # is what keeps the rest of that stack from being considered again; the marking
  # (rather than remembering the roots alone) is load-bearing for a hand-edited
  # cycle, whose members each climb to a DIFFERENT member as their root.
  def detached_roots
    roots = []
    covered = Set.new
    # Sorted, so the roots come out in the order sibling rows elsewhere in the
    # tree do. `.sort` on a `.keys` result is safe where the same call on a
    # `@parents` VALUE would not be: the hash widened to `Hash[String, untyped]`
    # on its values only, so the keys read back as a concrete `Array[String]`
    # and `.sort` stays off the poly-array slow path (the shape that compiles
    # clean and dies only in the shipped binary -- see test/binary_test.sh,
    # whose fixture walks this line).
    @parents.keys.sort.each do |name|
      next if covered.include?(name)

      root = detached_root(name)
      next if trunk?(parent_of(root))

      roots << root
      covered.merge(order_branches(root))
    end
    roots
  end

  # Climb from `branch` to the top of the stack the trunk walk cannot reach: the
  # last branch whose own parent is absent from the tracked graph. The same walk
  # as `stack_root`, stopping one condition wider -- an existing but untracked
  # parent ends the climb too, because a branch with no record of its own is
  # never drawn and so cannot carry a subtree. `seen` guards a hand-edited
  # parent cycle (A -> B -> A), which would otherwise loop forever; breaking out
  # of it renders the cycle as a root instead of hiding it.
  def detached_root(branch)
    seen = Set.new
    loop do
      seen.add(branch)
      parent = parent_of(branch)
      break if parent.empty? || trunk?(parent)
      break unless tracked?(parent)
      break if seen.include?(parent)

      branch = parent
    end
    branch
  end

  # True when `branch` records a parent that exists as a branch but that the
  # tree never draws, because nothing tracks it. Such a branch is drawn as a
  # detached root, at the indent a trunk's own children get, so its row has to
  # say which branch it really rests on -- `restack` still rebases it onto that
  # parent, not onto the trunk the indent suggests.
  def untracked_parent?(branch)
    parent = parent_of(branch)
    return false if parent.empty? || trunk?(parent) || tracked?(parent)

    branch?(parent)
  end

  # Walk down from `branch` to the root of its stack (whose parent is a trunk or
  # no longer a branch). Returns the root branch name. Reads this context's own
  # parent map and branch set, not a `git config`+`git show-ref` per level.
  # `seen` guards cyclic parent chains (A -> B -> A from hand-edited config) so
  # we terminate instead of hanging.
  #
  # Deliberately NOT `detached_root`, which stops one condition earlier: what
  # `restack` wants is the branch whose subtree it must replay, and an untracked
  # parent is a fine root for that (it is skipped itself, its children are
  # rebased onto it). What `tree` wants is the topmost branch it can DRAW, and
  # an untracked branch is never drawn. Same walk, two questions.
  def stack_root(branch)
    seen = Set.new
    loop do
      seen.add(branch)
      parent = parent_of(branch)
      break if parent.empty? || trunk?(parent)
      break unless branch?(parent)
      break if seen.include?(parent)

      branch = parent
    end
    branch
  end

  # True if making `new_parent` the parent of `branch` would create a cycle --
  # i.e. `branch` already lies on `new_parent`'s ancestor chain. Walks this
  # context (like `stack_root`), so the whole walk costs no `git` per level.
  #
  # The hit is recorded in `result` and reported after a `break`, NOT with a
  # `return true` from inside the `loop`. Under Spinel a `return` out of a `loop
  # do...end` corrupts a later `exit`: with `die(...) if would_cycle?(...)` the
  # compiled binary printed die's message and then exited 0, so a `parent`/
  # `track` that correctly REJECTED a cycle still reported success to a script.
  #
  # The miss was the engine, not the harness: cli_test.rb asserts these very
  # exit codes and still passed, because CRuby is unaffected and its `return`
  # returns. Only the compiled artifact can show it, so test/binary_test.sh is
  # where the guard had to go.
  def would_cycle?(branch, new_parent)
    seen = Set.new
    cur = new_parent
    result = false
    loop do
      if cur == branch
        result = true
        break
      end
      break if cur.empty? || trunk?(cur)
      break if seen.include?(cur)
      break unless branch?(cur)

      seen.add(cur)
      cur = parent_of(cur)
    end
    result
  end

  # Validate that `candidate` can become the parent of `branch`: it must exist,
  # must not be `branch` itself, and must not create a cycle. `verb` customizes
  # the cycle-error wording for the calling command. This context answers both
  # the existence check and the whole ancestor walk from its one snapshot.
  def validate_new_parent!(branch, candidate, verb)
    die("branch '#{candidate}' does not exist") unless branch?(candidate)
    die("a branch cannot be its own parent") if candidate == branch
    die("'#{candidate}' is downstream of '#{branch}'; #{verb} would create a cycle") if would_cycle?(branch, candidate)
    nil
  end
end

# Print one tree row for `branch`, indented two spaces per `depth`. One node of
# the traversal, no recursion: `cmd_tree` drives the order and calls this per
# line, reading the pre-built `ctx` so the whole tree costs no `git` per node.
def print_tree_row(branch, depth, cur, ctx)
  extra = ""
  parent = ctx.effective_parent_of(branch)
  if !parent.empty? && ctx.branch?(parent)
    # Counts from the batched `for-each-ref` (see scan_ahead_behind); the
    # sentinel guards the git-too-old case with a per-node fallback.
    behind, ahead = ctx.ahead_behind_of(branch)
    if behind < 0
      behind, ahead = ahead_behind(parent, branch)
    end
    if behind > 0
      extra = yellow("(needs restack: #{behind} behind)")
    elsif ahead > 0
      extra = dim("(#{ahead} commit(s))")
    end
    # An untracked parent is never drawn, so this row sits at root indent as if
    # it rested on the trunk. Name the parent it actually rests on -- silence
    # here is what made the whole subtree look like it belonged to the trunk.
    if ctx.untracked_parent?(branch)
      note = yellow("(parent '#{parent}' is untracked)")
      extra = extra.empty? ? note : "#{extra} #{note}"
    end
  elsif !parent.empty?
    extra = yellow("(parent '#{parent}' missing; run `#{PROG} sync`)")
  end

  puts "#{"  " * depth}#{tree_marker(branch, cur)} #{tree_name(branch, cur, "")} #{extra}"
  nil
end

# Print the subtree `ctx.order(root)` produced, offset `base` levels deep.
# `tree` calls this once per trunk (base 0, and skipping the depth-0 root, which
# it prints itself with the trunk styling) and once per detached root (base 1, so
# a stack the trunks cannot reach renders where a trunk's children would).
def print_order(root, base, skip_root, cur, ctx)
  ctx.order(root).split("\n").each do |line|
    branch = ctx.order_line_branch(line)
    next if branch.empty?

    depth = ctx.order_line_depth(line)
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
  record_tip_base(name, parent)
  info "created #{green(name)} on top of #{cyan(parent)}"
end

def cmd_tree(_args)
  trunks = trunk_branches
  cur = current_branch_or_empty
  # One StackContext captures the whole stack up front -- topology, branches, and
  # every node's counts -- so the loops below read it in memory, no `git` per node.
  ctx = StackContext.build(trunks)

  # Each trunk is a visual root; its children are the stack roots resting on it.
  # `order(trunk)` includes the trunk itself at depth 0, which we skip here --
  # the trunk row is printed with its own (cyan, "(trunk)") styling.
  trunks.each do |trunk|
    puts "#{tree_marker(trunk, cur)} #{tree_name(trunk, cur, "36")} #{dim("(trunk)")}"
    print_order(trunk, 0, true, cur, ctx)
  end

  # Stacks the trunks cannot reach -- a parent merged and deleted, or untracked
  # while it still had children -- render as extra roots, indented one level
  # (base 1) so they line up with the stack roots that rest on a trunk.
  ctx.detached_roots.each do |root|
    print_order(root, 1, false, cur, ctx)
  end
end

def cmd_parent(args)
  branch = current_branch
  new_parent = arg0(args)
  trunks = trunk_branches
  if new_parent.empty?
    puts effective_parent(branch, trunks)
    return
  end
  die("cannot set parent of trunk '#{branch}'") if is_trunk?(branch, trunks)
  StackContext.build_topology(trunks).validate_new_parent!(branch, new_parent, "setting it as parent")
  reparent!(branch, new_parent, "failed to set parent of '#{branch}'")
  info "parent of '#{branch}' set to '#{new_parent}'"
end

def cmd_track(args)
  branch = current_branch
  trunks = trunk_branches
  parent = arg0(args)
  die("cannot track trunk '#{branch}'") if is_trunk?(branch, trunks)
  # No parent named: the branch already sits on a trunk, so track it there --
  # the trunk its history actually rests on, not just the primary one.
  parent = containing_trunk(branch, trunks) if parent.empty?
  StackContext.build_topology(trunks).validate_new_parent!(branch, parent, "tracking it")
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
  trunks = trunk_branches
  parent = effective_parent(branch, trunks)
  # True for every trunk, and for a branch hand-configured as its own parent.
  die("already at the bottom of the stack") if parent == branch
  die("parent branch '#{parent}' no longer exists") unless branch_exists?(parent)
  checkout!(parent)
end

def cmd_up(args)
  branch = current_branch
  trunks = trunk_branches
  want = arg0(args)

  children = children_of(branch, trunks)
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

# Resolve the base commit to feed `git rebase --onto <parent> <base> <branch>`.
# The base is where the branch's own work begins -- below it, commits belong to
# the parent and must NOT be replayed.
#
# Prefers the recorded stackBase, but only when it still names a real commit
# that is an ancestor of `branch` (a rewritten or never-ancestor base would
# replay the wrong range); otherwise falls back to the merge-base of `branch`
# and `parent`.
#
# A valid recorded base is additionally clamped forward to the merge-base: a
# manual rebase/pull (or a parent that advanced past the branch) can leave the
# recorded base far below where they now diverge. When it is an ancestor of the
# merge-base, every commit between the two is already in `parent`, so replaying
# from it would re-apply and conflict -- the merge-base is correct. A base
# *above* the merge-base is left as-is: the squash-merged-parent case `--onto`
# exists for, where the branch's commits legitimately start below it.
#
# Returns "" only when even the merge-base is unavailable (unrelated histories,
# or a vanished parent during orphan heal) -- the caller then falls back to a
# plain `git rebase <parent> <branch>`.
def resolve_stack_base(branch, parent)
  base = get_base(branch)
  # Both the clamp target for a stale recorded base and the fallback when the
  # recorded base is unusable; "" disables the clamp and signals plain-rebase.
  mb = parent.empty? ? "" : git_out("merge-base #{sh(branch)} #{sh(parent)}")
  if !base.empty? &&
     git_ok("rev-parse --verify --quiet #{sh(base)}^{commit}") &&
     git_ok("merge-base --is-ancestor #{sh(base)} #{sh(branch)}")
    return mb if !mb.empty? && git_ok("merge-base --is-ancestor #{sh(base)} #{sh(mb)}")
    return base
  end
  mb
end

# Replay `branch`'s own commits (those above its stack base) onto `parent`'s tip,
# or die with the manual recovery command. A plain `git rebase <parent>` would
# replay all of `parent..branch`, re-applying a squash-merged parent's work and
# conflicting; `--onto` with the recorded base avoids that. With no base at all
# we fall back to the plain rebase, for branches predating stackBase.
#
# `verb` is the subcommand to send the user back to after a conflict.
def replay_onto!(branch, parent, verb)
  info "restacking #{cyan(branch)} onto #{cyan(parent)}"
  base = resolve_stack_base(branch, parent)
  if base.empty?
    info "'#{branch}': no recorded stack base; rebasing onto '#{parent}'"
    ok = git_ok("rebase #{sh(parent)} #{sh(branch)}")
  else
    ok = git_ok("rebase --onto #{sh(parent)} #{sh(base)} #{sh(branch)}")
  end
  return nil if ok

  git_ok("rebase --abort")
  recover = base.empty? ? "git rebase #{parent}" : "git rebase --onto #{parent} #{base}"
  die("conflict while rebasing '#{branch}' onto '#{parent}'.\n" \
      "Resolve it manually with:\n" \
      "    git checkout #{branch} && #{recover}\n" \
      "then re-run '#{PROG} #{verb}'.")
  nil
end

# Rebase the whole stack rooted at `root`, each branch onto its parent, in
# `ctx.order_branches(root)` order (each parent before its children). That order,
# and the cycle guard, are fixed up front, so this is a flat loop.
#
# `verb` is the subcommand to name on conflict, passed in rather than derived
# from `heal_orphans`: `drop` heals nothing yet must still send the user to
# `restack` (its splice is already in config, re-running `drop` would be wrong).
#
# A branch with no recorded parent is untracked and left untouched -- NOT rebased
# onto a trunk. When `heal_orphans` is true (`sync`), a branch whose recorded
# parent no longer exists is reparented onto the trunk it rests on first; when
# false (`restack`) it is left untouched. Reparenting rewrites config but not
# `ctx`, and an orphan roots its own subtree, so the pre-computed order still holds.
#
# The heal takes the whole trunk LIST, not one trunk chosen by the caller: which
# trunk an orphan belongs to is per-branch (`containing_trunk`), and getting it
# wrong here doesn't just mis-record a parent -- the replay below then rebases the
# branch onto the wrong trunk, dropping the commits of the one it was built on.
#
# `ctx` is built with `build_topology` (no counts). Safe to reuse across the
# traversal because neither restack nor sync creates or deletes branch refs
# mid-walk (sync only rewrites config; rebase updates history in place).
def restack_subtree(root, trunks, heal_orphans, verb, ctx)
  ctx.order_branches(root).each do |branch|
    parent = ctx.parent_of(branch)

    if heal_orphans && !parent.empty? && !ctx.branch?(parent)
      trunk = containing_trunk(branch, trunks)
      info "'#{branch}': parent '#{parent}' no longer exists; reparenting onto trunk '#{trunk}'"
      die("failed to reparent '#{branch}'") unless set_parent(branch, trunk)
      parent = trunk
    end

    if !parent.empty? && ctx.branch?(parent)
      behind, ahead = ahead_behind(parent, branch)
      # `behind == 0`: already on the parent's tip, nothing to move; still falls
      # through to the re-anchor below (which back-fills a missing base).
      if behind > 0
        if ahead == 0
          # No commits of its own above the parent -- a strict ancestor whose work
          # already sits there while the parent advanced past it. Nothing to
          # replay (`--onto` would re-apply and conflict); fast-forward instead.
          info "fast-forwarding #{cyan(branch)} to #{cyan(parent)}"
          ok = git_ok("checkout #{sh(branch)}") && git_ok("merge --ff-only #{sh(parent)}")
          die("failed to fast-forward '#{branch}' to '#{parent}'") unless ok
        else
          replay_onto!(branch, parent, verb)
        end
      end
      # Every path above leaves the branch on the parent's tip (both moving paths
      # `die` on failure), so re-anchor the recorded base there for a later parent
      # advance to replay from.
      record_tip_base(branch, parent)
    end
  end
  nil
end

# The shared body of `restack` and `sync`: restack the current branch's stack,
# then return to it. The two are the same walk and differ only in whether a
# branch whose parent was deleted is healed onto trunk first -- `heal_orphans`.
#
# `verb`/`gerund` are the calling command's own name, passed in rather than
# derived from `heal_orphans`, so each command states its wording once (see the
# same separation in `restack_subtree`).
def run_stack_rebase(heal_orphans, verb, gerund)
  original = current_branch
  trunks = trunk_branches
  # Built before the root walk, which reads topology out of it, not a subprocess
  # per level.
  ctx = StackContext.build_topology(trunks)
  root = ctx.stack_root(original)

  info "#{gerund} stack rooted at #{cyan(root)}"
  restack_subtree(root, trunks, heal_orphans, verb, ctx)

  unless git_ok("checkout #{sh(original)}")
    die("#{verb} completed, but returning to '#{original}' failed;\n" \
        "you are now on '#{current_branch_or_empty}'. Check out '#{original}' manually.")
  end
  info green("done.")
  nil
end

def cmd_restack(_args)
  run_stack_rebase(false, "restack", "restacking")
end

def cmd_sync(_args)
  run_stack_rebase(true, "sync", "syncing")
end

# Splice `branch` out of the stack: reconnect each child to `branch`'s own
# parent, untrack `branch`, and restack the moved subtrees. The first-class "the
# bottom of my stack merged, re-base the rest" move -- run *while the merged
# branch still exists*, so its recorded parent (the grandparent) is still
# readable and children reconnect exactly, unlike delete-then-`sync` which only
# heals onto trunk. (Contrast `untrack`, which orphans the children instead.)
#
# Non-destructive by default: rewrites stack config only, never the branch ref.
# `--delete` is opt-in `git branch -D` after a successful splice. No merge
# detection -- invoking `drop` IS the assertion that the branch is done.
def cmd_drop(args)
  delete = has_flag?(args, "--delete")
  operand = first_operand(args)
  branch = operand.empty? ? current_branch : operand
  trunks = trunk_branches
  die("cannot drop trunk '#{branch}'") if is_trunk?(branch, trunks)

  # One snapshot answers every read the splice needs -- exists?, parent,
  # children -- from a single scan. NOT reused past the rewrites below, which
  # invalidate it.
  ctx = StackContext.build_topology(trunks)
  die("branch '#{branch}' does not exist") unless ctx.branch?(branch)

  original = current_branch_or_empty

  # Where the children reconnect: the dropped branch's own parent, or -- when it
  # was untracked and so sat directly on a trunk -- the trunk it rested on. This
  # is `effective_parent_rule` applied by hand, the ONE place that doesn't call
  # it, so a change to that rule must be mirrored here. Routing it through the
  # helper was measured to widen this file's whole reparent chain to Spinel's
  # untyped slow path (see effective_parent_rule); the rule is also trunk-blind,
  # while the children need the trunk their history is actually built on.
  parent = ctx.parent_of(branch)
  # A recorded parent that no longer exists is no reconnect target either, and
  # the restack below doesn't heal orphans -- writing that dead name onto each
  # child would turn one orphan into N, silently. `validate_new_parent!` would
  # die on it; this is the one reparent site whose parent is read rather than
  # typed by the user, so a missing one heals onto trunk, as `sync` does. Same
  # guard as `restack_subtree`'s heal, minus its `heal_orphans` opt-in.
  if !parent.empty? && !ctx.branch?(parent)
    trunk = containing_trunk(branch, trunks)
    info "'#{branch}': parent '#{parent}' no longer exists; reconnecting children onto trunk '#{trunk}'"
    parent = trunk
  end
  parent = containing_trunk(branch, trunks) if parent.empty?

  # Capture children BEFORE rewriting config. Each is reparented as `parent`/
  # `track` do it (set_parent + record_reparent_base), re-anchoring stackBase to
  # merge-base(child, parent) so `restack`'s `--onto` replays from the right point.
  moved = ctx.children_of(branch)
  moved.each do |child|
    reparent!(child, parent, "failed to reparent '#{child}' onto '#{parent}'")
  end

  # Untrack the dropped branch; its ref stays intact unless `--delete` was passed.
  untrack!(branch)
  info "dropped #{green(branch)}; reparented children onto #{cyan(parent)}"

  # Restack each moved subtree onto its new parent. Rebuild the topology first so
  # it reflects the config rewrites above.
  ctx = StackContext.build_topology(trunks)
  moved.each do |child|
    # "restack", not "drop", on conflict: the splice is already in config.
    restack_subtree(child, trunks, false, "restack", ctx)
  end

  if delete
    # Can't delete the branch you're on; step onto its former parent first.
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
  # Only the Spinel-compiled binary was "built with" Spinel, and it's the only
  # engine whose RUBY_DESCRIPTION is "spinel" (CRuby names its own version).
  return unless RUBY_DESCRIPTION == "spinel"

  # SPINEL_REF is stamped at build time (empty when un-stamped); the 12-char
  # slice matches `spinel --version`'s short rev.
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

# Command-level flags a subcommand consumes itself (vs. the global -h/-v),
# currently only `drop --delete`. Explicit so a typo like `--delet` is still
# rejected and the tolerated set lives in one place.
COMMAND_FLAGS = ["--delete"].freeze

# Parse the global flags (-h/-v) out of `argv`, returning the command they map to
# ("help"/"version") or "" when none was given. Flags are removed in place and
# may appear anywhere (`tree -v` prints the version).
#
# Spinel's optparse is an exact-match subset of CRuby's (no clustering, no
# abbreviation, no `--`) and its `parse!` leaves an unknown flag in argv instead
# of raising -- the leftover check below reports it with CRuby's own message,
# keeping the script and compiled binary aligned.
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
  # Lift command-level flags out before global parsing: CRuby's `parse!` raises
  # on any long option the parser doesn't register, so an unregistered `--delete`
  # would be reported as an invalid *global* option. Pulled aside here and
  # re-attached to the subcommand's args below.
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
    if cleaned.empty?
      cmd = "help"
    else
      cmd = cleaned[0]
      rest = cleaned[1..-1]
    end
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
  # Explicit nil: as the trailing expression the `case`'s mixed branch types
  # (nil from most handlers, Array[String] from cmd_tree) would widen to untyped.
  nil
end

main(ARGV)
