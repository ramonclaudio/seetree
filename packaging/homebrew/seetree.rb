class Seetree < Formula
  desc "Live terminal tree viewer that lights up as Claude Code edits files"
  homepage "https://github.com/ramonclaudio/seetree"
  version "VERSION_PLACEHOLDER"
  license "MIT"

  on_macos do
    on_arm do
      url "https://github.com/ramonclaudio/seetree/releases/download/vVERSION_PLACEHOLDER/seetree-aarch64-macos"
      sha256 "SHA_AARCH64_MACOS"
    end
    on_intel do
      url "https://github.com/ramonclaudio/seetree/releases/download/vVERSION_PLACEHOLDER/seetree-x86_64-macos"
      sha256 "SHA_X86_64_MACOS"
    end
  end

  on_linux do
    on_arm do
      url "https://github.com/ramonclaudio/seetree/releases/download/vVERSION_PLACEHOLDER/seetree-aarch64-linux-musl"
      sha256 "SHA_AARCH64_LINUX"
    end
    on_intel do
      url "https://github.com/ramonclaudio/seetree/releases/download/vVERSION_PLACEHOLDER/seetree-x86_64-linux-musl"
      sha256 "SHA_X86_64_LINUX"
    end
  end

  resource "extras" do
    url "https://github.com/ramonclaudio/seetree/releases/download/vVERSION_PLACEHOLDER/seetree-extras.tar.gz"
    sha256 "SHA_EXTRAS"
  end

  def install
    binary = Dir["seetree-*"].first
    bin.install binary => "seetree"

    resource("extras").stage do
      bash_completion.install "completions/seetree.bash" => "seetree"
      zsh_completion.install "completions/_seetree"
      fish_completion.install "completions/seetree.fish"
      man1.install "man/seetree.1"
    end
  end

  test do
    assert_match "seetree", shell_output("#{bin}/seetree --version")
  end
end
