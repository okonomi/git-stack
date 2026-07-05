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
# carries no Ruby runtime dependency. Spinel is not packaged, so it is built
# from a pinned source ref as part of the install, mirroring CI and the
# SessionStart hook.
class GitStack < Formula
  desc "Manage stacked branches with plain git"
  homepage "https://github.com/okonomi/git-stack"
  head "https://github.com/okonomi/git-stack.git", branch: "main"
  license "MIT"

  # The compiled binary shells out to `git` at run time; that is its only
  # runtime dependency.
  depends_on "git"

  # Spinel, built from source to compile git-stack. Keep this revision in
  # sync with SPINEL_REF in .github/workflows/ci.yml and the SessionStart
  # hook (.claude/hooks/session-start.sh).
  resource "spinel" do
    url "https://github.com/matz/spinel.git",
        revision: "0ee18cfc7496d1c50cb5399919544d174ab38572"
  end

  # Spinel's `make deps` normally curls these gems from rubygems.org for their
  # bundled C sources, but Homebrew builds with no network. Vendor them as
  # resources and unpack them into Spinel's vendor/ so the build runs offline.
  resource "prism" do
    url "https://rubygems.org/gems/prism-1.9.0.gem"
    sha256 "7b530c6a9f92c24300014919c9dcbc055bf4cdf51ec30aed099b06cd6674ef85"
  end

  resource "rbs" do
    url "https://rubygems.org/gems/rbs-4.0.1.gem"
    sha256 "e237fd49787fb265bf0f389f2f0f5788fdcdf1f49bb54b4f7952cea904162a07"
  end

  def install
    spinel_prefix = buildpath/"spinel"

    resource("spinel").stage do
      spinel_src = Pathname.pwd

      # Unpack the vendored gems into the layout `make deps` produces, so its
      # dependency targets are already satisfied and no network fetch happens.
      # A .gem is a tar wrapping data.tar.gz, which holds the gem's files.
      { "prism" => spinel_src/"vendor/prism",
        "rbs"   => spinel_src/"vendor/rbs" }.each do |name, dest|
        resource(name).stage do
          gem = Dir["*.gem"].first
          system "tar", "-xf", gem, "data.tar.gz"
          dest.mkpath
          system "tar", "-xzf", "data.tar.gz", "-C", dest
        end
      end

      system "make", "deps" # no-op: vendor/ is already populated
      system "make"
      system "make", "install", "PREFIX=#{spinel_prefix}"
    end

    # Compile bin/git-stack.rb -> build/bin/git-stack with the freshly built
    # Spinel, then install that native binary. Naming it `git-stack` lets it
    # work both directly and as the `git stack` subcommand (git picks up
    # `git-*` executables on PATH).
    ENV.prepend_path "PATH", spinel_prefix/"bin"
    system "spin", "build"
    bin.install "build/bin/git-stack"
  end

  test do
    assert_match "git stack", shell_output("#{bin}/git-stack version")
  end
end
