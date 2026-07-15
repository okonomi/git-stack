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
branch has no recorded base (e.g. it predates this feature), `restack` falls
back to the live merge-base of the branch and its parent.

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
stack down when they reach any trunk. The **first** trunk you register is the
*primary* one: it's the default base a branch falls back to — for example when
`git stack sync` reparents a branch whose parent was merged and deleted.

## Commands

| Command                 | Description                                                        |
| ----------------------- | ------------------------------------------------------------------ |
| `git stack init [branch...]` | Set (or auto-detect) the trunk branch(es).                    |
| `git stack create <name>` | Create `<name>` stacked on the current branch. (alias: `b`)     |
| `git stack tree`          | Show the stack as a tree. (aliases: `ls`, `list`)               |
| `git stack up [child]`    | Check out the branch stacked on the current one.                |
| `git stack down`          | Check out the current branch's parent.                          |
| `git stack parent [branch]` | Show or set the parent of the current branch.                 |
| `git stack track [parent]`  | Track the current branch on top of `[parent]` (or trunk).     |
| `git stack untrack`       | Stop tracking the current branch in a stack.                    |
| `git stack restack`       | Rebase the whole stack so each branch sits on its parent.       |
| `git stack sync`          | Detect & delete merged branches, reparent what was stacked on them, then restack every stack. |
| `git stack version`       | Show the git-stack version and the Spinel build revision.       |

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

Once `feature-a` merges, a single `sync` cleans up after it — from any branch,
even straight from `main`:

```sh
git checkout main && git pull
git stack sync                  # detects the merge, deletes feature-a,
                                # reparents feature-b onto main, and restacks
```

`sync` finds merged branches for you, so there's no manual `git branch -d`
(which fails anyway on a squash- or rebase-merged branch — its commits were
rewritten, so its tip isn't an ancestor of trunk). It then deletes each merged
branch, reparents whatever was stacked on it onto that branch's own parent (so a
merged *middle* branch's children land on their grandparent, not just trunk), and
restacks every stack in the repo — not only the one you're standing in.

### How `sync` detects a merge

It works from plain git, with an optional GitHub assist:

- **Reachable merge** — the branch's tip is an ancestor of a trunk (a merge
  commit, fast-forward, or rebase-merge whose tip still lives). Pure git.
- **Upstream gone** — after `git fetch --prune`, the branch's upstream tracking
  ref reads `[gone]`, i.e. its remote counterpart was deleted. This is what
  GitHub does on merge when *"automatically delete head branches"* is on, and is
  the primary signal for squash- and rebase-merged branches (whose tip never
  lands in trunk). Pure git.
- **PR merged** *(optional)* — `gh pr view <branch>` reports the PR as `MERGED`.
  A backstop for repos with auto-delete off. Off by default; enable it with
  `git config stack.mergeDetection gh` (requires the `gh` CLI and a GitHub
  origin). The two pure-git signals above are unaffected either way.

`sync` runs `git fetch --prune` up front so the upstream-gone check is accurate;
it's a no-op when there's no `origin`.

`git stack tree` flags branches that have drifted from their parent:

```
  main (trunk)
    feature-a (2 commit(s))
      feature-b (needs restack: 1 behind)
```

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

## Tests

The suite lives in `test/cli_test.rb`, a Spinel **snapshot test**: it drives
each command in throwaway repositories and prints a transcript of exactly what
they emit (output + exit status). `spin test` compiles it with Spinel and
diffs that transcript against the committed snapshot in
`test/cli_test.rb.expected` — any change in behaviour shows up as a diff.

```sh
spin test                 # run the test and diff its output against the snapshot
spin test --regen         # refresh the snapshot after an intentional change
```

It is also a plain Ruby program, so you can print/regenerate the transcript
under CRuby without Spinel:

```sh
ruby test/cli_test.rb                                # print the transcript
ruby test/cli_test.rb > test/cli_test.rb.expected    # regenerate the snapshot
```

By default it drives the Ruby script under CRuby; point `GIT_STACK` at another
build to test that one instead:

```sh
GIT_STACK="$PWD/build/bin/git-stack" ruby test/cli_test.rb   # compiled Spinel binary
```

## License

MIT — see [LICENSE](LICENSE).
