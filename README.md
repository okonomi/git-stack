# git-stack

Manage **stacked branches** with plain git — no server, no database, no
dependencies beyond `git` and `ruby`.

Stacked branches (a.k.a. stacked diffs) let you split a large change into a
chain of small, dependent branches:

```
main ─▶ feature-a ─▶ feature-b ─▶ feature-c
```

Each branch builds on the one below it. When you amend a branch near the
bottom, everything above it needs to be replayed — `git-stack` tracks the
parent of each branch and does that replay for you.

## Install

`git-stack` is a single self-contained Ruby script (`bin/git-stack.rb`). It
shells out to `git` for everything (via `system()` and backticks), so it needs
nothing beyond `git` and a Ruby interpreter.

### Homebrew

This repo doubles as its own Homebrew tap (`Formula/git-stack.rb`). Since the
repo isn't named `homebrew-git-stack`, tap it with an explicit URL:

```sh
brew tap okonomi/git-stack https://github.com/okonomi/git-stack
brew install git-stack
git stack help
```

There are no tagged releases yet, so the formula builds from the tip of `main`.
It compiles the script into a standalone native binary with Spinel (see below),
so the installed `git-stack` needs no Ruby runtime — only `git` at run time.
Because Spinel isn't packaged, the tap ships it as a sibling formula
(`Formula/spinel.rb`) that `git-stack` pulls in as a build dependency and
builds from a pinned source ref, so the first `brew install` takes a little
longer.

### Ruby script

Put it anywhere on your `PATH` with a name starting with `git-` and git will
pick it up as the `git stack` subcommand:

```sh
install -m 0755 bin/git-stack.rb /usr/local/bin/git-stack
git stack help
```

(You can also run `ruby bin/git-stack.rb ...` directly from a checkout.)

### Native binary (Spinel)

