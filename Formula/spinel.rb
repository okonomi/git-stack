# Homebrew formula for Spinel, Matz's ahead-of-time Ruby compiler.
#
# Spinel is not packaged upstream and has no tagged releases, so this pins a
# specific commit. It lives in the okonomi/git-stack tap because git-stack
# build-depends on it to compile its native binary — it is not meant as a
# general-purpose Spinel package.
#
# Keep the revision in sync with SPINEL_REF in .github/workflows/ci.yml and
# the SessionStart hook (.claude/hooks/session-start.sh).
class Spinel < Formula
  desc "Ahead-of-time Ruby compiler (pinned build for git-stack)"
  homepage "https://github.com/matz/spinel"
  url "https://github.com/matz/spinel.git",
      revision: "11ec0497760fa4617cef1ac1b21b0d712aec0499"
  version "0.0.0-11ec049"
  license "MIT"

  # `make deps` normally curls these gems from rubygems.org for their bundled
  # C sources, but Homebrew builds with no network. Vendor them as resources
  # and unpack them into vendor/ so the build runs offline.
  resource "prism" do
    url "https://rubygems.org/gems/prism-1.9.0.gem"
    sha256 "7b530c6a9f92c24300014919c9dcbc055bf4cdf51ec30aed099b06cd6674ef85"
  end

  resource "rbs" do
    url "https://rubygems.org/gems/rbs-4.0.1.gem"
    sha256 "e237fd49787fb265bf0f389f2f0f5788fdcdf1f49bb54b4f7952cea904162a07"
  end

  def install
    # Unpack the vendored gems into the layout `make deps` produces, so its
    # dependency targets are already satisfied and no network fetch happens.
    # A .gem is a tar wrapping data.tar.gz, which holds the gem's files.
    { "prism" => buildpath/"vendor/prism",
      "rbs"   => buildpath/"vendor/rbs" }.each do |name, dest|
      resource(name).stage do
        gem = Dir["*.gem"].first
        system "tar", "-xf", gem, "data.tar.gz"
        dest.mkpath
        system "tar", "-xzf", "data.tar.gz", "-C", dest
      end
    end

    system "make", "deps" # no-op: vendor/ is already populated
    system "make"
    # Installs the real binaries under lib/spinel/ with bin/ symlinks into
    # them; those binaries resolve their runtime lib via /proc/self/exe
    # (realpath on macOS), so they keep working through Homebrew's own bin
    # symlinks and when invoked from another formula's build.
    system "make", "install", "PREFIX=#{prefix}"
  end

  test do
    assert_path_exists bin/"spin"
    system bin/"spin", "--help"
  end
end
