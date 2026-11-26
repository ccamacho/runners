#!/bin/bash
# Install the GitHub CLI to ~/bin (no sudo needed).
set -euo pipefail

GH_VERSION=2.105.0
GH_BIN="$HOME/bin/gh"

if [ -x "$GH_BIN" ]; then
  echo "gh already installed: $("$GH_BIN" --version | head -1)"
  exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"
curl -sL -o gh.tar.gz "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz"
tar xzf gh.tar.gz
mkdir -p "$HOME/bin"
cp "gh_${GH_VERSION}_linux_amd64/bin/gh" "$GH_BIN"
"$GH_BIN" --version
