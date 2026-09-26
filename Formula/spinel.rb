# Homebrew formula for Spinel, pinned for git-stack's build rather than as a
# general-purpose package. Upstream has no packages or tags, so the stable build
# pins a commit; `brew install --HEAD okonomi/git-stack/spinel` builds upstream
# `master` for trying the latest.
#
# REVISION must match SPINEL_REF in .github/workflows/ci.yml and the
# SessionStart hook; CI fails when the three disagree.
class Spinel < Formula
  # `version` derives from this rather than repeating the sha: Homebrew detects
  # upgrades by the version string, not `revision:`, so a bump that missed one
  # would leave installs reporting up to date.
  REVISION = "a3be2abdc09c3d5fa7094948baa7ce4d40dbb397".freeze

  desc "Ahead-of-time Ruby compiler (pinned build for git-stack)"
  homepage "https://github.com/matz/spinel"
  url "https://github.com/matz/spinel.git", revision: REVISION
  version "0.0.0-#{REVISION[0, 7]}"
  license "MIT"
  head "https://github.com/matz/spinel.git", branch: "master"

  # `make deps` curls these gems for their C sources, but Homebrew builds without
  # network, so they are vendored as resources.
  resource "prism" do
    url "https://rubygems.org/gems/prism-1.9.0.gem"
    sha256 "7b530c6a9f92c24300014919c9dcbc055bf4cdf51ec30aed099b06cd6674ef85"
  end

  resource "rbs" do
    url "https://rubygems.org/gems/rbs-4.0.1.gem"
    sha256 "e237fd49787fb265bf0f389f2f0f5788fdcdf1f49bb54b4f7952cea904162a07"
  end

  def install
    # Laid out as `make deps` would leave them, so its targets are already
    # satisfied. A .gem is a tar wrapping data.tar.gz. HEAD builds reuse these
    # too, so bump the resources if upstream moves off prism 1.9.0 / rbs 4.0.1.
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
    # The binaries find their runtime lib through their own realpath, so they
    # keep working behind Homebrew's bin symlinks and from another formula's
    # build.
    system "make", "install", "PREFIX=#{prefix}"
  end

  test do
    assert_path_exists bin/"spin"
    system bin/"spin", "--help"
  end
end
