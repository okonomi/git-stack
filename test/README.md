# Tests

Two independent suites exercise git-stack.

## `spin test` — Spinel snapshot tests

```sh
spin test              # build each test/*.rb with Spinel and run it
spin test up_down.rb   # just one
```

Each `test/*.rb` requires `support/harness.rb`, which pulls in
`bin/git-stack.rb` itself and drives its functions against a throwaway
repository under `build/test/`. Spinel compiles the test to a native binary
and **CRuby is the oracle**: `spin test` runs the same source under CRuby and
the two outputs must match. That checks two things at once — that the test's
assertions hold, and that git-stack behaves identically compiled and
interpreted.

Coverage: `help` and `sh_quote` are pure (no repo); `create_and_tree`,
`up_down`, `restack`, `parent_track`, `untrack`, `create_rejects_existing`,
and `dispatch_unknown` spin up real repos and drive the commands end to end,
mirroring `run.sh`.

### Conventions that keep the snapshots deterministic

- **Never reassign `$stdout` or `$stderr`.** Spinel is a whole-program
  compiler and unifies a global's type across every use; a single
  `$stderr = …` anywhere retypes `$stderr` to `unknown`, and git-stack's
  `info`/`die` writes then silently vanish in the compiled build (but not
  under CRuby), breaking parity. The suite lets git-stack's own stderr land in
  the captured output — it is deterministic — and reads state back with the
  `git_state` helper.
- Repos live at a **fixed** path under `build/test/` (not a random `mktemp`),
  so no temp directory name leaks into the output.
- `NO_COLOR=1` and `GIT_STACK_TEST_NOEXEC=1` are set by the harness (the
  latter keeps `bin/git-stack.rb` from auto-running `main` when required).

### Do not use `spin test --regen`

`--regen` writes `.expected` snapshot files by capturing **stdout only**
(`… 2>/dev/null`), whereas a normal run compares the **merged** `stdout`+`stderr`
(`… 2>&1`). Because these end-to-end tests intentionally surface git-stack's
stderr (progress lines, `error:` messages, git's own "Switched to branch …"),
a regenerated `.expected` would be missing that half and the next run would
fail. There are therefore no committed `.expected` files: CRuby is the live
oracle on every run. Frozen goldens would also be fragile across git versions,
which the live oracle avoids (the compiled build and the oracle share the same
`git`).

## `run.sh` — dependency-free bash suite

```sh
test/run.sh
GIT_STACK="$PWD/build/bin/git-stack" test/run.sh   # exercise the Spinel binary
```

Asserts on each command in throwaway repositories, running the Ruby script
under CRuby by default. See the comment at the top of `run.sh`.
