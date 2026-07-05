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
class GitStack < Formula
  desc "Manage stacked branches with plain git"
  homepage "https://github.com/okonomi/git-stack"
  head "https://github.com/okonomi/git-stack.git", branch: "main"
  license "MIT"

  # git-stack is a self-contained Ruby script that shells out to `git`.
  depends_on "git"

  def install
    # Install the script as `git-stack` so it works both directly and as the
    # `git stack` subcommand (git picks up `git-*` executables on PATH).
    bin.install "bin/git-stack.rb" => "git-stack"
  end

  test do
    assert_match "git stack", shell_output("#{bin}/git-stack version")
  end
end
