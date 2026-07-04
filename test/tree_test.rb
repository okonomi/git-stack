# Snapshot test: create / tree / parent / up / down.
#
# Runs the compiled git-stack binary against a throwaway repository and prints
# a deterministic transcript. `spin test` diffs stdout against
# test/tree_test.rb.expected. The binary under test is $GIT_STACK (set by CI /
# the Makefile); it defaults to build/bin/git-stack next to this project.

ROOT = `pwd`.strip
env_gs = ENV["GIT_STACK"]
GS = (env_gs.nil? || env_gs == "") ? "#{ROOT}/build/bin/git-stack" : env_gs

# Run a setup command silently (git plumbing we don't want in the snapshot).
def run_quiet(cmd)
  system("#{cmd} >/dev/null 2>&1")
end

# Run git-stack in the repo and return its combined output (colour disabled so
# the snapshot is stable regardless of TTY).
def stack(dir, gs, args)
  `cd #{dir} && NO_COLOR=1 #{gs} #{args} 2>&1`
end

DIR = `mktemp -d`.strip

# A deterministic repo: a single base commit on `main`, no signing.
run_quiet("cd #{DIR} && git init -q")
run_quiet("cd #{DIR} && git config user.email t@example.com")
run_quiet("cd #{DIR} && git config user.name tester")
run_quiet("cd #{DIR} && git config commit.gpgsign false")
run_quiet("cd #{DIR} && git commit -q --allow-empty -m base")
run_quiet("cd #{DIR} && git branch -M main")

print "== init ==\n"
print stack(DIR, GS, "init main")

# Build a two-branch stack: main -> feature-a -> feature-b.
run_quiet("cd #{DIR} && #{GS} create feature-a")
run_quiet("cd #{DIR} && git commit -q --allow-empty -m a1")
run_quiet("cd #{DIR} && #{GS} create feature-b")
run_quiet("cd #{DIR} && git commit -q --allow-empty -m b1")

print "== tree (on feature-b) ==\n"
print stack(DIR, GS, "tree")

print "== parent of feature-b ==\n"
print stack(DIR, GS, "parent")

print "== down to feature-a ==\n"
print stack(DIR, GS, "down")
print stack(DIR, GS, "tree")

print "== up back to feature-b ==\n"
print stack(DIR, GS, "up")
print stack(DIR, GS, "tree")

run_quiet("rm -rf #{DIR}")
