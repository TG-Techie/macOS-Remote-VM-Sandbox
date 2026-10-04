#!/bin/zsh
# The second of the two setup commands. Before it, in the VM's window: finish Setup Assistant
# (user admin, password admin), then in the VM's Terminal run
#
#   zsh "/Volumes/My Shared Files/tools/install-guest.sh"
#
# which starts the guest's MCP agent. Then, on this Mac, with the VM still running:
#
#   scripts/finalize-mac.sh [NAME] [--vms DIR] [--password P]   NAME defaults to sandbox
#
# Everything goes through the agent over vsock, so it needs no SSH and no route to the guest. It runs
# the base setup (passwordless sudo, autologin, no sleep, then the Command Line Tools and Homebrew,
# which need the guest to reach the internet), shuts the guest down and snapshots the VM as
# NAME-base-<date>.vmbundle beside it (an APFS clone: instant, no extra disk until they diverge).
set -euo pipefail
cd "${0:A:h}/.."
name=sandbox vms=$PWD/vms password=admin
while (( $# )); do
  case $1 in
    --vms) vms=${2:A}; shift 2 ;;
    --password) password=$2; shift 2 ;;
    -*) echo "unknown option $1; see the top of $0" >&2; exit 2 ;;
    *) name=$1; shift ;;
  esac
done
bundle=$vms/$name.vmbundle
[[ -f $bundle/config.json ]] || { echo "no VM at $bundle; run scripts/setup-mac.sh --fresh $name first" >&2; exit 1 }
url=http://127.0.0.1:8765/mcp

# Runs a shell command in the guest through the agent and prints its result. Fails if the command did.
guest() {
  local body reply text
  body=$(jq -n --arg c "$1" --argjson t "${2:-120}" \
    '{jsonrpc:"2.0",id:1,method:"tools/call",params:{name:"shell_exec",arguments:{command:$c,timeout_seconds:$t}}}')
  reply=$(curl -sS -m $(( ${2:-120} + 30 )) -X POST "$url" -H 'Content-Type: application/json' -d "$body") || return 1
  text=$(print -r -- "$reply" | jq -r '.result.content[0].text // .error.message')
  print -r -- "$text"
  [[ $(print -r -- "$reply" | jq -r '.result.isError') == false && $text == "exit 0"* ]]
}
step() { print -P "\n%B==> $1%b" }

curl -sS -m 5 -X POST "$url" -d '{"jsonrpc":"2.0","id":1,"method":"ping"}' >/dev/null 2>&1 || {
  echo "Nothing answers at $url. Is the VM running (scripts/setup-mac.sh --fresh $name reopens it), and"
  echo "did you run this in the VM's Terminal?"
  echo '  zsh "/Volumes/My Shared Files/tools/install-guest.sh"'
  exit 1
} >&2

step "base setup in the guest (the Command Line Tools and Homebrew take a while)"
tools="/Volumes/My Shared Files/tools"
if ! guest "printf '%s\\n' '$password' | sudo -S -p '' /bin/zsh '$tools/base-setup.sh'" 3600; then
  echo "Base setup didn't finish (above). If it stopped at the Command Line Tools or Homebrew, the guest"
  echo "can't reach the internet; the snapshot below still has everything before that."
fi
# sshd refuses keys when the home folder is group- or world-writable, which was seen once.
guest 'chmod 750 "$HOME"' >/dev/null

step "shutting the guest down"
guest "printf '%s\\n' '$password' | sudo -S -p '' shutdown -h +0" >/dev/null 2>&1 || true
# sandbox-vm run holds a lock on config.json while the VM runs; -k keeps lockf from deleting it.
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
echo "Boot it: dist/sandbox-vm run $name --share /path/to/project --memory-gb 12"
