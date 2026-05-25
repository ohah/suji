#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage: scripts/homebrew-formula.sh <version> <macos-arm64-sha256> <linux-x64-sha256> [release-base-url]

Example:
  scripts/homebrew-formula.sh 0.1.0 <sha> <sha>
EOF
}

if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
  usage
  exit 2
fi

version="$1"
macos_sha="$2"
linux_sha="$3"
base_url="${4:-https://github.com/ohah/suji/releases/download/v${version}}"
base_url="${base_url%/}"

if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "invalid version: $version" >&2
  exit 2
fi

if ! [[ "$macos_sha" =~ ^[[:xdigit:]]{64}$ ]]; then
  echo "invalid macOS sha256: $macos_sha" >&2
  exit 2
fi

if ! [[ "$linux_sha" =~ ^[[:xdigit:]]{64}$ ]]; then
  echo "invalid Linux sha256: $linux_sha" >&2
  exit 2
fi

cat <<EOF
class Suji < Formula
  desc "Zig core multi-backend desktop framework"
  homepage "https://github.com/ohah/suji"
  license "MIT"
  version "${version}"

  if OS.mac? && Hardware::CPU.arm?
    url "${base_url}/suji-macos-arm64.tar.gz"
    sha256 "${macos_sha}"
  elsif OS.linux? && Hardware::CPU.intel?
    url "${base_url}/suji-linux-x64.tar.gz"
    sha256 "${linux_sha}"
  else
    odie "Suji Homebrew binaries are currently available for macOS arm64 and Linux x86_64"
  end

  def install
    bin.install "suji"
    prefix.install "LICENSE" if File.exist?("LICENSE")
    doc.install "README.md" if File.exist?("README.md")
  end

  test do
    assert_match "Suji", shell_output("#{bin}/suji 2>&1")
  end
end
EOF
