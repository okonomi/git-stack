# Shared harness for the git-stack snapshot tests run by `spin test`.
#
# Each test/*.rb requires this and then drives git-stack's own functions
# against a throwaway repository. Spinel compiles the test to a native binary
# and CRuby is the oracle, so the two outputs must match -- which also proves
# git-stack behaves identically whether compiled or interpreted.
#
# This file lives under test/support/ so `spin test` (which globs test/*.rb,
# non-recursively) does not pick it up as a test of its own.

# Keep bin/git-stack.rb from auto-running main() when we require it, and force
# escape-free, deterministic output.
ENV["GIT_STACK_TEST_NOEXEC"] = "1"
ENV["NO_COLOR"] = "1"
require_relative "../../bin/git-stack"

# Create a fresh repo with a single commit on `main` and chdir into it. The
# repo lives under build/test (so `spin clean` wipes it) at a fixed path -- not
# a random mktemp -- so its name never leaks into a snapshot.
def new_repo(name)
  dir = "build/test/repo_" + name
  system("rm -rf " + dir + " && mkdir -p " + dir)
  Dir.chdir(dir)
  system("git init -q -b main >/dev/null 2>&1")
  system("git config user.email test@example.com >/dev/null 2>&1")
  system("git config user.name Test >/dev/null 2>&1")
  system("git config commit.gpgsign false >/dev/null 2>&1")
  system("echo base > file.txt && git add file.txt && git commit -qm base >/dev/null 2>&1")
end

# Write `msg` to `file` and commit it with that message.
def commit(file, msg)
  system("echo " + msg + " > " + file +
         " && git add " + file +
         " && git commit -qm " + msg + " >/dev/null 2>&1")
end

# Trimmed stdout of a shell command, for reading git state back deterministically.
#
# Note: this suite never reassigns $stdout or $stderr. Spinel is a whole-program
# compiler that unifies a global's type across every use, so a single
# `$stderr = ...` anywhere would retype $stderr to `unknown` and make git-stack's
# `info`/`die` writes vanish in the compiled build (but not under CRuby),
# breaking parity. Instead we let git-stack's own stderr land in the snapshot --
# it is deterministic -- and assert on git state with the helper below.
def git_state(cmd)
  `#{cmd} 2>/dev/null`.strip
end
