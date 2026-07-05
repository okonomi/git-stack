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
Because Spinel isn't packaged, the formula builds it from a pinned source ref
as part of the install, so the first `brew install` takes a little longer.

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

The parent of each branch is stored in your repository's git config:

```
branch.<name>.stackParent = <parent-branch>
```

The bottom of every stack rests on the **trunk** (`main`/`master`), stored
as `stack.trunk`. Because everything lives in git config, there is no extra
state file to commit and nothing to keep in sync.

## Commands

| Command                 | Description                                                        |
| ----------------------- | ------------------------------------------------------------------ |
| `git stack init [branch]` | Set (or auto-detect) the trunk branch.                           |
| `git stack create <name>` | Create `<name>` stacked on the current branch. (alias: `b`)     |
| `git stack tree`          | Show the stack as a tree. (aliases: `ls`, `list`)               |
| `git stack up [child]`    | Check out the branch stacked on the current one.                |
| `git stack down`          | Check out the current branch's parent.                          |
| `git stack parent [branch]` | Show or set the parent of the current branch.                 |
| `git stack track [parent]`  | Track the current branch on top of `[parent]` (or trunk).     |
| `git stack untrack`       | Stop tracking the current branch in a stack.                    |
| `git stack restack`       | Rebase the whole stack so each branch sits on its parent.       |
| `git stack version`       | Show the git-stack version.                                    |

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