The script is written in the subset of Ruby that
[Spinel](https://github.com/matz/spinel), Matz's ahead-of-time Ruby compiler,
accepts. This repo is a Spinel project (`spin.toml`), so its `spin` tool
compiles the script straight to a standalone native executable — no Ruby
runtime needed at run time:

```sh
spin build                       # -> build/bin/git-stack (native binary)
install -m 0755 build/bin/git-stack /usr/local/bin/git-stack
git stack help

# or let spin place it on PATH for you:
spin install                     # copies it to ~/.local/bin
```

## How it works

Each branch records two things in your repository's git config: its parent, and
the commit its parent sat at when the branch was stacked (its *base*):

```
branch.<name>.stackParent = <parent-branch>
branch.<name>.stackBase   = <sha>
```

The base marks where the branch's own commits begin, so `restack` replays
exactly those commits with `git rebase --onto <parent> <base>`. This is what
lets a stack survive a parent that was **squash-merged** into trunk and then
deleted: a plain `git rebase` would re-apply the parent's already-merged commits
(after squashing, their patch-ids no longer match, so git can't drop them) and
conflict, while `--onto` replays only the commits above the recorded base. If a
branch has no usable base (it predates this feature, or the recorded commit is
no longer in its history), or the base is at or below the merge-base of the
branch and its parent, `restack` runs a plain `git rebase <parent>`. That way git
still drops commits whose patches the parent already has, such as the old copies
left under a branch after its parent was rebased outside git-stack.

The bottom of every stack rests on a **trunk** (`main`/`master`), stored
as `stack.trunk`. Because everything lives in git config, there is no extra
state file to commit and nothing to keep in sync.

### Multiple trunks

Some workflows have more than one long-lived base branch — git-flow, for
example, uses both `main` and `develop`. `stack.trunk` is a multi-valued git
config key, so you can register several trunks and stack branches on whichever
one you like:

```sh
git stack init main develop     # both are trunks
git stack init                  # -> trunk(s): main, develop
```

Each trunk is a root in `git stack tree`, and `restack`/`sync` stop walking a
stack down when they reach any trunk.

`init` writes the **whole** list, so `plant` and `fell` edit it one name at a
time — no re-typing the names you're keeping, and no silently dropping one you
forgot to repeat:

```sh
git stack plant develop         # -> planted develop; trunk(s): main, develop
git stack fell develop          # -> felled develop; trunk(s): main
git stack plant                 # (no args) -> trunk(s): main
```

Neither touches a branch ref: `fell` unregisters the trunk and leaves the branch
alone, the way `drop` leaves a dropped branch alone. A branch stacked on a felled
trunk keeps its recorded parent, so nothing is orphaned and `restack` still
replays onto it — but the felled branch is untracked now, so `tree` draws that
stack as a root of its own until you `git stack track` it back into one.

With no arguments both just report the list, and — unlike `init` — register
nothing while doing it, so looking never changes what the next command does.

`plant` never auto-detects for you either: it starts from whatever is configured,
empty list included, so `plant my-base` on a fresh repo means exactly what
`init my-base` means. Planting appends, and the **first** trunk stays primary, so
a new trunk never displaces the tie-breaker a repo already relies on.

Felling the *last* trunk is allowed. It unsets the key, leaving the repo as it
was before `init` — so the next command falls back to auto-detection, and `fell`
tells you which branch that will be:

```sh
git stack fell main    # -> no trunk left -- the next command will auto-detect main
```

Which is the catch worth knowing: an auto-detected trunk is **not** a registered
one, so felling a trunk that detection would pick again just hands it back. To
change which branch a repo treats as its base, register the one you want:

```sh
git stack init my-base          # my-base is now the trunk
```

For the same reason `fell` refuses a trunk that is only auto-detected — there is
no registration to remove, and the command would report a success that changed
nothing. `git stack plant` (no arguments) is what tells the two apart:

```
trunk(s): main, develop                     # registered
trunk(s): main (auto-detected, not registered)
```

Trunks are peers, so the commands that need a trunk without one to follow —
`git stack track` with no argument, `git stack sync` reparenting a branch whose
parent was merged and deleted, `git stack drop` reconnecting the children of a
branch that sat directly on a trunk, and `git stack down`/`parent` on an
untracked branch — pick the trunk the branch's own history rests on: a stack
built on `develop` stays on `develop`. The **first** trunk you
register is the *primary* one, used as the tie-breaker when history can't
distinguish them (two trunks still pointing at the same commit). `sync` names
the trunk it picked, since it rewrites the branch as well as its config.

A registered trunk that is later renamed or deleted is dropped from the list on
the next command, with a note saying so — a name with no branch cannot be
rebased onto, and `sync` would otherwise record it as a branch's parent. (You can
also remove it outright with `git stack fell <name>` — the way to drop a dead
name without having to name a replacement.) If none of the registered trunks is
left, git-stack auto-detects one again (so renaming `master` to `main` just
works) and asks you to run `git stack init <branch>` only when there is nothing
to detect.

### Restacking onto the trunk's upstream

By default a branch whose parent is a trunk is restacked onto the **local**
trunk, so following the latest `main` means `git checkout main && git pull`
first. With worktrees that is often impossible: `main` stays checked out in
another worktree, and git refuses to update it from here.

```sh
git config stack.trunkUpstream true
```

makes such branches restack onto, and `tree` measure them against, the trunk's
upstream (`origin/main`) instead, and has `git stack sync` fetch that remote
first. One `sync` from any worktree then follows the remote trunk. `restack`
and `drop` use the upstream as it was last fetched and never fetch.

- `stackParent` still names the trunk (`main`); only the ref it resolves to
  changes. `git stack tree` shows it as `main (trunk, restacks onto
  origin/main)`.
- A trunk without an upstream (including every trunk in a repository with no
  remote) keeps its local branch. So does one whose upstream has not been
  fetched yet, with a warning.
- If the fetch fails (offline, say), `sync` warns and uses the upstream as last
  fetched.
- Commits that exist only on the local trunk (not yet pushed) are no longer
  under your stack's base.

It is off by default because it changes what an existing setup restacks onto,
and has `sync` touch the network.

## Commands

| Command                 | Description                                                        |
| ----------------------- | ------------------------------------------------------------------ |
| `git stack init [branch...]` | Set (or auto-detect) the trunk branch(es).                    |
| `git stack plant [branch...]` | Add branch(es) to the trunks, keeping the rest. With no argument, list the trunks. |
| `git stack fell [branch...]`  | Remove branch(es) from the trunks; the branch itself is kept. With no argument, list the trunks. |
| `git stack anchor [branch...]` | Register branch(es) as anchors to stack on (see [Anchors](#anchors)). With no argument, list the anchors. |
| `git stack unanchor [branch...]` | Unregister anchor(s); their stacks stay on the trunk. |
| `git stack create <name>` | Create `<name>` stacked on the current branch. (aliases: `b`, `branch`) |
| `git stack tree`          | Show the stack as a tree. (aliases: `ls`, `list`)               |
| `git stack up [child]`    | Check out the branch stacked on the current one.                |
| `git stack down`          | Check out the current branch's parent.                          |
| `git stack parent [branch]` | Show or set the parent of the current branch.                 |
| `git stack track [parent]`  | Track the current branch on top of `[parent]` (or trunk).     |
| `git stack untrack`       | Stop tracking the current branch in a stack.                    |
| `git stack drop [branch]` | Splice `[branch]` (or the current branch) out of the stack, reconnecting its children to its parent. (`--delete` also removes the branch) |
| `git stack restack`       | Rebase the whole stack so each branch sits on its parent.       |
| `git stack sync`          | Restack the current stack, and reparent every branch whose parent was deleted (e.g. merged via a PR) onto trunk — wherever in the repository it sits. |
| `git stack version`       | Show the git-stack version and the Spinel build revision.       |
| `git stack help`          | Show the built-in help.                                         |

## Walkthrough

```sh
git checkout main

git stack create feature-a      # main -> feature-a, now on feature-a
# ... hack, commit ...

git stack create feature-b      # feature-a -> feature-b, now on feature-b
# ... hack, commit ...

git stack tree
#   main (trunk)
#     feature-a (1 commit(s))
#     * feature-b (1 commit(s))

# Address review feedback on the lower branch:
git stack down                  # back to feature-a
# ... amend, add a commit ...

git stack restack               # replay feature-b on the new feature-a
git stack up                    # back up to feature-b
```

Once a branch merges, `drop` it: this reconnects whatever was stacked on it to
its parent and restacks — *while the merged branch still exists*, so the
reconnection is exact:

```sh
git checkout main && git pull

git stack drop feature-a        # reparents feature-b onto main and restacks it
git branch -d feature-a         # delete the merged branch when you're ready
                                # (or `git stack drop feature-a --delete`)
```

`drop` touches the **stack graph only** — it never deletes the branch ref unless
you pass `--delete`, keeping every destructive act explicit and in your hands.
It does no merge detection either: invoking `drop` *is* your assertion that the
branch is done.

The order matters. Reconnecting *before* deleting is what lets `drop` re-anchor a
child onto its true grandparent. Dropping `feature-b` from
`main → feature-a → feature-b → feature-c` reconnects `feature-c` onto
**`feature-a`**, because `feature-b`'s recorded parent is still readable at drop
time:

```sh
git stack drop feature-b        # feature-c is reparented onto feature-a
```

Contrast with `git stack untrack`, which just orphans the children, and with
`git stack sync`, which heals *after* a parent was already deleted and only ever
reconnects onto trunk (the grandparent link is gone by then). `sync` is still the
right tool when a branch was deleted out from under a stack — for example by a
PR merge that auto-deleted the remote branch — and you're repairing the orphans
after the fact:

```sh
git checkout main && git pull
git branch -d feature-a         # merged and deleted first

git stack sync                  # reparents the orphaned feature-b onto main
```

It heals every orphan in the repository, not just the stack you happen to be
standing in — so the `sync` `git stack tree` recommends beside an orphaned
branch repairs it from wherever you run it, no checkout first.

`git stack tree` flags branches that have drifted from their parent:

```
  main (trunk)
    feature-a (2 commit(s))
      feature-b (needs restack: 1 behind)
```

A stack whose parent is no longer part of the tree — untracked, or merged and
deleted — is drawn as a root of its own rather than dropped from the picture,
with the reason on the row. It sits at the indent a trunk's own children get, so
the note is what tells you `restack` still replays it onto the recorded parent
(`feature-a` here) and not onto the trunk:

```
  main (trunk)
    feature-b (1 commit(s)) (parent 'feature-a' is untracked)
      feature-c (1 commit(s))
```

With more than one trunk, the trunk it is drawn under is the one its history
actually rests on, and that is the same trunk `git stack up` offers it from — so
a stack grown on `develop` is never drawn as though it belonged to `main`.

## Adopting existing branches

Already have a branch you want to fold into a stack?

```sh
git checkout my-existing-branch
git stack track main            # or any other branch as the parent
```

## Restack conflicts

If a rebase hits a conflict, `git stack restack` aborts cleanly and leaves
your working tree untouched, telling you how to resolve it by hand:

```sh
git checkout <branch> && git rebase <parent>
# resolve conflicts, git rebase --continue
git stack restack               # continue restacking the rest
```

## Worktrees

Stack metadata lives in git config, which every worktree of a repository
shares, so `tree`, `restack`, `sync` and `drop` see the same stacks from any of
them.

A branch that another worktree has checked out cannot be checked out here, so
`restack`, `sync` and `drop` rebase it from inside that worktree instead
(`git -C <worktree> rebase ...`). On a conflict the rebase there is aborted, and
the message says `cd <worktree>` rather than `git checkout <branch>`.

If that worktree has uncommitted changes to tracked files, a rebase or merge in
progress, or no longer exists on disk, the branch is skipped together with every
branch stacked on it, and the rest of the stack is still restacked. The command
then lists what it skipped and exits non-zero instead of printing `done.`. A
branch that is already up to date is never skipped.

Two worktrees restacking at once can collide on git's config lock. git-stack
retries a locked write for about a second; a lock that outlasts that was left
behind by a killed git, and git-stack tells you where it is rather than
removing it.

### Anchors

A worktree tool such as git-wt makes a branch for each worktree it creates.
That branch sits on the trunk with no commits of its own, and your stacks grow
on top of it. Register it as an **anchor** so git-stack knows what it is:

```sh
git stack anchor feature-x      # -> anchored feature-x; anchor(s): feature-x
git stack anchor                # (no args) -> anchor(s): feature-x
git stack unanchor feature-x    # -> unanchored feature-x; no anchor left
```

An anchor is not part of any stack. `git stack create` on an anchor records the
anchor's **trunk** as the new branch's parent, so the stack is restacked onto
the trunk, its first PR targets the trunk, and the anchor itself is never
rebased. What the anchor adds is membership: every branch created on it, or on
top of such a branch, records `branch.<name>.stackAnchor`. It is kept on every
branch rather than on the stack's root, because deleting a merged root deletes
its config with it.

`git stack tree` draws each anchor as a heading under its trunk, with the
stacks that belong to it one level further in:

```
  main (trunk)
    feature-x (anchor)
      feat-a (1 commit(s))
      * feat-b (1 commit(s))
      fix-c (2 commit(s))
    other-branch (1 commit(s))
```

It looks like a parent, but it is not one: `feat-a` and `fix-c` are restacked
onto `main`. The heading says ``(anchor, N behind; run `git stack sync`)`` when
the trunk has moved on, and `(anchor, done)` once every branch created on it
has been deleted — the worktree can then be removed with your worktree tool.
git-stack never deletes an anchor or a worktree.

`git stack down` from a stack's root goes to its anchor rather than the trunk —
the trunk is usually checked out in another worktree, and the anchor is where
the next stack is created — and `git stack up` from an anchor goes to its stack,
or lists them when there are several.

A trunk cannot be an anchor, an anchor cannot be a parent (`track` and `parent`
refuse it), and a branch already in a stack must be untracked before it can
become one. `unanchor` keeps the stacks; they become ordinary stacks on the
trunk.

## Tests

The suite lives in `test/`, split by topic (`init_test.rb`, `sync_test.rb`,
`drop_test.rb`, …), with the shared harness in `test/support/helper.rb`. Each
file is a Spinel **snapshot test**: it drives its commands in throwaway
repositories and prints a transcript of exactly what they emit (output + exit
status). `spin test` compiles each one with Spinel and diffs its transcript
against the committed snapshot beside it — any change in behaviour shows up as
a diff.

```sh
spin test                 # run the test and diff its output against the snapshot
spin test --regen         # refresh the snapshot after an intentional change
```

It is also a plain Ruby program, so you can print/regenerate the transcript
under CRuby without Spinel:

```sh
ruby test/sync_test.rb                                 # print one file's transcript
ruby test/sync_test.rb > test/sync_test.rb.expected    # regenerate that snapshot
```

By default it drives the Ruby script under CRuby; point `GIT_STACK` at another
build to test that one instead:

```sh
GIT_STACK="$PWD/build/bin/git-stack" ruby test/sync_test.rb   # compiled Spinel binary
```

## License

MIT — see [LICENSE](LICENSE).
