# Homebrew formula for git-stack.
#
# This repo doubles as its own Homebrew tap. Because it is not named
# `homebrew-git-stack`, tap it with an explicit URL:
#
#     brew tap okonomi/git-stack https://github.com/okonomi/git-stack
#     brew install git-stack
#
# There are no tagged releases yet, so the formula is HEAD-only: it builds
# straight from the tip of `main`. Once a release is cut, add `url`/`sha256`
# stable stanzas alongside the `head` line below.
#
# The install compiles bin/git-stack.rb into a standalone native binary with
# Spinel (Matz's ahead-of-time Ruby compiler), so the installed `git-stack`
# carries no Ruby runtime dependency. Spinel isn't packaged, so it ships as a
# sibling formula in this tap (Formula/spinel.rb) and is pulled in as a build
# dependency below.
class GitStack < Formula
  desc "Manage stacked branches with plain git"
  homepage "https://github.com/okonomi/git-stack"
  head "https://github.com/okonomi/git-stack.git", branch: "main"
  license "MIT"

  # The compiled binary shells out to `git` at run time; that is its only
  # runtime dependency. Spinel is only needed to build it.
  depends_on "git"
  depends_on "okonomi/git-stack/spinel" => :build

  def install
    # Stamp the exact Spinel revision compiling this binary into the source, so
    # `git stack version` reports its real build toolchain. bin/git-stack.rb
    # ships SPINEL_REF as an empty placeholder; fill it in here with the actual
    # `spinel --version` before `spin build`. `spinel --version` prints
    # "spinel <short-rev>"; take the revision token when present.
    rev = Utils.safe_popen_read("spinel", "--version").split[1]
    inreplace "bin/git-stack.rb", /^SPINEL_REF = ".*"$/, %Q(SPINEL_REF = "#{rev}") if rev

    # Compile bin/git-stack.rb -> build/bin/git-stack with Spinel, then install
    # that native binary. Naming it `git-stack` lets it work both directly and
    # as the `git stack` subcommand (git picks up `git-*` executables on PATH).
    system "spin", "build"
    bin.install "build/bin/git-stack"
  end

  test do
    assert_match "git stack", shell_output("#{bin}/git-stack version")
  end
end
