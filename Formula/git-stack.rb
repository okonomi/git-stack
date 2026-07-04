# Homebrew formula for git-stack.
#
# This repository doubles as its own Homebrew tap. Install with:
#
#     brew tap okonomi/git-stack https://github.com/okonomi/git-stack
#     brew install git-stack
#
# The formula downloads the prebuilt Spinel native binary for your platform
# (built by .github/workflows/release.yml), so Spinel is not required to
# install. `git` is the only runtime dependency.
class GitStack < Formula
  desc "Manage stacked branches with plain git"
  homepage "https://github.com/okonomi/git-stack"
  version "0.1.0"
  license "MIT"

  on_macos do
    on_arm do
      url "https://github.com/okonomi/git-stack/releases/download/v0.1.0/git-stack-0.1.0-macos-arm64.tar.gz"
      sha256 "0000000000000000000000000000000000000000000000000000000000000000"
    end
    on_intel do
      url "https://github.com/okonomi/git-stack/releases/download/v0.1.0/git-stack-0.1.0-macos-x86_64.tar.gz"
      sha256 "0000000000000000000000000000000000000000000000000000000000000000"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/okonomi/git-stack/releases/download/v0.1.0/git-stack-0.1.0-linux-arm64.tar.gz"
      sha256 "0000000000000000000000000000000000000000000000000000000000000000"
    end
    on_intel do
      url "https://github.com/okonomi/git-stack/releases/download/v0.1.0/git-stack-0.1.0-linux-x86_64.tar.gz"
      sha256 "0000000000000000000000000000000000000000000000000000000000000000"
    end
  end

  depends_on "git"

  def install
    bin.install "git-stack"
  end

  test do
    assert_match "git stack", shell_output("#{bin}/git-stack help")
  end
end
