# Homebrew formula for git-stack. This repo is its own tap; it is not named
# `homebrew-git-stack`, so tap it with an explicit URL:
#
#     brew tap okonomi/git-stack https://github.com/okonomi/git-stack
#     brew install git-stack
#
# HEAD-only because there are no tagged releases yet; add `url`/`sha256` once
# one is cut.
#
# Compiled to a native binary with Spinel, so no Ruby runtime is needed. Spinel
# is not packaged, hence the sibling formula (Formula/spinel.rb).
class GitStack < Formula
  desc "Manage stacked branches with plain git"
  homepage "https://github.com/okonomi/git-stack"
  head "https://github.com/okonomi/git-stack.git", branch: "main"
  license "MIT"

  # `git` at run time; Spinel only to build.
  depends_on "git"
  depends_on "okonomi/git-stack/spinel" => :build

  def install
    # A compiled binary cannot ask for its compiler's revision at run time, so
    # `git stack version` reads SPINEL_REF, stamped here before `spin build`.
    rev = Utils.safe_popen_read("spinel", "--version").split[1]
    inreplace "bin/git-stack.rb", /^SPINEL_REF = ".*"$/, %Q(SPINEL_REF = "#{rev}") if rev

    # Named `git-stack` so git also runs it as `git stack`.
    system "spin", "build"
    bin.install "build/bin/git-stack"
  end

  test do
    assert_match "git stack", shell_output("#{bin}/git-stack version")
  end
end
