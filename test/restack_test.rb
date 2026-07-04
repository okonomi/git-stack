# Snapshot test: restack replays a child branch after its parent moves.
#
# Uses real file commits (not empty ones) so the rebase is unambiguous. See
# tree_test.rb for the harness conventions.

ROOT = `pwd`.strip
env_gs = ENV["GIT_STACK"]
GS = (env_gs.nil? || env_gs == "") ? "#{ROOT}/build/bin/git-stack" : env_gs

def run_quiet(cmd)
  system("#{cmd} >/dev/null 2>&1")
end

def stack(dir, gs, args)
  `cd #{dir} && NO_COLOR=1 #{gs} #{args} 2>&1`
end

# Commit a new file so the commit is non-empty and rebases cleanly.
def commit_file(dir, name)
  run_quiet("cd #{dir} && echo #{name} > #{name}.txt && git add -A && git commit -q -m #{name}")
end

DIR = `mktemp -d`.strip
run_quiet("cd #{DIR} && git init -q")
run_quiet("cd #{DIR} && git config user.email t@example.com")
run_quiet("cd #{DIR} && git config user.name tester")
run_quiet("cd #{DIR} && git config commit.gpgsign false")
commit_file(DIR, "base")
run_quiet("cd #{DIR} && git branch -M main")
run_quiet("cd #{DIR} && #{GS} init main")

# main -> feature-a (a1) -> feature-b (b1)
run_quiet("cd #{DIR} && #{GS} create feature-a")
commit_file(DIR, "a1")
run_quiet("cd #{DIR} && #{GS} create feature-b")
commit_file(DIR, "b1")

# Add a new commit to feature-a; feature-b is now one commit behind its parent.
run_quiet("cd #{DIR} && #{GS} down")
commit_file(DIR, "a2")

print "== tree before restack (feature-b is behind) ==\n"
print stack(DIR, GS, "tree")

print "== restack ==\n"
print stack(DIR, GS, "restack")

print "== tree after restack (feature-b caught up) ==\n"
print stack(DIR, GS, "tree")

run_quiet("rm -rf #{DIR}")
