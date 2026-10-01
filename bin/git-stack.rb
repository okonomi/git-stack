#!/usr/bin/env ruby
# frozen_string_literal: true
#
# git-stack -- manage stacked branches with plain git.
#
# A "stack" is a chain of branches where each branch records a parent and the
# commit its parent sat at when the branch was stacked, in git config:
#
#     branch.<name>.stackParent = <parent-branch>
#     branch.<name>.stackBase   = <sha>
#
# stackBase exists because a plain `git rebase <parent>` cannot survive a parent
# that was squash-merged and deleted: its commits no longer match by patch-id, so
# git re-applies them and conflicts. `git rebase --onto <parent> <base>` skips
# everything below the recorded base.
#
# Trunks (main/master, and optionally others like git-flow's `develop`) are the
# multi-valued `stack.trunk` key, auto-detected on first use.
#
# Written in the subset of Ruby that Spinel's AOT compiler accepts, so `spin
# build` turns it into a native binary; it also runs unchanged under CRuby. Many
# roundabout-looking shapes below keep Spinel's inferred types concrete --
# rbs/git-stack.rbs and the emitted-RBS golden in CI hold that line.

# Both ship with Spinel too, spliced into the program at compile time.
require "optparse"
require "set"

PROG = "git stack"
VERSION = "0.1.0"

# Stamped with `spinel --version` by the Homebrew formula before `spin build`
# (see Formula/git-stack.rb): a compiled binary cannot ask for its compiler's
# revision at run time. An un-stamped build reports "unknown".
SPINEL_REF = ""

# --- output helpers ---------------------------------------------------------

# Callers name the intent (`green(name)`, `bold("USAGE")`); only `paint` spells an
# escape code, its reset, or the colour-off case.

# Per the NO_COLOR spec (https://no-color.org/), the variable's mere presence --
# even as an empty string -- disables colour.
def color_enabled?
  return false unless ENV["NO_COLOR"].nil?

  # `STDOUT`, not `$stdout`: Spinel dispatches `$stdout.tty?` against `unknown`
  # and the binary crashes in a real terminal (c144c70).
  STDOUT.tty?
end

USE_COLOR = color_enabled?

# `code` is an SGR parameter such as "32" or "1".
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

# Quote a single argument for a shell command.
def sh(arg)
  "'" + arg.to_s.gsub("'") { "'\\''" } + "'"
end

# A branch name as an unambiguous rev, shell-quoted. Git resolves `refs/tags/`
# before `refs/heads/`, so wherever git reads a bare name as a rev, a same-named
# tag wins -- `restack` once replayed a stack onto the tag's commit (#96).
#
# Not for an argument that names a branch to check out or update (`checkout`,
# `checkout -b`, `branch -D`, `rebase`'s trailing branch). Those already prefer
# `refs/heads/`, and `git rebase <upstream> refs/heads/<branch>` detaches HEAD and
# leaves the branch where it was. Each such site says so where it sits.
#
# Only the name is quoted: `refs/heads/` has no shell metacharacters.
def branch_ref(name)
  "refs/heads/#{sh(name)}"
end

# Every git call goes through one of these three. Need the output: `git_out`.
# Need only success: `git_ok`, or `git_run` when git's own messages should reach
# the user (only `checkout!`, for "Switched to branch").
#
# The status is read as `$? == 0` on its own line: Spinel drops the boolean when a
# bare `system` is the method's last expression.
def git_ok(subcmd)
  system("git #{subcmd} >/dev/null 2>&1")
  $? == 0
end

# The trimmed stdout of `git <subcmd>`, or "" on failure.
def git_out(subcmd)
  `git #{subcmd} 2>/dev/null`.strip
end

def git_run(subcmd)
  system("git #{subcmd}")
  $? == 0
end

# `git_out` for the two scans every traversal trusts -- the branch list and the
# stack config -- dying instead of answering when git fails. A partial or empty
# scan is a wrong answer, not a smaller one: each branch it misses reads as
# deleted, and `sync` would reparent healthy branches onto trunk.
#
# `empty_ok` is for `git config --get-regexp`, whose non-zero exit also means
# "nothing matched". Any non-zero counts as failure, not just 1: only `$? == 0`
# reads the same under CRuby and Spinel.
def git_scan(subcmd, empty_ok)
  out = `git #{subcmd} 2>/dev/null`
  die("scan failed: git #{subcmd}") unless $? == 0 || empty_ok
  out.strip
end

# How often a config write retries a lock another git holds, and the pause
# between tries. Not left to git: a held config lock fails at once, with no
# timeout setting like refs' `core.filesRefLockTimeout`, so two worktrees
# restacking together would fail whichever wrote second.
CONFIG_LOCK_TRIES = 20
CONFIG_LOCK_PAUSE = 0.05

# Every config write goes through here; reads stay on `git_out`. False for any
# failure but the lock -- an unset of an absent key is one, and callers ignore it.
#
# A lock still held after every try is a leftover from a killed git, which
# waiting cannot fix. It is never removed here: it may yet belong to a live
# write. Nor is `core.lockfilePid` asked for its owner: git writes no PID file
# for the config lock.
#
# The failure is told apart by git's message, hence `LC_ALL=C`: the exit status
# is only `$? == 0` under Spinel (see `git_ok`), and the message is translated.
def git_config_write(args)
  tries = 0
  while tries < CONFIG_LOCK_TRIES
    sleep(CONFIG_LOCK_PAUSE) if tries > 0
    err = `LC_ALL=C git config #{args} 2>&1 >/dev/null`
    return true if $? == 0
    return false unless err.include?("could not lock config file")

    tries += 1
  end
  lock = "#{git_out("rev-parse --path-format=absolute --git-common-dir")}/config.lock"
  die("git config is locked by '#{lock}'.\n" \
      "If no git command is running, a killed one left it behind; remove it and re-run.")
  false
end

# A bare name, not `branch_ref`, which would detach HEAD (see there).
def checkout!(branch)
  die("failed to check out '#{branch}'") unless git_run("checkout #{sh(branch)}")
end

def require_repo
  die("not a git repository") unless git_ok("rev-parse --git-dir")
end

# The current branch, or "" when detached.
#
# Strips `refs/heads/` itself rather than asking for `--short`, which stops
# shortening once the name is ambiguous: a tag named after the branch makes it
# answer `heads/<name>` (#93).
#
# Then resolved to the spelling git stores. On a case-insensitive filesystem
# `git checkout Feat-A` succeeds against `feat-a` and records `Feat-A` in HEAD,
# while every reader here compares refnames exactly (#106). `%(HEAD)` is no help:
# git compares HEAD's stored string the same way.
def current_branch_or_empty
  ref = git_out("symbolic-ref --quiet HEAD")
  return "" if ref.empty?

  name = ref.delete_prefix("refs/heads/")
  # HEAD outside `refs/heads/`: no branch to resolve, so returned whole, as
  # `--short` did.
  return name if name == ref

  # "" for an unborn branch, whose only spelling is HEAD's own.
  stored = stored_refname(name)
  stored.empty? ? name : stored
end

# The spelling git stores for `name`, matched case-insensitively, or "" when no
# branch folds to it. Only for names git handed us (HEAD, `origin/HEAD`), which the
# user cannot correct. A name the user typed must match exactly, or a typo in
# `init Main` would be silently accepted (#101).
#
# Not `--ignore-case`: it folds ASCII only (`feat-Ä` misses `feat-ä`) and defeats
# the ref-prefix optimisation. `String#downcase` folds Unicode, as the filesystem
# did.
#
# Callers skip an empty `name`: the exact check on "" lists every branch, twice.
def stored_refname(name)
  return name if branch_ref_exists?(name)

  folded = name.downcase
  stored = branch_names.find { |branch| branch.downcase == folded }
  stored.nil? ? "" : stored
end

def current_branch
  require_branch(current_branch_or_empty)
end

# `current_branch`'s guard, for a caller already holding HEAD -- reading it can
# cost more than one `git` call, so it is read once (see `cmd_drop`).
def require_branch(head)
  die("you are in 'detached HEAD' state; check out a branch first") if head.empty?
  head
end

# True when git would refuse to create `name`. Deliberately loose: on a
# case-insensitive filesystem `Main` is taken beside `main`, as git itself says.
# Not called `branch_exists?`, because a name read back from config needs the
# exact answer, `branch_ref_exists?` (#101).
def branch_name_taken?(name)
  git_ok("show-ref --verify --quiet #{branch_ref(name)}")
end

# True when `name` is exactly a branch git has -- for a name read from config and
# compared or written back as one (#101). One `git` call per name; for a whole
# list use `existing_branches`.
#
# `for-each-ref`, not `show-ref --verify`, which inherits the filesystem's case
# folding. Its pattern also matches one level down (`feat` finds `feat/sub`),
# hence the exact-line test; git's D/F rule makes that line the only one when
# present.
def branch_ref_exists?(name)
  rows = git_out("for-each-ref --format='%(refname)' #{branch_ref(name)}")
  unpack_lines(rows).include?("refs/heads/#{name}")
end

# [behind, ahead] of `branch` relative to `onto`, a full ref (see `parent_ref`).
# The per-branch form, for `restack` and for `tree` on a git without the batched
# atom (see scan_ahead_behind).
def ahead_behind(onto, branch)
  out = git_out("rev-list --left-right --count #{sh(onto)}...#{branch_ref(branch)}")
  parts = out.split("\t")
  return [0, 0] if parts.length != 2

  [parts[0].to_i, parts[1].to_i]
end

# Trunks are peers. The first configured one is the primary: the fallback when a
# branch's own trunk cannot be told (see `containing_trunk`).

# Every configured trunk, in config order.
#
# `map`/`reject` rather than an `each`/`<<` accumulator, here and wherever this
# file filters a `split`: a fresh `[]` fed from a block widens to
# `Array[untyped]`. Spinel resolves these array methods only on a concrete
# receiver, so a chain must start at something typed (a `split`, `keys`, or a
# pinned parameter).
#
# `uniq` because validating input cannot fix a list already doubled by an old
# `init main main` or a hand-written `config --add` (#83).
def configured_trunks
  out = git_out("config --get-all stack.trunk")
  out.split("\n").map { |line| line.strip }.reject { |name| name.empty? }.uniq
end

# Replace the trunk list with exactly `trunks`.
def set_trunks(trunks)
  # Fails when the key is absent, which is fine.
  git_config_write("--unset-all stack.trunk")
  trunks.each do |trunk|
    git_config_write("--add stack.trunk #{sh(trunk)}")
  end
end

# The trunk to auto-detect -- the remote's default branch, then main/master -- or
# "" when none fits. Split from `detect_trunk` because `plant`/`fell` report the
# answer without dying on its absence.
#
# Every candidate must be a local branch. `origin/HEAD` naming a branch this clone
# lacks is ordinary, and storing it would leave a phantom trunk.
#
# Strips `refs/remotes/origin/` itself rather than asking for `--short`, which
# answers `remotes/origin/<name>` when a local branch is named `origin/<name>`.
def detect_trunk_or_empty
  name = git_out("symbolic-ref --quiet refs/remotes/origin/HEAD").delete_prefix("refs/remotes/origin/")
  # Resolved, not merely checked: `origin/HEAD` may say `Develop` where git stores
  # `develop` (#108). The empty guard only saves listing every branch twice.
  stored = name.empty? ? "" : stored_refname(name)
  return stored unless stored.empty?

  # Exact, unlike `origin/HEAD` above. That one is the remote's fact; these are our
  # guess, and folding a guess would accept anything that folds to `main` (#101).
  return "main" if branch_ref_exists?("main")
  return "master" if branch_ref_exists?("master")

  ""
