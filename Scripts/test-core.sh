#!/usr/bin/env bash
# Runs the AetherCore tests on Linux in seconds (the Core is pure Swift). Installs the Swift toolchain once under ~/swift-tc.
# Usage: Scripts/test-core.sh [swift test arguments, e.g. --filter DownloadSkipTests]
set -euo pipefail
VERSION=6.0.3
DIR="${SWIFT_TC_DIR:-$HOME/swift-tc}"
TC="$DIR/swift-$VERSION-RELEASE-ubuntu24.04"
if [ ! -x "$TC/usr/bin/swift" ]; then
  mkdir -p "$DIR"
  curl -fsSL "https://download.swift.org/swift-$VERSION-release/ubuntu2404/swift-$VERSION-RELEASE/swift-$VERSION-RELEASE-ubuntu24.04.tar.gz" | tar xz -C "$DIR"
fi
export PATH="$TC/usr/bin:$PATH"
cd "$(dirname "$0")/../Packages/AetherCore"
swift test "$@" 2>&1 | grep -E "error:|Executed [0-9]+ tests?|failed \(|Fatal|crashed" | sort -u | tail -25
