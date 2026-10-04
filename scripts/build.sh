#!/bin/zsh
# Builds release binaries and assembles dist/: vmsandbox for the host, and dist/guest/, which
# vmsandbox run shares read-only into the VM.
# Files are replaced by rename, never deleted and recreated, so a VM running from dist/ keeps a
# working tools share and a running vmsandbox keeps its binary.
set -euo pipefail
cd "${0:A:h}/.."
# Build output and VMs stay out of iCloud Drive and other File Provider syncs when the clone sits
# in a synced folder. The attribute must be on each folder before anything is written into it.
for d in .build dist vms; do
  mkdir -p "$d"
  xattr -w 'com.apple.fileprovider.ignore#P' 1 "$d"
done
swift build -c release
mkdir -p dist/guest
place() { cp "$1" "$2.new" && mv -f "$2.new" "$2" }
place .build/release/vmsandbox dist/vmsandbox
place .build/release/sandbox-mcp dist/sandbox-mcp   # `sandbox-mcp host`: the tools on this Mac, no VM
for f in .build/release/sandbox-mcp guest/servers.json guest/install-guest.sh guest/base-setup.sh; do
  place "$f" "dist/guest/${f:t}"
done
echo "Built dist/. Before it can start a VM, sign it with the virtualization entitlement: scripts/sign.sh"
