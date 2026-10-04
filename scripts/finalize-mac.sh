#!/bin/zsh
# The second of the two setup commands. Run it once Setup Assistant is done in the VM's window
# (user admin, password admin) and Remote Login is on:
#
#   scripts/finalize-mac.sh [NAME] [--vms DIR]     NAME defaults to sandbox, DIR to vms/ in this folder
#
# It runs the base setup (passwordless sudo, autologin, no sleep, the Command Line Tools,
# Homebrew) and installs the MCP agent in the guest, then shuts the guest down and snapshots the
# VM as NAME-base-<date>.vmbundle beside it (an APFS clone: instant, no extra disk until the copies
# diverge). Boot the VM again with: dist/vmsandbox run <bundle> --share <project> --memory-gb N
set -euo pipefail
cd "${0:A:h}/.."
name=sandbox vms=$PWD/vms
while (( $# )); do
  case $1 in
    --vms) vms=${2:A}; shift 2 ;;
    -*) echo "unknown option $1; see the top of $0" >&2; exit 2 ;;
    *) name=$1; shift ;;
  esac
done
bundle=$vms/$name.vmbundle
[[ -f $bundle/config.json ]] || { echo "no VM at $bundle; run scripts/setup-mac.sh --fresh $name first" >&2; exit 1 }

step() { print -P "\n%B==> $1%b" }
step "base setup in the guest (Command Line Tools and Homebrew take a while)"
dist/vmsandbox exec "$bundle" --root guest/base-setup.sh
step "the MCP agent"
dist/vmsandbox exec "$bundle" guest/install-guest.sh
# sshd refuses keys when the home folder is group- or world-writable, which was seen once.
print 'chmod 750 "$HOME"' | dist/vmsandbox exec "$bundle" -

step "shutting the guest down"
print 'shutdown -h +0' | dist/vmsandbox exec "$bundle" --root - || true
# vmsandbox run holds a lock on config.json while the VM runs; -k keeps lockf from deleting it.
for i in {1..60}; do
  lockf -k -t 0 "$bundle/config.json" true 2>/dev/null && break
  sleep 2
done
lockf -k -t 0 "$bundle/config.json" true 2>/dev/null \
  || { echo "the VM is still running after 2 minutes; close its window, then rerun to snapshot" >&2; exit 1 }

snapshot=$vms/$name-base-$(date +%F).vmbundle
[[ ! -e $snapshot ]] || snapshot=$vms/$name-base-$(date +%F-%H%M).vmbundle
step "snapshot"
cp -c -R "$bundle" "$snapshot"
echo "Done. Snapshot: $snapshot"
echo "Boot it: dist/vmsandbox run $bundle --share /path/to/project --memory-gb 12"
