#!/bin/zsh
# Signs dist/vmsandbox ad hoc with com.apple.security.virtualization, which the Virtualization
# framework requires of any process that starts a VM. Ad-hoc signing is local to this Mac.
set -euo pipefail
cd "${0:A:h}/.."
cp dist/vmsandbox dist/vmsandbox.new
codesign --force --sign - --entitlements vmsandbox.entitlements dist/vmsandbox.new
mv -f dist/vmsandbox.new dist/vmsandbox
codesign --display --entitlements - dist/vmsandbox
