#!/usr/bin/env python3
"""Generate the versioned Homebrew cask for a published FVM GUI release."""

import argparse
import re
from pathlib import Path


VERSION_PATTERN = re.compile(r"\d+\.\d+(?:\.\d+)?\Z")
SHA256_PATTERN = re.compile(r"[0-9a-fA-F]{64}\Z")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--sha256", required=True)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    if not VERSION_PATTERN.fullmatch(args.version):
        parser.error("version must be numeric, such as 1.0 or 1.2.3")
    if not SHA256_PATTERN.fullmatch(args.sha256):
        parser.error("sha256 must contain exactly 64 hexadecimal characters")

    cask = f'''cask "fvm-gui" do
  version "{args.version}"
  sha256 "{args.sha256.lower()}"

  url "https://github.com/lephuhao24/flutters/releases/download/v#{{version}}/FVM-GUI.zip"
  name "FVM GUI"
  desc "Native macOS interface for managing Flutter SDKs with FVM"
  homepage "https://github.com/lephuhao24/flutters"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "FVM GUI.app"

  caveats <<~EOS
    This tester build is not signed or notarized. macOS may block its first launch.
    Only install releases from a source you trust. If blocked, review the app in
    System Settings > Privacy & Security and use Open Anyway only after verifying
    the release checksum.
  EOS
end
'''

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(cask, encoding="utf-8")


if __name__ == "__main__":
    main()
