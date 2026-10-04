#!/bin/zsh
# Run once inside the guest, in Terminal, as the user the guest logs in as:
#   zsh "/Volumes/My Shared Files/tools/install-guest.sh" [PORT]
# Installs LaunchAgents that run at login: the MCP aggregator on vsock PORT (default 8765, which
# must match sandbox-vm run --guest-port), a relay from vsock 8722 to this guest's sshd, which
# sandbox-vm run forwards SSH to, and a half-hourly walk that releases host disk space (below). It also turns on Remote Login with keys only: put a key in
# ~/.ssh/authorized_keys to log in (the password is a known default, so it never logs in by SSH).
set -euo pipefail

TOOLS="/Volumes/My Shared Files/tools"
PROJECT="/Volumes/My Shared Files/project"
PORT="${1:-8765}"
LOG="$HOME/Library/Logs/vm-sandbox-mcp.log"

[[ -x "$TOOLS/sandbox-mcp" ]] || { echo "$TOOLS/sandbox-mcp is missing: start the VM with dist/sandbox-vm run."; exit 1; }
[[ -d "$PROJECT" ]] || { echo "$PROJECT is missing: start the VM with dist/sandbox-vm run --share PROJECT_DIR."; exit 1; }

# The aggregator needs nothing else installed. The git tools need the Command Line Tools,
# which base-setup.sh installs, so their absence is only a warning here.
if ! xcode-select -p >/dev/null 2>&1; then
  echo "Note: the Command Line Tools aren't installed yet, so the git tools won't work until they are."
fi

mkdir -p "$HOME/Library/LaunchAgents" "${LOG:h}"
# agent LABEL WHEN PROGRAM ARGS...: installs a LaunchAgent running PROGRAM ARGS, WHEN being
# "always" (at login, restarted if it exits) or "every:SECONDS", and (re)loads it only if its
# settings changed or it isn't loaded. So an agent can run this script through the MCP server
# without restarting the server under its own call.
agent() {
  local label=$1 when=$2 plist="$HOME/Library/LaunchAgents/$1.plist" new arg; shift 2
  new=$(mktemp)
  {
    print '<?xml version="1.0" encoding="UTF-8"?>'
    print '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    print "<plist version=\"1.0\"><dict>"
    print "  <key>Label</key><string>$label</string>"
    print "  <key>ProgramArguments</key><array>"
    for arg in "$@"; do print "    <string>$arg</string>"; done
    print "  </array>"
    case $when in
      always)
        print "  <key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>ThrottleInterval</key><integer>10</integer>"
        print "  <key>StandardOutPath</key><string>$LOG</string><key>StandardErrorPath</key><string>$LOG</string>" ;;
      every:*)
        print "  <key>StartInterval</key><integer>${when#every:}</integer><key>LowPriorityIO</key><true/><key>Nice</key><integer>10</integer>"
        print "  <key>StandardOutPath</key><string>/dev/null</string><key>StandardErrorPath</key><string>/dev/null</string>" ;;
      *) echo "agent $label: WHEN must be always or every:SECONDS, not $when" >&2; exit 1 ;;
    esac
    print "</dict></plist>"
  } > "$new"
  if [[ -f $plist ]] && [[ $(plutil -convert json -o - "$plist") == $(plutil -convert json -o - "$new") ]] \
      && launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; then
    rm -f "$new"; echo "$label: unchanged and running"; return
  fi
  mv -f "$new" "$plist"
  launchctl bootout "gui/$(id -u)" "$plist" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$plist" \
    || echo "Couldn't load $label now (an SSH session can't always reach the login session); it starts at the next login."
}
agent local.vm-sandbox.mcp always "$TOOLS/sandbox-mcp" aggregate --config "$TOOLS/servers.json" --listen "vsock:$PORT"
agent local.vm-sandbox.ssh always "$TOOLS/sandbox-mcp" relay --listen vsock:8722 --to 127.0.0.1:22
# A file this guest opened through the share keeps its space on the host after the host deletes it,
# while the guest holds its vnode (docs/findings.md). Reading through many of the guest's own files
# recycles the vnode table and lets the host free it. Read-only, low priority, about 20 s.
agent local.vm-sandbox.release every:1800 /usr/bin/find /System/Library /usr /Library /Applications -type f -name .vm-sandbox-none

# Remote Login, keys only. Needs the passwordless sudo that base-setup.sh sets up.
if sudo -n true 2>/dev/null; then
  print "PasswordAuthentication no\nKbdInteractiveAuthentication no" | sudo -n tee /etc/ssh/sshd_config.d/100-vm-sandbox.conf >/dev/null
  sudo -n launchctl enable system/com.openssh.sshd
  sudo -n launchctl bootstrap system /System/Library/LaunchDaemons/ssh.plist 2>/dev/null \
    || sudo -n launchctl kickstart -k system/com.openssh.sshd
  mkdir -p -m 700 "$HOME/.ssh"; touch "$HOME/.ssh/authorized_keys"; chmod 600 "$HOME/.ssh/authorized_keys"
  echo "Remote Login is on, keys only; authorized keys: $(grep -c . "$HOME/.ssh/authorized_keys")."
else
  echo "Note: no passwordless sudo yet (base-setup.sh), so Remote Login wasn't set to keys only."
fi
sleep 1
tail -n 5 "$LOG" || true
echo "Installed. The aggregator and the SSH relay start at every login, and the release walk runs every"
echo "30 minutes; their log is $LOG."