end

def detect_trunk
  name = detect_trunk_or_empty
  die("cannot determine trunk branch; run '#{PROG} init <branch>'") if name.empty?

  name
end

# The configured trunks that still exist, announcing each that doesn't. A `git`
# call per trunk rather than an `existing_branches` scan: there is rarely more
# than one.
#
# `select` on a concrete receiver (see `configured_trunks`). If this widens,
# `trunk_branches` hands out two array representations and the cast segfaults,
# which is why rbs/git-stack.rbs pins it.
def live_trunks(configured)
  configured.select do |trunk|
    live = branch_ref_exists?(trunk)
    info "configured trunk '#{trunk}' no longer exists; ignoring it" unless live
    live
  end
end

# Every trunk, auto-detecting and caching one on first use.
#
# Configured names are re-checked here, for every command, because a trunk
# renamed or deleted after `init` leaves a ghost: `sync` and `drop` would record
# it as a parent, skip the rebase, and report success. Survivors are re-cached so
# the notice prints once, and an empty list re-detects as an unset key does.
def trunk_branches
  configured = configured_trunks
  list = live_trunks(configured)
  unless list.empty?
    set_trunks(list) if list.length != configured.length
    return list
  end

  trunk = detect_trunk
  set_trunks([trunk])
  # A re-detect replaced a configured trunk, so say which one took over.
  info "trunk set to #{trunk}" unless configured.empty?
  [trunk]
end

def is_trunk?(branch, trunks)
  trunks.include?(branch)
end

# The trunk `branch` rests on, from ancestry rather than config -- for a branch
# whose parent is unrecorded or deleted. Naming the primary trunk instead dragged
# stacks built on `develop` over to `main` (#73).
#
# The nearest trunk wins: `<trunk>..<branch>` counts the commits since the branch
# left it, and a branch on `develop` also carries develop's commits over `main`.
# Ties keep config order, so the primary trunk breaks them.
def containing_trunk(branch, trunks)
  return trunks[0] if trunks.length < 2

  best = trunks[0]
  best_count = -1
  trunks.each do |trunk|
    out = git_out("rev-list --count #{branch_ref(trunk)}..#{branch_ref(branch)}")
    # Empty when the range failed to resolve; skipped, or `"".to_i`'s 0 would win.
    next if out.empty?

    count = out.to_i
    if best_count < 0 || count < best_count
      best = trunk
      best_count = count
    end
  end
  best
end

# --- trunk upstreams --------------------------------------------------------

# With `stack.trunkUpstream`, a branch whose parent is a trunk is restacked onto
# and measured against the trunk's upstream (`origin/main`), which `git fetch`
# updates from any worktree -- unlike the local trunk, which is usually checked
# out in another one and refuses both `pull` and `fetch origin main:main` there.
# Off by default: it moves the base off a `main` the user just pulled, drops
# unpushed trunk commits from it, and has `sync` touch the network.
#
# `stackParent` still names the trunk branch. The upstream is resolved per run,
# per trunk, so a trunk without one keeps its local ref.

# `stack.trunkUpstream` as a boolean. A value git cannot read as one dies rather
# than reading as false, which would silently restack onto the stale local trunk.
def trunk_upstream_enabled?
  raw = git_out("config --get stack.trunkUpstream")
  return false if raw.empty?

  value = git_out("config --type=bool --get stack.trunkUpstream")
  die("stack.trunkUpstream must be true or false, not '#{raw}'") if value.empty?
  value == "true"
end

# "<trunk>\t<upstream ref>\t<remote>" for every trunk with an upstream, or none
# unless `stack.trunkUpstream` is on.
#
# `for-each-ref`'s `%(upstream)`, not `<trunk>@{upstream}`: that is a rev, so a
# tag named after the trunk makes it ambiguous (#96), and `refs/heads/main@{u}`
# is not accepted either.
def trunk_upstream_rows(trunks)
  return [] unless trunk_upstream_enabled?

  refs = trunks.map { |trunk| " #{branch_ref(trunk)}" }.join("")
  out = git_out("for-each-ref --format='%(refname)%09%(upstream)%09%(upstream:remotename)'#{refs}")
  # The pattern also matches a level down (`main` finds `main/x`), hence the
  # exact-name test.
  unpack_lines(out).map { |row| row.delete_prefix("refs/heads/") }.select do |row|
    is_trunk?(tab_field(row, 0), trunks) && !tab_field(row, 1).empty?
  end
end

# Field `index` of a tab-separated row, or "" past its end. One field at a time,
# not `split` mapped over the rows: an array of arrays widens under Spinel.
def tab_field(row, index)
  fields = row.split("\t")
  index < fields.length ? fields[index] : ""
end

# trunk -> the upstream ref its children restack onto. A trunk whose upstream
# is not there (never fetched, or deleted on the remote) keeps its local ref,
# and says so.
def trunk_onto_refs(rows)
  onto = {}
  rows.each do |row|
    trunk = tab_field(row, 0)
    up = tab_field(row, 1)
    if git_ok("rev-parse --verify --quiet #{sh(up)}")
      onto[trunk] = up
    else
      info "warning: trunk '#{trunk}' has no '#{ref_label(up)}' yet; using the local branch"
    end
  end
  onto
end

# `sync`'s fetch, of each remote a trunk's upstream lives on. A failed fetch
# only warns: offline, the last fetched upstream is still a better base than
# giving up. Remote "." is this repository, with nothing to fetch.
def fetch_trunk_remotes(rows)
  remotes = rows.map { |row| tab_field(row, 2) }
  remotes.reject { |remote| remote.empty? || remote == "." }.uniq.each do |remote|
    info "fetching #{cyan(remote)}"
    info "warning: fetching '#{remote}' failed; using what was fetched last" unless git_ok("fetch --quiet #{sh(remote)}")
  end
  nil
end

# The full ref `parent` is restacked onto and measured against: the trunk's
# upstream when `onto` has one, else the branch itself.
def parent_ref(parent, onto)
  up = onto[parent]
  up.nil? ? "refs/heads/#{parent}" : up
end

# A full ref as the user would type it: `main`, `origin/main`.
def ref_label(ref)
  return ref.delete_prefix("refs/heads/") if ref.start_with?("refs/heads/")

  ref.delete_prefix("refs/remotes/")
end

# --- anchors ----------------------------------------------------------------

# An anchor is the branch a worktree tool makes for a worktree: it sits on a
# trunk and carries no commits, and stacks grow on top of it. It is never a node
# of the graph -- a stack created on it records the trunk as parent -- so it is
# never restacked and never a PR base.
#
# `stackAnchor` goes on every branch of the stack, not only the root: deleting a
# branch deletes its whole `branch.<name>` config section, and the root is the
# branch deleted first, once it merges.

# Every registered anchor, in config order. Shaped like `configured_trunks`.
def configured_anchors
  out = git_out("config --get-all stack.anchor")
  out.split("\n").map { |line| line.strip }.reject { |name| name.empty? }.uniq
end

def set_anchors(anchors)
  # Fails when the key is absent, which is fine.
  git_config_write("--unset-all stack.anchor")
  anchors.each do |anchor|
    git_config_write("--add stack.anchor #{sh(anchor)}")
  end
end

# The anchor `branch`'s stack belongs to, or "".
def get_anchor(branch)
  git_out("config --get branch.#{sh(branch)}.stackAnchor")
end

def set_anchor(branch, anchor)
  git_config_write("branch.#{sh(branch)}.stackAnchor #{sh(anchor)}")
end

# Kept on the anchor itself, so it tells "every stack here was deleted" from
# "no stack yet", and goes with the anchor when that is deleted.
def mark_anchor_used(anchor)
  git_config_write("branch.#{sh(anchor)}.stackAnchorUsed true")
end

# branch -> the anchor it records, for every branch at once: `tree` would
# otherwise spend a `git config` per row.
def anchor_memberships
  members = {}
  scan = git_scan("config --get-regexp '^branch\\..*\\.stackanchor$'", true)
  unpack_lines(scan).each do |line|
    space = line.index(" ")
    next if space.nil?

    value = line[(space + 1)..-1].strip
    next if value.empty?

    members[line[0...space].sub(/^branch\./, "").sub(/\.stackanchor$/, "")] = value
  end
  members
end

# Unset `stackAnchor` on every branch that names `anchor`, for when the anchor
# stops being one. Its stacks stay, as ordinary stacks on the trunk.
def release_anchor(anchor)
  anchor_memberships.each do |name, value|
    git_config_write("--unset branch.#{sh(name)}.stackAnchor") if value == anchor
  end
  nil
end

# Unregister every anchor whose branch is gone and release its stacks, saying
# so. Checked on every command, as `trunk_branches` checks the trunks: the
# worktree tool deletes the anchor without telling git-stack, and a stack left
# naming it would be scoped and drawn under nothing.
def prune_vanished_anchors
  anchors = configured_anchors
  return nil if anchors.empty?

  live = anchors.select { |anchor| branch_ref_exists?(anchor) }
  return nil if live.length == anchors.length

  set_anchors(live)
  anchors.reject { |anchor| live.include?(anchor) }.each do |gone|
    release_anchor(gone)
    info "anchor '#{gone}' no longer exists; unregistered it (its stacks stay on the trunk)"
  end
  nil
end

# The registered anchors whose branch still exists.
def live_anchors
  configured_anchors.select { |anchor| branch_ref_exists?(anchor) }
end

# True once a stack was created on `anchor` (see `mark_anchor_used`).
def anchor_used?(anchor)
  git_out("config --type=bool --get branch.#{sh(anchor)}.stackAnchorUsed") == "true"
end

# Dies unless `candidate` may become a parent. An anchor is not a graph node.
def refuse_anchor_parent!(candidate)
  return nil unless configured_anchors.include?(candidate)

  die("'#{candidate}' is an anchor, not a stack branch; check it out and run '#{PROG} create <name>' on it instead")
  nil
end

# --- push -------------------------------------------------------------------

# The remote `branch` is pushed to, in the order git itself picks one for a
# plain `git push`, then `origin`, then a repository's only remote; "" when none
# fits. Resolved here rather than left to `git push`, because the lease and the
# refspec below name the remote explicitly.
def push_remote_for(branch)
  remote = git_out("config --get branch.#{sh(branch)}.pushRemote")
  remote = git_out("config --get remote.pushDefault") if remote.empty?
  remote = git_out("config --get branch.#{sh(branch)}.remote") if remote.empty?
  # "." is this repository, which a push cannot mean.
  remote = "" if remote == "."
  return remote unless remote.empty?

  remotes = git_out("remote").split("\n").map { |line| line.strip }.reject { |name| name.empty? }
  return "origin" if remotes.include?("origin")

  remotes.length == 1 ? remotes[0] : ""
end

# The SHA git-stack last pushed `branch` at, or "".
def get_pushed(branch)
  git_out("config --get branch.#{sh(branch)}.stackPushed")
end

# Push `branch` to the same name on `remote`, never with a bare `--force`.
# Returns "" on success, else why not.
#
# The lease expects the SHA git-stack last pushed. A branch it never pushed is
# leased against the remote-tracking ref instead, with `--force-if-includes`, so
# a push made outside git-stack does not leave the lease failing forever -- and
# a ref merely refreshed by a background fetch does not count as seen.
#
# `LC_ALL=C` because the lease failure is told apart by git's message: the exit
# status is only `$? == 0` under Spinel (see `git_ok`).
def push_branch(branch, remote)
  dst = "refs/heads/#{branch}"
  pushed = get_pushed(branch)
  lease = pushed.empty? ? "--force-with-lease=#{sh(dst)} --force-if-includes" : "--force-with-lease=#{sh("#{dst}:#{pushed}")}"
  # Only when there is none: an upstream the user chose stays theirs.
  upstream = git_out("config --get branch.#{sh(branch)}.merge").empty? ? " --set-upstream" : ""
  info "pushing #{cyan(branch)} to #{cyan(remote)}"
  out = `LC_ALL=C git push --quiet#{upstream} #{lease} #{sh(remote)} #{sh("#{dst}:#{dst}")} 2>&1`
  if $? == 0
    git_config_write("branch.#{sh(branch)}.stackPushed #{sh(git_out("rev-parse #{branch_ref(branch)}"))}")
    return ""
  end
  if out.include?("stale info") || out.include?("remote ref updated since checkout")
    return "'#{remote}/#{branch}' has commits this branch does not include; fetch them and bring them in (or check they can go) first"
  end

  lines = unpack_lines(out)
  lines.empty? ? "git push failed" : lines[lines.length - 1].strip
end

# --- worktrees --------------------------------------------------------------

# git refuses to check out, or to rebase by name, a branch another worktree
# holds. Such a branch is rewritten from inside its worktree (`git -C <path>`),
# which needs no checkout at all.

# branch -> worktree path, for every branch another worktree holds. `here` is the
# current worktree's branch, which the usual checkout-and-rebase handles.
#
# Not keyed by path: `worktree list` answers the resolved path, which need not
# match the one this process was started in (a symlinked /tmp).
def other_worktree_checkouts(here)
  held = {}
  path = ""
  unpack_lines(git_out("worktree list --porcelain")).each do |line|
    if line.start_with?("worktree ")
      path = line.delete_prefix("worktree ")
    else
      name = worktree_line_branch(line, path)
      held[name] = path unless name.empty? || name == here
    end
  end
  held
end

# The branch a `worktree list --porcelain` line says `path` holds, or "".
#
# A worktree mid-rebase lists as `detached`, yet git still refuses the branch
# being rebased, so that one is read from the rebase's own `head-name`.
def worktree_line_branch(line, path)
  return line.delete_prefix("branch refs/heads/") if line.start_with?("branch refs/heads/")
  return "" unless line == "detached"

  head = worktree_file(path, "rebase-merge/head-name")
  head = worktree_file(path, "rebase-apply/head-name") if head.empty?
  head.start_with?("refs/heads/") ? head.delete_prefix("refs/heads/") : ""
end

# The contents of `name` in `path`'s git dir, or "" when it is absent.
#
# `cat`, not `File.read`: Spinel's subset has no File.
def worktree_file(path, name)
  file = worktree_git_path(path, name)
  return "" if file.empty?

  `cat #{sh(file)} 2>/dev/null`.strip
end

# `name` resolved in `path`'s own git dir, where a linked worktree keeps its
# rebase and merge state -- not under `<path>/.git`, which is a file there.
def worktree_git_path(path, name)
  git_out("-C #{sh(path)} rev-parse --path-format=absolute --git-path #{sh(name)}")
end

# The state files of an operation git leaves half-done in a worktree, as
# "<file>\t<what to call it>".
IN_PROGRESS_MARKERS = [
  "rebase-merge\ta rebase",
  "rebase-apply\ta rebase",
  "MERGE_HEAD\ta merge",
  "CHERRY_PICK_HEAD\ta cherry-pick",
  "REVERT_HEAD\ta revert"
].freeze

def worktree_path_exists?(path, name)
  file = worktree_git_path(path, name)
  return false if file.empty?

  system("test -e #{sh(file)}")
  $? == 0
end

# Why the worktree at `path` cannot take a rebase now, or "" when it can.
#
# Only tracked changes count, as they do for git's own rebase: an untracked file
# is carried across unless the rebase would overwrite it, and then it fails like
# a conflict and is aborted.
#
# `--no-optional-locks`: a plain `status` refreshes that worktree's index, and
# would race whatever the user is running there.
def worktree_busy_reason(path)
  return "is missing (see 'git worktree prune')" unless git_ok("-C #{sh(path)} rev-parse --git-dir")

  marker = IN_PROGRESS_MARKERS.find { |row| worktree_path_exists?(path, tab_head(row)) }
  return "has #{tab_tail(marker)} in progress" unless marker.nil?

  dirty = git_out("--no-optional-locks -C #{sh(path)} status --porcelain --untracked-files=no")
  return "has uncommitted changes" unless dirty.empty?

  ""
end

# `held[branch]`, or "" when the branch is free to check out here.
def worktree_of(held, branch)
  path = held[branch]
  path.nil? ? "" : path
end

# --- stack metadata ---------------------------------------------------------

def get_parent(branch)
  git_out("config --get branch.#{sh(branch)}.stackParent")
end

def set_parent(branch, parent)
  git_config_write("branch.#{sh(branch)}.stackParent #{sh(parent)}")
end

def clear_parent(branch)
  git_config_write("--unset branch.#{sh(branch)}.stackParent")
end

# The recorded stack base, or "" when none is (a branch predating stackBase, or
# unrelated histories at reparent time).
def get_base(branch)
  git_out("config --get branch.#{sh(branch)}.stackBase")
end

def set_base(branch, sha)
  git_config_write("branch.#{sh(branch)}.stackBase #{sh(sha)}")
end

def clear_base(branch)
  git_config_write("--unset branch.#{sh(branch)}.stackBase")
end

# The base for reparenting an existing branch: the merge-base, not the parent's
# tip, since the branch may already have diverged. With no common ancestor it is
# left unset, and `restack` computes a merge-base itself.
def record_reparent_base(branch, parent)
  base = git_out("merge-base #{branch_ref(branch)} #{branch_ref(parent)}")
  if base.empty?
    info "warning: no common ancestor of '#{branch}' and '#{parent}'; stack base not recorded"
    return
  end
  set_base(branch, base)
  nil
end

# The base for a branch sitting exactly on `onto`'s tip (after `create` or a
# replay). `onto` is a full ref: the upstream a trunk child was replayed onto,
# not the trunk it names as parent.
def record_tip_base(branch, onto)
  set_base(branch, git_out("rev-parse #{sh(onto)}"))
  nil
end

# Set the parent and re-anchor the base together: a base left over from the old
# parent replays the wrong range. `err` keeps each command's own wording.
# `restack_subtree` does not come through here; it anchors on the tip after
# rebasing.
#
# Parent first, everywhere: config has no multi-key transaction, and a run cut
# off between the two writes leaves a missing base, which `resolve_stack_base`
# recovers as a merge-base. The other order would leave a base beside the old
# parent.
def reparent!(branch, parent, err)
  die(err) unless set_parent(branch, parent)
  record_reparent_base(branch, parent)
  nil
end

# Parent, base and anchor go together, so none outlives the stack it pointed into.
def untrack!(branch)
  clear_parent(branch)
  clear_base(branch)
  # Fails when the key is absent, which is fine.
  git_config_write("--unset branch.#{sh(branch)}.stackAnchor")
  nil
end

# Every `branch.<name>.stackParent` in one scan, so traversals read children in
# memory rather than spawning `git` per node.
def scan_stack_config
  git_scan("config --get-regexp '^branch\\..*\\.stackparent$'", true)
end

def existing_branches
  Set.new(branch_names)
end

# Every local branch name. `%(refname)` stripped here, not `%(refname:short)`,
# which answers `heads/<name>` when a tag shares the name.
#
# Also exposed as an Array for `stored_refname`, which has to search it:
# `Set#find` is on Spinel's poly path and would widen every caller.
def branch_names
  out = git_scan("for-each-ref --format='%(refname)' refs/heads/", false)
  unpack_lines(out).map { |name| name.delete_prefix("refs/heads/") }
end

# The branches `up`'s menu offers from `parent`: its recorded children, plus, for a
# trunk, the detached roots `tree` draws under it -- stacks whose parent was
# untracked or deleted (#85). Only the roots `containing_trunk` assigns to this
# trunk, as `cmd_tree` places them, or `up` from `main` would check out a stack
# built on `develop` (#91).
#
# Live roots only: a phantom would reach `checkout!` and fail in git's words, not
# ours. `containing_trunk` runs last because it costs a `rev-list` per trunk.
#
# `select`/`concat` are safe here only because both receivers are pinned
# `Array[String]` in rbs/git-stack.rbs. Off a concrete receiver they compile and
# pass `spin test`, then die in the shipped binary; test/binary_test.sh drives
# this path on the compiled artifact.
def children_of(parent, trunks)
  topology = StackRepository.load_topology(trunks)
  children = topology.children_of(parent)
  return children unless is_trunk?(parent, trunks)

  ours = topology.live_detached_roots.select { |root| containing_trunk(root, trunks) == parent }
  children.concat(ours)
end

# What `up <name>` accepts from `parent`: the menu's list plus every other trunk's
# detached roots. Naming a branch is not the silent jump the menu's
# `containing_trunk` gate prevents, and refusing a row `tree` drew would bring
# #85 back.
def named_children_of(parent, trunks)
  topology = StackRepository.load_topology(trunks)
  children = topology.children_of(parent)
  return children unless is_trunk?(parent, trunks)

  children.concat(topology.live_detached_roots)
end

# The roots of the stacks created on `anchor`, sorted: what `up` offers from it,
# and what `sync` takes in its scope. Live branches only, since `up` checks one
# out. `members` is `anchor_memberships`.
def anchor_stacks(topology, members, anchor, trunks)
  topology.tracked_branches.select do |name|
    members[name] == anchor && topology.branch?(name) && is_trunk?(topology.parent_of(name), trunks)
  end.sort
end

# The parent `parent`/`down` answer with: a trunk is its own (the bottom), a
# recorded parent wins, and otherwise the trunk the branch's history rests on.
# The only place that resolves a trunk for a parentless branch; a snapshot cannot
# afford `containing_trunk` per node (#73).
#
# One hop only. "Where does this stack start" is `StackTopology#climb_to_root`'s
# question (#80).
def effective_parent(branch, trunks)
  return branch if is_trunk?(branch, trunks)

  parent = get_parent(branch)
  parent.empty? ? containing_trunk(branch, trunks) : parent
end

# --- tree rendering ---------------------------------------------------------

def tree_marker(branch, cur)
  branch == cur ? "*" : " "
end

# `default_code` is an SGR code, or "" for no colour.
def tree_name(branch, cur, default_code)
  return bold(green(branch)) if branch == cur
  return branch if default_code.empty?

  paint(default_code, branch)
end

# Readers for `"<left>\t<right>"` lines. A line with no tab answers "", which
# every caller skips, so malformed and trailing empty lines need no guard of their
# own.
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

# A list packed one entry per line, wherever it has to be a hash value: Spinel
# widens an array-valued hash to `Hash[String, untyped]`, and no seed line fixes
# it -- `Hash[String, Array[String]]` in rbs/git-stack.rbs is silently dropped,
# not refused, so only the emitted golden shows it failed. A plain
# `Array[String]` ivar infers fine and needs no packing.
#
# `unpack_lines`' `split` re-introduces the concrete element type that `map`,
# `reject`, `sort` and `each_slice` downstream need. `pack_lines([])` is "", not
# "\n", so a round trip is a no-op.
def pack_lines(lines)
  lines.map { |line| "#{line}\n" }.join("")
end

def unpack_lines(packed)
  packed.split("\n").reject { |line| line.empty? }
end

# Branches per batched `for-each-ref`. Not smaller: each batch is a git process
# whose fixed cost grows with the repository. Not unbounded: every row carries a
# column for each parent in the batch, so the readback parses CHUNK^2 fields.
AHEAD_BEHIND_CHUNK = 128

# The distinct parent refs in `group`, packed, one per `%(ahead-behind:)` column.
# `uniq` keeps first-occurrence order, which `ahead_behind_columns` reads back as
# column numbers.
def ahead_behind_bases(group)
  pack_lines(unpack_lines(group).map { |pl| tab_tail(pl) }.reject { |parent| parent.empty? }.uniq)
end

# `group`'s branches as the batch's ref arguments.
def ahead_behind_refs(group)
  branches = unpack_lines(group).map { |pl| tab_head(pl) }.reject { |branch| branch.empty? }
  branches.map { |branch| " #{branch_ref(branch)}" }.join("")
end

# branch -> the for-each-ref column holding its counts, built once per batch.
#
# `bases` is split raw, not through `unpack_lines`: its only producer already
# drops empties, and `ahead_behind_chunk` has to split it identically.
def ahead_behind_columns(group, bases)
  parent_col = {}
  bases.split("\n").each_with_index do |b, col|
    parent_col[b] = col
  end

  cols = {}
  unpack_lines(group).each do |pl|
    branch = tab_head(pl)
    next if branch.empty?

    col = parent_col[tab_tail(pl)]
    cols[branch] = col unless col.nil?
  end
  cols
end

# One batch's output as "<branch>\t<behind>\t<ahead>" lines. Each row is
# "<refname>\t<col0>\t<col1>..."; `cols` says which column is the branch's own.
def ahead_behind_readback(output, cols)
  result = ""
  output.split("\n").each do |row|
    branch = tab_head(row).delete_prefix("refs/heads/")
    next if branch.empty?

    idx = cols[branch]
    next if idx.nil?

    col = tab_tail(row).split("\t")[idx]
    next if col.nil? || col.empty?

    # The atom prints "<ahead> <behind>"; callers want [behind, ahead].
    ab = col.split(" ")
    next if ab.length != 2

    result = "#{result}#{branch}\t#{ab[1].to_i}\t#{ab[0].to_i}\n"
  end
  result
end

# One batch of scan_ahead_behind: a `for-each-ref` over up to AHEAD_BEHIND_CHUNK
# branches, one `%(ahead-behind:)` atom per distinct parent. Empty on git < 2.41,
# where the atom fails and `tree` falls back per node.
def ahead_behind_chunk(group)
  refs = ahead_behind_refs(group)
  return "" if refs.empty?

  bases = ahead_behind_bases(group)
  # Each base is already a full ref (see `parent_ref`), left unquoted: the atom
  # sits inside `fmt`, which is `sh`-quoted whole, so inner quotes would nest and
  # break it.
  atoms = bases.split("\n").map { |b| "\t%(ahead-behind:#{b})" }
  fmt = "%(refname)#{atoms.join("")}"

  out = git_out("for-each-ref --format=#{sh(fmt)}#{refs}")
  ahead_behind_readback(out, ahead_behind_columns(group, bases))
end

# name -> "<behind>\t<ahead>", parsed once so each node's lookup is O(1). Packed
# rather than Array[Integer] values, which Spinel widens (see pack_lines).
def ahead_behind_index(ab)
  index = {}
  unpack_lines(ab).each do |line|
    fields = line.split("\t")
    next if fields.length != 3

    index[fields[0]] = "#{fields[1]}\t#{fields[2]}"
  end
  index
end

# The in-memory topology of the stack forest: recorded parents, and the children
# index inverted from them.
#
# Broader than a valid tree on purpose. Config may hold a parent whose ref was
# deleted, an untracked parent, or a hand-written cycle, and `tree` has to show
# them for `sync`/`drop` to repair. New edges go through `validate_new_parent!`.
#
#   @parents   branch -> recorded parent           (config scan, trunks dropped)
#   @branches  the set of existing local branches
#   @children  parent -> "<child>\n<child>\n..."    (packed, see pack_lines)
class StackTopology
  def self.from_scan(branches, trunks, scan)
    topology = new(branches, trunks)
    topology.load(scan)
    topology
  end

  def initialize(branches, trunks)
    @parents = {}
    @branches = branches
    @trunks = Set.new(trunks)
    @children = {}
    # Explicit nil, or Spinel infers `-> String` from the last assignment.
    nil
  end

  # Parse a `scan_stack_config` string into the indexes. git lowercases the
  # variable name, hence `stackparent`.
  #
  # Two kinds of record are dropped here, so no reader has to retest them:
  #
  #   * A trunk's parent. Old or hand-written ones exist, and honouring one would
  #     let `restack` rebase a shared trunk onto another trunk.
  #   * An empty or blank value, which `get_parent` reads as "no parent".
  #     Indexed, it drew the branch as a root measured against the wrong trunk
  #     (#73). `--get-regexp` prints the key plus one space for an empty value,
  #     so without the strip it parsed differently on the last line.
  def load(scan)
    unpack_lines(scan).each do |line|
      space = line.index(" ")
      next if space.nil?

      key = line[0...space]
      value = line[(space + 1)..-1].strip
      next if value.empty?

      name = key.sub(/^branch\./, "").sub(/\.stackparent$/, "")
      next if trunk?(name)

      @parents[name] = value
    end
    index_children
    nil
  end

  def trunk?(name)
    @trunks.include?(name)
  end

  # True when `name` records a parent. Says nothing about the ref (that is
  # `branch?`); a trunk answers false.
  def tracked?(name)
    !@parents[name].nil?
  end

  # Reset first: rows are appended, so a second `load` would list every child
  # twice and `up` would see "multiple children".
  def index_children
    @children = {}
    @parents.each do |name, value|
      row = @children[value]
      @children[value] = row.nil? ? "#{name}\n" : "#{row}#{name}\n"
    end
    nil
  end

  # "" when none is recorded, which is always the case for a trunk.
  def parent_of(branch)
    parent = @parents[branch]
    parent.nil? ? "" : parent
  end

  # The sorted children of `branch`.
  #
  # `.to_s` guards against Spinel widening `@children` again: a widened value
  # splits to `unknown`, and iterating that is a baked-in NoMethodError. A no-op
  # while rbs/git-stack.rbs pins the field.
  def children_of(branch)
    row = @children[branch]
    return [] if row.nil?

    unpack_lines(row.to_s).sort
  end

  # The only view the snapshot gets of the parent index.
  def tracked_branches
    @parents.keys
  end

  # The subtree at `root` in pre-order (siblings sorted), one "<depth>\t<branch>"
  # line per node, `root` at depth 0. The cycle guard lives here once.
  def order(root)
    walk_order(root, 0, Set.new, "")
  end

  # Readers for one `order` line. A tab-less line answers "" (and depth 0), which
  # callers skip.
  def order_line_branch(line)
    tab_tail(line)
  end

  def order_line_depth(line)
    tab_head(line).to_i
  end

  # `order` without depths, for callers that traverse but never render. Decoded
  # from `order` so the two cannot disagree on order or on cycles.
  def order_branches(root)
    order(root).split("\n").map { |line| order_line_branch(line) }.reject { |name| name.empty? }
  end

  # Yields (branch, depth) in pre-order, so the packed rows never leave this class.
  def each_preorder(root)
    order(root).split("\n").each do |line|
      branch = order_line_branch(line)
      next if branch.empty?

      yield branch, order_line_depth(line)
    end
    nil
  end

  # `visited` stops a hand-edited cycle. `acc` is threaded and returned rather
  # than mutated, which keeps it a concrete String.
  def walk_order(branch, depth, visited, acc)
    return acc if visited.include?(branch)
    visited.add(branch)
    acc = "#{acc}#{depth}\t#{branch}\n"

    row = @children[branch]
    return acc if row.nil?

    # `.to_s`: see children_of.
    unpack_lines(row.to_s).sort.each do |child|
      acc = walk_order(child, depth + 1, visited, acc)
    end
    acc
  end

  def branch?(name)
    @branches.include?(name)
  end

  # The roots `tree` draws besides the trunks: the top of every tracked stack the
  # trunk walk cannot reach, because its parent was deleted or still exists but
  # is untracked (#58).
  #
  # Each branch climbs to its root rather than being tested where it sits, so the
  # answer does not depend on how branches sort. A root resting on a trunk is
  # dropped: the trunk walk already draws it. The whole emitted subtree is marked
  # covered, not just the root, because members of a cycle each climb to a
  # different root.
  def detached_roots
    roots = []
    covered = Set.new
    # `.sort` is safe on `.keys`: the hash widened on its values only.
    @parents.keys.sort.each do |name|
      next if covered.include?(name)

      root = detached_root(name)
      next if trunk?(parent_of(root))

      roots << root
      covered.merge(order_branches(root))
    end
    roots
  end

  # `detached_roots` whose ref still exists, for callers that move to a root
  # rather than draw it. A phantom would fail in `checkout!` with git's words, and
  # `containing_trunk` would hand it to the primary trunk. A named query rather
  # than a filter at each caller, so the next caller cannot forget it (#85).
  def live_detached_roots
    detached_roots.select { |root| branch?(root) }
  end

  # Every existing branch whose recorded parent's ref is gone: what `sync` heals,
  # wherever it sits in the forest (#55). A phantom (config outliving its ref) is
  # skipped; its live children are orphans in their own right.
  #
  # Narrower than `detached_roots`, since a live untracked parent is not broken.
  def orphan_roots
    @parents.keys.sort.select { |name| branch?(name) && parent_missing?(name) }
  end

  # The roots one `sync` pass replays from: `root`'s stack plus every orphaned
  # one. An orphan already inside an earlier root's subtree is dropped, so no
  # stack is replayed twice.
  def rebase_roots(root)
    orphans = orphan_roots
    return [root] if orphans.empty?

    with_roots([root], orphans)
  end

  # `roots` followed by each of `extra` not already inside an earlier subtree.
  def with_roots(roots, extra)
    acc = roots.map { |root| root }
    covered = Set.new
    roots.each { |root| covered.merge(order_branches(root)) }
    extra.each do |name|
      next if covered.include?(name)

      acc << name
      covered.merge(order_branches(name))
    end
    acc
  end

  # The root `tree` draws for `branch`'s stack. Unlike `stack_root`, it climbs past
  # a missing parent, to draw the row that says "run sync".
  def detached_root(branch)
    climb_to_root(branch, false)
  end

  # True when the recorded parent exists but is untracked. `tree` then draws this
  # branch at trunk-child indent, so its row has to name the parent `restack`
  # really rebases onto.
  def untracked_parent?(branch)
    parent = parent_of(branch)
    return false if parent.empty? || trunk?(parent) || tracked?(parent)

    branch?(parent)
  end

  # True when the recorded parent's ref is gone. Unlike an untracked parent, not a
  # valid edge for restack or drop.
  def parent_missing?(branch)
    parent = parent_of(branch)
    !parent.empty? && !branch?(parent)
  end

  # True when a dropped branch's children cannot reconnect to its parent (none
  # recorded, or its ref is gone), so a trunk has to stand in. Callers ask before
  # paying for `containing_trunk`.
  def reconnect_needs_trunk?(branch)
    parent = parent_of(branch)
    parent.empty? || !branch?(parent)
  end

  # A live parent, tracked or not, is the exact target; otherwise `fallback_trunk`.
  def reconnect_target(branch, fallback_trunk)
    return fallback_trunk if reconnect_needs_trunk?(branch)

    parent_of(branch)
  end

  # The root `restack`/`sync` replay from. Stops at an untracked parent, as
  # `detached_root` does, so `restack` never names a root `tree` does not draw
  # (#80); and at a missing parent, which is nothing to replay onto.
  def stack_root(branch)
    climb_to_root(branch, true)
  end

  # Walk up recorded parents and answer the last branch reached. Stops at a trunk,
  # at no parent, at a parent outside the tracked graph, and (with `require_ref`)
  # at a parent whose ref is gone. `seen` breaks a hand-edited cycle, which then
  # renders as a root. It is a Hash, not a Set: Spinel's Set scans an Array on
  # every `include?`, which makes the climb quadratic on a long chain.
  def climb_to_root(branch, require_ref)
    seen = {}
    loop do
      seen[branch] = true
      parent = parent_of(branch)
      break if parent.empty? || trunk?(parent)
      break unless tracked?(parent)
      break if require_ref && !branch?(parent)
      break if seen.key?(parent)

      branch = parent
    end
    branch
  end

  # True if making `new_parent` the parent of `branch` would close a cycle.
  # `seen` is a Hash for the same reason as in `climb_to_root`.
  def would_cycle?(branch, new_parent)
    seen = {}
    cur = new_parent
    loop do
      return true if cur == branch
      break if cur.empty? || trunk?(cur)
      break if seen.key?(cur)
      break unless branch?(cur)

      seen[cur] = true
      cur = parent_of(cur)
    end
    false
  end

  # `verb` words the cycle error for the calling command.
  def validate_new_parent!(branch, candidate, verb)
    die("branch '#{candidate}' does not exist") unless branch?(candidate)
    die("a branch cannot be its own parent") if candidate == branch
    die("'#{candidate}' is downstream of '#{branch}'; #{verb} would create a cycle") if would_cycle?(branch, candidate)
    nil
  end
end

# Reads config and refs, and builds the topology or the rendering snapshot from
# them.
class StackRepository
  def self.load_topology(trunks)
    # Config before refs, as it always was, so a ref/config change racing the
    # command behaves as it always has.
    scan = scan_stack_config
    branches = existing_branches
    StackTopology.from_scan(branches, trunks, scan)
  end

  def self.load_snapshot(trunks)
    StackSnapshot.new(load_topology(trunks), trunk_onto_refs(trunk_upstream_rows(trunks)))
  end
end

# The topology plus ahead/behind counts, for rendering.
#
# Holds no trunk: resolving one per node would cost a `rev-list` per trunk per
# node, in the scan built to keep `tree` off per-node subprocesses. The rows that
# once needed one are dropped by `load` (#73).
class StackSnapshot
  # `onto` as in `restack_subtree`, so `tree` measures a trunk child against the
  # same ref `restack` would replay it onto.
  def initialize(topology, onto)
    @topology = topology
    @onto = onto
    @ab = ahead_behind_index(scan_ahead_behind)
    nil
  end

  def topology
    @topology
  end

  # The full ref `branch` is measured against (see `parent_ref`).
  def parent_ref_of(branch)
    parent_ref(@topology.parent_of(branch), @onto)
  end

  # The upstream `trunk`'s children restack onto, or "" for the local branch.
  def upstream_of(trunk)
    up = @onto[trunk]
    up.nil? ? "" : up
  end

  # [behind, ahead]; [-1, -1] tells the renderer to ask per branch instead (git
  # without the batched atom).
  def ahead_behind_of(branch)
    packed = @ab[branch]
    return [-1, -1] if packed.nil?

    fields = packed.split("\t")
    return [-1, -1] if fields.length != 2

    [fields[0].to_i, fields[1].to_i]
  end

  def scan_ahead_behind
    pairs = ""
    @topology.tracked_branches.each do |name|
      next unless @topology.branch?(name)

      parent = @topology.parent_of(name)
      next unless @topology.branch?(parent)

      pairs = "#{pairs}#{name}\t#{parent_ref(parent, @onto)}\n"
    end

    result = ""
    unpack_lines(pairs).each_slice(AHEAD_BEHIND_CHUNK) do |chunk|
      result = "#{result}#{ahead_behind_chunk(pack_lines(chunk))}"
    end
    result
  end
end

# The note for a branch whose parent is untracked or missing, or "". The one
# source of these sentences for `tree`, `parent` and `down`, so they cannot drift
# (#85). The two cases are exclusive, so the order of the tests is meaningless.
def parent_note(branch, topology)
  parent = topology.parent_of(branch)
  return yellow("(parent '#{parent}' is untracked)") if topology.untracked_parent?(branch)
  return yellow("(parent '#{parent}' missing; run `#{PROG} sync`)") if topology.parent_missing?(branch)

  ""
end

# `parent_note` on stderr, clear of `parent`'s scripted stdout.
#
# Checks for a recorded parent before building the topology, which costs two
# repo-wide scans: `down` from a branch on a trunk, the most common command, has
# no note to print.
def print_parent_note(branch, trunks)
  return nil if get_parent(branch).empty?

  note = parent_note(branch, StackRepository.load_topology(trunks))
  info note unless note.empty?
  nil
end

# One tree row, indented two spaces per `depth`, read from the snapshot alone.
def print_tree_row(branch, depth, cur, snapshot)
  extra = ""
  topology = snapshot.topology
  parent = topology.parent_of(branch)
  if !parent.empty? && topology.branch?(parent)
    behind, ahead = snapshot.ahead_behind_of(branch)
    # git without the batched atom: ask per branch.
    if behind < 0
      behind, ahead = ahead_behind(snapshot.parent_ref_of(branch), branch)
    end
    if behind > 0
      extra = yellow("(needs restack: #{behind} behind)")
    elsif ahead > 0
      extra = dim("(#{ahead} commit(s))")
    end
  end

  # A row whose parent is not drawn above it must say where it really rests, or
  # the subtree looks like it belongs to the trunk.
  note = parent_note(branch, topology)
  unless note.empty?
    extra = extra.empty? ? note : "#{extra} #{note}"
  end

  puts "#{"  " * depth}#{tree_marker(branch, cur)} #{tree_name(branch, cur, "")} #{extra}"
  nil
end

# `root`'s subtree, `base` levels deep. `tree` passes base 0 for a trunk, skipping
# the root row it styles itself, and base 1 for a detached root.
def print_order(root, base, skip_root, cur, snapshot)
  snapshot.topology.each_preorder(root) do |branch, depth|
    next if skip_root && depth == 0

    print_tree_row(branch, depth + base, cur, snapshot)
  end
  nil
end

# --- subcommands ------------------------------------------------------------

def arg0(args)
  args.empty? ? "" : args[0]
end

# Command-level flags arrive mixed in with the operands (see COMMAND_FLAGS).
def has_flag?(args, flag)
  args.include?(flag)
end

# The first operand or "", wherever a flag sits -- so `drop --delete` still falls
# back to the current branch.
def first_operand(args)
  name = args.find { |a| operand?(a) }
  name.nil? ? "" : name
end

# The one definition of a positional, shared with `validate_args!` so a command
# line is never rejected for an argument the command would not read. `""` names
# no branch.
def operand?(arg)
  !arg.empty? && !arg.start_with?("-")
end

# `plant`/`fell` with no arguments: report the trunks without registering one.
#
# Not `init`'s listing, which registers what it detects: merely looking would turn
# the next `plant my-base` into "main and my-base", and it dies in a repo `fell`
# has to work in. A detection is labelled as one because `fell` cannot remove it.
#
# The order -- live configured trunks, else detection -- restates
# `trunk_branches`' rule, as `cmd_fell` does. Nothing couples the three, so change
# them together.
def report_trunks
  live = live_trunks(configured_trunks)
  unless live.empty?
    info "trunk(s): #{live.join(", ")}"
    return nil
  end

  detected = detect_trunk_or_empty
  if detected.empty?
    info "no trunk registered, and none to detect; run '#{PROG} init <branch>' or '#{PROG} plant <branch>'"
  else
    info "trunk(s): #{detected} (auto-detected, not registered)"
  end
  nil
end

# Rejected rather than deduped: a repeat is a typo, and a stored one drew a trunk's
# subtree twice (#83). Called after the per-name checks, so `init nope nope` still
# says "does not exist".
def check_trunk_repeats!(names)
  seen = Set.new
  names.each do |name|
    die("duplicate trunk '#{name}'") if seen.include?(name)

    seen.add(name)
  end
  nil
end

# Set the whole trunk list; `plant`/`fell` edit it one name at a time.
def cmd_init(args)
  if args.empty?
    # Unlike `report_trunks`, registers a detection: recording the trunk is
    # `init`'s job.
    trunks = trunk_branches
    info "trunk(s): #{trunks.join(", ")}"
    return
  end

  # Exact stored names (see `branch_ref_exists?`): a loose match let
  # `init main Main` store one branch as two trunks. Not deduped by commit
  # either, since `containing_trunk` supports trunks at the same commit.
  refs = existing_branches
  args.each do |trunk|
    die("branch '#{trunk}' does not exist") unless refs.include?(trunk)
  end
  check_trunk_repeats!(args)

  set_trunks(args)
  info "trunk set to #{args.join(", ")}"
end

# Register trunks alongside the existing ones. `init` needs the whole list
# retyped, and a name left out silently unregisters that trunk.
#
# Reads `configured_trunks`, not `trunk_branches`, so it never auto-detects: that
# dies in a repo with no main/master -- exactly where `plant my-base` is needed --
# and elsewhere would plant `main` beside the name asked for.
#
# A planted branch keeps its `stackParent`. Every reader ignores a trunk's parent,
# and keeping it makes `fell` an exact undo.
def cmd_plant(args)
  return report_trunks if args.empty?

  refs = existing_branches
  trunks = configured_trunks
  args.each do |name|
    # Not shared with `cmd_init`'s loop: the per-name checks differ, and splitting
    # them would change which error `plant <a-trunk> <no-such-branch>` gets.
    die("branch '#{name}' does not exist") unless refs.include?(name)
    # Not a silent no-op: the list is a set, so planting again cannot be meant.
    die("'#{name}' is already a trunk") if is_trunk?(name, trunks)
  end
  check_trunk_repeats!(args)

  # Appended: config order is precedence, so the primary trunk stays first. Only
  # live names are carried over, or a dead one would look confirmed in the
  # summary. `live_trunks` re-asks existence rather than taking `refs`, since its
  # signature is pinned in rbs/git-stack.rbs.
  planted = live_trunks(trunks) + args
  set_trunks(planted)
  info "planted #{green(args.join(", "))}; trunk(s): #{planted.join(", ")}"
  nil
end

# Unregister trunks, keeping the rest. Config only: the branch stays as an
# untracked branch, and stacks on it are drawn as detached roots.
#
# Felling the last trunk is allowed and leaves the key unset, so the next command
# auto-detects. That is how a wrong detection is undone without an `init` naming
# the very branch you wanted gone.
#
# Reads `configured_trunks`, not the live list, so a dead name can still be
# felled: when it is the last name and nothing is detectable, `trunk_branches`
# dies before it can prune it.
def cmd_fell(args)
  return report_trunks if args.empty?

  trunks = configured_trunks
  # Asked once, before removing anything, so each dead name is announced once. The
  # removal works on this list: a remainder of only dead names reads as empty, and
  # the next command would re-detect the branch just felled.
  live = live_trunks(trunks)
  # With no live configured trunk, the trunk in force is a detection. Asked only
  # then, since the ladder costs several `git` calls.
  detected = live.empty? ? detect_trunk_or_empty : ""
  args.each do |name|
    next if is_trunk?(name, trunks)

    # An unset key is what asks for detection, so "removing" the detected trunk
    # would change nothing. Point at registering the one wanted instead.
    if !detected.empty? && name == detected
      die("'#{name}' is auto-detected, not registered; run '#{PROG} init <branch>' or '#{PROG} plant <branch>' to register the trunk you want")
    end
    die("'#{name}' is not a trunk")
  end
  check_trunk_repeats!(args)

  # Order kept, so felling the primary promotes the next name.
  left = live.reject { |name| args.include?(name) }
  set_trunks(left)
  felled = green(args.join(", "))
  unless left.empty?
    info "felled #{felled}; trunk(s): #{left.join(", ")}"
    return nil
  end

  # Say which branch the next command will detect, or that none is left.
  # Detection reads refs only, never `stack.trunk`, so `detected` is still right
  # when it was asked.
  now = live.empty? ? detected : detect_trunk_or_empty
  if now.empty?
    info "felled #{felled}; no trunk left, and none to detect -- the next command will ask for '#{PROG} init <branch>'"
  else
    info "felled #{felled}; no trunk left -- the next command will auto-detect #{cyan(now)}"
  end
  nil
end

# Register anchors alongside the existing ones; with no arguments, list them.
# Shaped like `plant`.
def cmd_anchor(args)
  anchors = configured_anchors
  if args.empty?
    info(anchors.empty? ? "no anchor registered; run '#{PROG} anchor <branch>'" : "anchor(s): #{anchors.join(", ")}")
    return nil
  end

  refs = existing_branches
  trunks = trunk_branches
  args.each do |name|
    die("branch '#{name}' does not exist") unless refs.include?(name)
    die("trunk '#{name}' cannot be an anchor") if is_trunk?(name, trunks)
    die("'#{name}' is already an anchor") if anchors.include?(name)
    # It would be a graph node and an anchor at once, restacked and skipped.
    die("'#{name}' is stacked on '#{get_parent(name)}'; run '#{PROG} untrack' on it first") unless get_parent(name).empty?
  end
  die("duplicate anchor in '#{args.join(" ")}'") if args.uniq.length != args.length

  added = anchors + args
  set_anchors(added)
  info "anchored #{green(args.join(", "))}; anchor(s): #{added.join(", ")}"
  nil
end

# Unregister anchors. Their stacks stay, as ordinary stacks on the trunk.
def cmd_unanchor(args)
  anchors = configured_anchors
  return cmd_anchor(args) if args.empty?

  args.each do |name|
    die("'#{name}' is not an anchor") unless anchors.include?(name)
  end

  left = anchors.reject { |name| args.include?(name) }
  set_anchors(left)
  args.each { |name| release_anchor(name) }
  gone = green(args.join(", "))
  info(left.empty? ? "unanchored #{gone}; no anchor left" : "unanchored #{gone}; anchor(s): #{left.join(", ")}")
  nil
end

def cmd_create(args)
  name = arg0(args)
  die("usage: #{PROG} create <branch-name>") if name.empty?
  die("branch '#{name}' already exists") if branch_name_taken?(name)

  here = current_branch
  # On an anchor the stack rests on the anchor's trunk; elsewhere the new branch
  # joins whatever anchor its parent belongs to.
  on_anchor = configured_anchors.include?(here)
  parent = on_anchor ? containing_trunk(here, trunk_branches) : here
  anchor = on_anchor ? here : get_anchor(here)
  die("failed to create branch '#{name}'") unless git_ok("checkout -b #{sh(name)}")
  die("created branch '#{name}' but failed to record its parent") unless set_parent(name, parent)
  # A new branch has no commits yet, so its stack begins at the tip it was cut
  # from -- the anchor's, which may lag its trunk.
  record_tip_base(name, "refs/heads/#{here}")
  unless anchor.empty?
    set_anchor(name, anchor)
    mark_anchor_used(anchor) if on_anchor
  end
  where = on_anchor ? "#{cyan(parent)} (anchor #{cyan(here)})" : cyan(parent)
  info "created #{green(name)} on top of #{where}"
end

def cmd_tree(_args)
  trunks = trunk_branches
  cur = current_branch_or_empty
  snapshot = StackRepository.load_snapshot(trunks)

  # Detached roots are drawn under the trunk `containing_trunk` assigns them --
  # the answer `up`'s menu uses, so a trunk never shows a choice its menu refuses
  # (#91). Resolved once per root before the loop; asking inside it would cost
  # trunks^2 x roots `rev-list`s.
  #
  # Parallel arrays rather than a Hash or a packed index, both of which widened
  # `print_order` and its callees to untyped.
  #
  # A phantom root has no answerable trunk and lands on the primary; `tree` still
  # has to draw it somewhere.
  roots = snapshot.topology.detached_roots
  homes = roots.map { |root| containing_trunk(root, trunks) }
  # Anchors are drawn under the trunk their history rests on, as detached roots
  # are, with the stacks that record them one level further in.
  anchors = live_anchors
  anchor_homes = anchors.map { |anchor| containing_trunk(anchor, trunks) }
  members = anchor_memberships
  trunks.each do |trunk|
    up = snapshot.upstream_of(trunk)
    label = up.empty? ? "(trunk)" : "(trunk, restacks onto #{ref_label(up)})"
    puts "#{tree_marker(trunk, cur)} #{tree_name(trunk, cur, "36")} #{dim(label)}"
    stacks = snapshot.topology.children_of(trunk)
    anchors.each_with_index do |anchor, i|
      next unless anchor_homes[i] == trunk

      mine = stacks.select { |root| members[root] == anchor }
      print_anchor_row(anchor, trunk, !mine.empty?, cur, snapshot)
      mine.each { |root| print_order(root, 2, false, cur, snapshot) }
    end
    stacks.each do |root|
      # A stack recording an anchor that is gone or unregistered is drawn as an
      # ordinary one, rather than vanishing from `tree`.
      anchor = members[root]
      next if !anchor.nil? && anchors.include?(anchor)

      print_order(root, 1, false, cur, snapshot)
    end
    roots.each_with_index do |root, i|
      print_order(root, 1, false, cur, snapshot) if homes[i] == trunk
    end
  end
end

# An anchor's heading in `tree`. It is not a node, so it is measured against the
# trunk ref its stacks restack onto, and says whether `sync` has work to do.
#
# "done" needs the used mark: without it, an anchor whose stacks were all
# deleted looks exactly like one nobody has stacked on yet.
def print_anchor_row(anchor, trunk, has_stacks, cur, snapshot)
  up = snapshot.upstream_of(trunk)
  behind, _ahead = ahead_behind(up.empty? ? "refs/heads/#{trunk}" : up, anchor)
  label = dim("(anchor)")
  if !has_stacks && anchor_used?(anchor)
    label = green("(anchor, done)")
  elsif behind > 0
    label = yellow("(anchor, #{behind} behind; run `#{PROG} sync`)")
  end
  puts "  #{tree_marker(anchor, cur)} #{tree_name(anchor, cur, "")} #{label}"
  nil
end

def cmd_parent(args)
  branch = current_branch
  new_parent = arg0(args)
  trunks = trunk_branches
  if new_parent.empty?
    puts effective_parent(branch, trunks)
    # Only the read path looks for a note; setting a parent has none to print.
    print_parent_note(branch, trunks)
    return
  end
  die("cannot set parent of trunk '#{branch}'") if is_trunk?(branch, trunks)
  refuse_anchor_parent!(new_parent)
  StackRepository.load_topology(trunks).validate_new_parent!(branch, new_parent, "setting it as parent")
  reparent!(branch, new_parent, "failed to set parent of '#{branch}'")
  info "parent of '#{branch}' set to '#{new_parent}'"
end

def cmd_track(args)
  branch = current_branch
  trunks = trunk_branches
  parent = arg0(args)
  die("cannot track trunk '#{branch}'") if is_trunk?(branch, trunks)
  # The trunk its history rests on, not just the primary.
  parent = containing_trunk(branch, trunks) if parent.empty?
  refuse_anchor_parent!(parent)
  StackRepository.load_topology(trunks).validate_new_parent!(branch, parent, "tracking it")
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
  # A stack's root steps down to its anchor rather than the trunk: the trunk is
  # usually checked out in another worktree, and the anchor is where the next
  # stack is created.
  if parent != branch && is_trunk?(parent, trunks)
    anchor = get_anchor(branch)
    parent = anchor if !anchor.empty? && branch_ref_exists?(anchor) && configured_anchors.include?(anchor)
  end
  # Every trunk, and a branch hand-configured as its own parent.
  die("already at the bottom of the stack") if parent == branch
  die("parent branch '#{parent}' no longer exists") unless branch_ref_exists?(parent)
  # An untracked parent has no row in `tree`; say so before moving HEAD there
  # (#85).
  print_parent_note(branch, trunks)
  checkout!(parent)
end

def cmd_up(args)
  branch = current_branch
  trunks = trunk_branches
  want = arg0(args)
  # An anchor has no children in the graph; its stacks stand in for them.
  anchored = configured_anchors.include?(branch)

  unless want.empty?
    children = anchored ? anchor_stacks(StackRepository.load_topology(trunks), anchor_memberships, branch, trunks) : named_children_of(branch, trunks)
    # The menu path's wording: "'x' is not stacked..." would imply some other name
    # would have worked.
    die("no branch stacked on top of '#{branch}'") if children.empty?
    die("'#{want}' is not stacked directly on '#{branch}'") unless children.include?(want)
    checkout!(want)
    return
  end

  children = anchored ? anchor_stacks(StackRepository.load_topology(trunks), anchor_memberships, branch, trunks) : children_of(branch, trunks)
  die("no branch stacked on top of '#{branch}'") if children.empty?

  if children.length == 1
    checkout!(children[0])
    return
  end

  info "'#{branch}' has multiple #{anchored ? "stacks" : "children"}; pick one:"
  children.each do |child|
    info "  #{PROG} up #{child}"
  end
  exit 1
end

# The base for `git rebase --onto <parent> <base> <branch>`, or "" to plain-rebase
# onto `parent`.
#
# The recorded stackBase is kept only while it is a commit in `branch`'s history
# above the merge-base -- the squash-merged-parent case `--onto` exists for. A
# base below the merge-base is not used: after a manual rebase or pull, the
# commits in between are already in `parent` and would conflict.
#
# "" stands in for the merge-base, because `--onto <parent> <merge-base>` makes
# the merge-base the upstream and turns off git's patch-id skip: the old copies
# of a parent rebased outside git-stack are then re-applied and conflict.
#
# `onto` is the parent's full ref (see `parent_ref`).
def resolve_stack_base(branch, onto)
  base = get_base(branch)
  if base.empty?
    info "'#{branch}': no recorded stack base; rebasing onto '#{ref_label(onto)}'"
    return ""
  end
  unless git_ok("rev-parse --verify --quiet #{sh(base)}^{commit}") &&
         git_ok("merge-base --is-ancestor #{sh(base)} #{branch_ref(branch)}")
    info "'#{branch}': stack base #{base} is not in its history; rebasing onto '#{ref_label(onto)}'"
    return ""
  end
  mb = onto.empty? ? "" : git_out("merge-base #{branch_ref(branch)} #{sh(onto)}")
  return "" if !mb.empty? && git_ok("merge-base --is-ancestor #{sh(base)} #{sh(mb)}")
  base
end

# " in worktree '<path>'" for a branch another worktree holds, else "".
def worktree_suffix(wt)
  wt.empty? ? "" : " in worktree '#{wt}'"
end

# `git` options that run a command where `branch` is checked out: nothing here,
# `-C <wt>` in another worktree.
def worktree_at(wt)
  wt.empty? ? "" : "-C #{sh(wt)} "
end

# Replay `branch`'s own commits onto `parent`, or die with the recovery command.
# `verb` is the command to re-run after resolving a conflict. `wt` is the other
# worktree holding `branch`, or "". `onto` is the parent's full ref (see
# `parent_ref`).
def replay_onto!(branch, onto, verb, wt)
  parent = ref_label(onto)
  info "restacking #{cyan(branch)} onto #{cyan(parent)}#{worktree_suffix(wt)}"
  base = resolve_stack_base(branch, onto)
  at = worktree_at(wt)
  # The rev is qualified; the trailing branch stays bare because git checks it out
  # (see `branch_ref`). In another worktree it is already checked out, and naming
  # it is what git refuses.
  target = wt.empty? ? " #{sh(branch)}" : ""
  if base.empty?
    ok = git_ok("#{at}rebase #{sh(onto)}#{target}")
  else
    ok = git_ok("#{at}rebase --onto #{sh(onto)} #{sh(base)}#{target}")
  end
  return nil if ok

  git_ok("#{at}rebase --abort")
  recover = base.empty? ? "git rebase #{parent}" : "git rebase --onto #{parent} #{base}"
  go = wt.empty? ? "git checkout #{branch}" : "cd #{sh(wt)}"
  die("conflict while rebasing '#{branch}' onto '#{parent}'#{worktree_suffix(wt)}.\n" \
      "Resolve it manually with:\n" \
      "    #{go} && #{recover}\n" \
      "then re-run '#{PROG} #{verb}'.")
  nil
end

# Move `branch`, which has no commits of its own, up to `parent`'s tip.
def fast_forward!(branch, onto, wt)
  parent = ref_label(onto)
  info "fast-forwarding #{cyan(branch)} to #{cyan(parent)}#{worktree_suffix(wt)}"
  # `checkout` names a branch, `merge` takes a rev (see `branch_ref`).
  merge = "merge --ff-only #{sh(onto)}"
  ok = wt.empty? ? git_ok("checkout #{sh(branch)}") && git_ok(merge) : git_ok("#{worktree_at(wt)}#{merge}")
  die("failed to fast-forward '#{branch}' to '#{parent}'#{worktree_suffix(wt)}") unless ok
  nil
end

# Rebase every branch in `root`'s subtree onto its parent, parents first.
#
# An untracked branch is left alone, not rebased onto a trunk. With
# `heal_orphans` (`sync`), a branch whose parent is gone is first reparented onto
# the trunk its own history rests on -- per branch, since the wrong trunk would
# drop the commits of the one it was built on.
#
# `verb` is passed rather than derived from `heal_orphans`: `drop` heals nothing
# but must send the user to `restack`. `topology` stays valid for the whole walk,
# as nothing here creates or deletes refs and a healed orphan roots its own
# subtree.
#
# A branch another worktree holds is rewritten there (`held`, see
# `other_worktree_checkouts`). When that worktree cannot take it, the branch is
# skipped with all its descendants -- replaying them onto the stale parent would
# only have to be undone -- and the skipped names are returned, packed, for the
# caller to report. The rest of the forest is still restacked.
#
# `onto` maps a trunk to the upstream its children restack onto (see
# `trunk_onto_refs`); it is empty unless `stack.trunkUpstream` is on.
def restack_subtree(root, trunks, heal_orphans, verb, topology, held, onto)
  skipped = ""
  # A Hash for `key?`, not a Set: see `climb_to_root`.
  blocked = {}
  topology.order_branches(root).each do |branch|
    parent = topology.parent_of(branch)

    if heal_orphans && topology.parent_missing?(branch)
      trunk = containing_trunk(branch, trunks)
      info "'#{branch}': parent '#{parent}' no longer exists; reparenting onto trunk '#{trunk}'"
      die("failed to reparent '#{branch}'") unless set_parent(branch, trunk)
      parent = trunk
    end

    # Pre-order, so a parent's verdict is in before its children are reached.
    if blocked.key?(parent)
      info "warning: skipping '#{branch}': its parent '#{parent}' was skipped"
      blocked[branch] = true
      skipped = "#{skipped}#{branch}\n"
      next
    end

    if !parent.empty? && topology.branch?(parent)
      ref = parent_ref(parent, onto)
      behind, ahead = ahead_behind(ref, branch)
      # `behind == 0` has nothing to move but is still re-anchored below, which
      # back-fills a missing base. Nothing moves either, so a busy worktree
      # holding it is no reason to skip.
      if behind > 0
        wt = worktree_of(held, branch)
        busy = wt.empty? ? "" : worktree_busy_reason(wt)
        unless busy.empty?
          info "warning: skipping '#{branch}': its worktree '#{wt}' #{busy}"
          blocked[branch] = true
          skipped = "#{skipped}#{branch}\n"
          next
        end

        if ahead == 0
          # No commits of its own: fast-forward, since `--onto` would re-apply the
          # parent's work and conflict.
          fast_forward!(branch, ref, wt)
        else
          replay_onto!(branch, ref, verb, wt)
        end
      end
      # Every path above ends on the parent's tip, skips, or dies.
      record_tip_base(branch, ref)
    end
  end
  skipped
end

# Dies listing the branches `restack_subtree` skipped, if any, in place of
# `done.`: a partial restack must not read as success to a script.
def report_skipped!(skipped, verb)
  names = unpack_lines(skipped)
  return nil if names.empty?

  die("#{verb} skipped #{names.length} branch(es): #{names.join(", ")}\n" \
      "Deal with the worktrees warned about above, then re-run '#{PROG} #{verb}'.")
  nil
end

# The shared body of `restack` and `sync`, returning to the starting branch.
#
# `restack` replays only the current stack; anything more would rebase branches
# the user never named. `sync` also takes every orphaned stack, because `tree`
# prints "run sync" beside an orphan wherever it is run (#55). An untracked but
# live parent is not broken, so it never widens the scope.
#
# Run from an anchor or a stack on one, `sync` takes that anchor's stacks and
# only its own orphans, then moves the anchor up to its trunk. The orphans of
# other worktrees are left to them, unless `all`: their stacks may be mid-edit
# there, and healing them rebases branches this worktree never touched.
def run_stack_rebase(heal_orphans, verb, gerund, all)
  original = current_branch
  trunks = trunk_branches
  # Planned from one pre-heal snapshot; the heal rewrites config only.
  topology = StackRepository.load_topology(trunks)
  anchor = heal_orphans ? scope_anchor(original, live_anchors) : ""
  outside = 0
  if anchor.empty?
    root = topology.stack_root(original)
    roots = heal_orphans ? topology.rebase_roots(root) : [root]
  else
    # Assigned here, not beside `anchor` with a `{}` fallback: that literal widens
    # `anchor_stacks` to untyped under Spinel.
    members = anchor_memberships
    orphans = topology.orphan_roots
    mine = orphans.select { |name| all || members[name] == anchor }
    outside = orphans.length - mine.length
    roots = topology.with_roots(anchor_stacks(topology, members, anchor, trunks), mine)
  end
  held = other_worktree_checkouts(original)
  # Only `sync` fetches: `restack` has never touched the network.
  upstreams = trunk_upstream_rows(trunks)
  fetch_trunk_remotes(upstreams) if heal_orphans
  onto = trunk_onto_refs(upstreams)

  skipped = ""
  roots.each do |stack|
    info "#{gerund} stack rooted at #{cyan(stack)}"
    skipped = "#{skipped}#{restack_subtree(stack, trunks, heal_orphans, verb, topology, held, onto)}"
  end

  unless git_ok("checkout #{sh(original)}")
    die("#{verb} completed, but returning to '#{original}' failed;\n" \
        "you are now on '#{current_branch_or_empty}'. Check out '#{original}' manually.")
  end
  unless anchor.empty?
    follow_anchor(anchor, parent_ref(containing_trunk(anchor, trunks), onto), original, held)
    if outside > 0
      info "note: left #{outside} orphaned stack(s) outside anchor '#{anchor}' alone; run '#{PROG} sync --all' to heal them too"
    end
  end
  report_skipped!(skipped, verb)
  info green("done.")
  nil
end

# The anchor whose scope `sync` runs in from `branch`: the anchor itself, or the
# one `branch`'s stack records. "" outside any. `anchors` is `live_anchors`, so
# a stack still naming an unregistered anchor is not scoped by it.
def scope_anchor(branch, anchors)
  return branch if anchors.include?(branch)

  anchor = get_anchor(branch)
  anchors.include?(anchor) ? anchor : ""
end

# Fast-forward `anchor` to `ref`, the trunk ref its stacks were restacked onto,
# so a stack created on it next starts from there.
#
# Only ever a fast-forward, and a warning rather than a failure when that is not
# possible: the anchor is not a stack branch, so nothing of the user's is
# replayed onto it, and commits on it are theirs to keep.
#
# Checked out -- here (`here` is the current branch) or in another worktree --
# it is merged there, since git refuses to move a branch under a worktree.
# Otherwise `update-ref` with the old value, which fails rather than clobbers a
# concurrent move.
def follow_anchor(anchor, ref, here, held)
  behind, ahead = ahead_behind(ref, anchor)
  return nil if behind == 0

  target = ref_label(ref)
  if ahead > 0
    info "warning: leaving anchor '#{anchor}' where it is: it has #{ahead} commit(s) of its own, so it cannot fast-forward to '#{target}'"
    return nil
  end

  wt = anchor == here ? git_out("rev-parse --show-toplevel") : worktree_of(held, anchor)
  if wt.empty?
    info "fast-forwarding anchor #{cyan(anchor)} to #{cyan(target)}"
    old = git_out("rev-parse #{branch_ref(anchor)}")
    ok = git_ok("update-ref #{sh("refs/heads/#{anchor}")} #{sh(git_out("rev-parse #{sh(ref)}"))} #{sh(old)}")
  else
    busy = worktree_busy_reason(wt)
    unless busy.empty?
      info "warning: leaving anchor '#{anchor}' where it is: its worktree '#{wt}' #{busy}"
      return nil
    end
    shown = anchor == here ? "" : worktree_suffix(wt)
    info "fast-forwarding anchor #{cyan(anchor)} to #{cyan(target)}#{shown}"
    ok = git_ok("#{worktree_at(wt)}merge --ff-only --quiet #{sh(ref)}")
  end
  info "warning: failed to fast-forward anchor '#{anchor}' to '#{target}'" unless ok
  nil
end

# Push every branch of the current stack, parents first, to its remote. No PR is
# opened: that needs a host's API, which local mode leaves to the user.
#
# A branch that cannot be pushed is warned about and the rest still go, as
# `restack` does with a skipped worktree: each push is a separate ref, and a
# half-pushed stack is still better than none. The command then fails, naming
# them. Every remote is resolved before the first push, so a missing one stops
# the command with nothing pushed.
def cmd_submit(_args)
  branch = current_branch
  trunks = trunk_branches
  if is_trunk?(branch, trunks) || configured_anchors.include?(branch)
    die("'#{branch}' is not in a stack; check out a branch of the stack to submit")
  end
  topology = StackRepository.load_topology(trunks)
  die("'#{branch}' is not in a stack; check out a branch of the stack to submit") unless topology.tracked?(branch)

  root = topology.stack_root(branch)
  branches = topology.order_branches(root).select { |name| topology.branch?(name) }
  remotes = branches.map { |name| push_remote_for(name) }
  branches.each_with_index do |name, i|
    die("no remote to push '#{name}' to; add one with 'git remote add <name> <url>'") if remotes[i].empty?
  end

  info "submitting stack rooted at #{cyan(root)}"
  failed = ""
  branches.each_with_index do |name, i|
    why = push_branch(name, remotes[i])
    next if why.empty?

    info "warning: not pushing '#{name}': #{why}"
    failed = "#{failed}#{name}\n"
  end
  names = unpack_lines(failed)
  unless names.empty?
    die("submit failed for #{names.length} branch(es): #{names.join(", ")}\n" \
        "Deal with the branches warned about above, then re-run '#{PROG} submit'.")
  end
  info green("done.")
  nil
end

def cmd_restack(_args)
  run_stack_rebase(false, "restack", "restacking", false)
end

def cmd_sync(args)
  run_stack_rebase(true, "sync", "syncing", has_flag?(args, "--all"))
end

# Splice `branch` out: reconnect its children to its parent, untrack it, and
# restack them -- for when the bottom of a stack has merged. Run while the branch
# still exists, so children reconnect to the real grandparent; delete-then-`sync`
# could only heal them onto trunk.
#
# Rewrites config only; `--delete` also removes the ref. No merge detection:
# running `drop` is the assertion that the branch is done.
def cmd_drop(args)
  delete = has_flag?(args, "--delete")
  operand = first_operand(args)
  # HEAD read once, for both the default branch and where to return.
  original = current_branch_or_empty
  branch = operand.empty? ? require_branch(original) : operand
  trunks = trunk_branches
  die("cannot drop trunk '#{branch}'") if is_trunk?(branch, trunks)

  # Stale after the rewrites below, which rebuild it.
  topology = StackRepository.load_topology(trunks)
  die("branch '#{branch}' does not exist") unless topology.branch?(branch)

  # A missing parent cannot be the target: the restack below does not heal, so
  # writing that name onto each child would turn one orphan into N. The trunk is
  # resolved only when needed, since `containing_trunk` costs a `rev-list` per
  # trunk.
  parent = topology.parent_of(branch)
  trunk = topology.reconnect_needs_trunk?(branch) ? containing_trunk(branch, trunks) : ""
  # Only a missing parent has a dead name to report.
  if topology.parent_missing?(branch)
    info "'#{branch}': parent '#{parent}' no longer exists; reconnecting children onto trunk '#{trunk}'"
  end
  parent = topology.reconnect_target(branch, trunk)

  moved = topology.children_of(branch)
  moved.each do |child|
    reparent!(child, parent, "failed to reparent '#{child}' onto '#{parent}'")
  end

  untrack!(branch)
  info "dropped #{green(branch)}; reparented children onto #{cyan(parent)}"

  topology = StackRepository.load_topology(trunks)
  held = other_worktree_checkouts(original)
  onto = trunk_onto_refs(trunk_upstream_rows(trunks))
  skipped = ""
  moved.each do |child|
    # "restack", not "drop", on conflict: the splice is already in config.
    skipped = "#{skipped}#{restack_subtree(child, trunks, false, "restack", topology, held, onto)}"
  end

  if delete
    # The checked-out branch cannot be deleted.
    git_ok("checkout #{sh(parent)}") if current_branch_or_empty == branch
    # Bare: `branch -D` only sees branches (see `branch_ref`).
    die("dropped '#{branch}' but failed to delete its ref") unless git_ok("branch -D #{sh(branch)}")
    info "deleted branch #{green(branch)}"
  end

  # The restack may have left HEAD on a moved child, and `--delete` may have
  # removed `original`.
  if !original.empty? && original != current_branch_or_empty && branch_ref_exists?(original)
    git_ok("checkout #{sh(original)}")
  end
  # Last, so the splice, the delete and the return to `original` still happen.
  report_skipped!(skipped, "restack")
  nil
end

def cmd_version(_args)
  puts "#{PROG} #{VERSION}"
  # Only a Spinel-built binary reports "spinel" here; CRuby names its own version.
  return unless RUBY_DESCRIPTION == "spinel"

  # 12 characters, matching `spinel --version`'s short rev.
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
        plant [branch...]     Add branch(es) to the trunks, keeping the rest. (no args: list them)
        fell [branch...]      Remove branch(es) from the trunks; the branch itself is kept. (no args: list them)
        anchor [branch...]    Register branch(es) a worktree tool made as anchors to stack on. (no args: list them)
        unanchor [branch...]  Unregister anchor(s); their stacks stay on the trunk.
        create <name>         Create <name> stacked on the current branch. (aliases: b, branch)
        tree                  Show the stack as a tree. (aliases: ls, list)
        up [child]            Check out the branch stacked on the current one.
        down                  Check out the current branch's parent.
        parent [branch]       Show or set the parent of the current branch.
        track [parent]        Track the current branch on top of [parent] (or trunk).
        untrack               Stop tracking the current branch in a stack.
        drop [branch]         Splice [branch] (or the current branch) out of the stack, reconnecting its children to its parent. (--delete also removes the branch)
        restack               Rebase the whole stack so each branch sits on its parent.
        sync [--all]          Reparent branches whose parent was deleted (e.g. merged via a PR) onto trunk, then restack. In an anchor: its stacks only, then fast-forward the anchor (--all: every orphan).
        submit                Push every branch of the current stack, parents first, with --force-with-lease.
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

# Command-level flags, as "<flag>\t<the one command that accepts it>". Listed, so
# a typo like `--delet` is still rejected. The owner lives in the row because
# these flags are lifted out of argv before the command is known.
COMMAND_FLAGS = ["--delete\tdrop", "--all\tsync"].freeze

# The command that accepts `flag`, or "".
def flag_owner(flag)
  row = COMMAND_FLAGS.find { |r| tab_head(r) == flag }
  row.nil? ? "" : tab_tail(row)
end

def command_flag?(arg)
  !flag_owner(arg).empty?
end

# Not nil: the golden pins `max_operands` as `(String) -> Integer`, and a nilable
# return would widen everything it feeds. -1 already means "unlimited".
UNKNOWN_COMMAND = -2

# How many operands each command accepts: -1 for unlimited, UNKNOWN_COMMAND for a
# name not listed.
#
# This duplicates `main`'s `case`, in the same order. Not folded into it: here an
# unlisted command dies on its first run, whereas a `case` arm could simply omit
# its guard and run unvalidated.
def max_operands(cmd)
  case cmd
  when "init", "plant", "fell" then -1
  when "anchor", "unanchor" then -1
  when "create", "b", "branch" then 1
  when "tree", "ls", "list" then 0
  when "up", "next" then 1
  when "down", "prev" then 0
  when "parent", "track" then 1
  when "untrack" then 0
  when "drop" then 1
  when "restack", "sync", "submit", "version", "help" then 0
  else UNKNOWN_COMMAND
  end
end

# Reject what the dispatcher would otherwise absorb in silence, before touching the
# repo: an extra operand (`create feat-b oops` ignored `oops`), or a lifted flag
# reaching a command that does not own it. The latter reuses the unknown-option
# wording, since to the user it is the same mistake.
def validate_args!(cmd, args)
  max = max_operands(cmd)
  die("unknown command '#{cmd}' (try '#{PROG} help')") if max == UNKNOWN_COMMAND

  args.each do |arg|
    owner = flag_owner(arg)
    die("invalid option: #{arg}") if !owner.empty? && owner != cmd
  end
  return nil if max < 0

  operands = args.reject { |a| !operand?(a) }
  return nil if operands.length <= max

  die(max == 0 ? "'#{cmd}' takes no arguments" : "'#{cmd}' takes at most one argument")
  nil
end

# Take -h/-v out of `argv`, wherever they appear, and return "help", "version" or
# "".
#
# Spinel's `parse!` leaves an unknown flag in argv instead of raising, so the
# leftover check reports it with CRuby's message.
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
  leftover = argv.find { |arg| arg.start_with?("-") }
  die("invalid option: #{leftover}") unless leftover.nil?
  cmd
end

def main(argv)
  # Lifted first: CRuby's `parse!` rejects any unregistered long option, so
  # `--delete` would be reported as an invalid global option.
  flags = argv.select { |a| command_flag?(a) }
  cleaned = argv.reject { |a| command_flag?(a) }

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
  rest += flags

  # Before `require_repo`: a bad command line is wrong in any directory.
  validate_args!(cmd, rest)

  repo_optional = cmd == "version" || cmd == "help"
  unless repo_optional
    require_repo
    prune_vanished_anchors
  end

  case cmd
  when "init"                 then cmd_init(rest)
  when "plant"                then cmd_plant(rest)
  when "fell"                 then cmd_fell(rest)
  when "anchor"               then cmd_anchor(rest)
  when "unanchor"             then cmd_unanchor(rest)
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
  when "submit"               then cmd_submit(rest)
  when "version"              then cmd_version(rest)
  when "help"                 then cmd_help(rest)
  else
    die("unknown command '#{cmd}' (try '#{PROG} help')")
  end
  # Explicit nil: the `case`'s mixed branch types would widen to untyped.
  nil
end

main(ARGV)
