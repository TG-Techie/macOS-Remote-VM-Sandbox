#!/bin/zsh
# Run once inside the guest, in Terminal, as the user the guest logs in as:
#   zsh "/Volumes/My Shared Files/tools/install-guest.sh" [PORT]
# Installs LaunchAgents that run at login: the MCP aggregator on vsock PORT (default 8765, which
# must match vmsandbox run --guest-port), and a relay from vsock 8722 to this guest's sshd, which
# vmsandbox run --ssh forwards to. It also turns on Remote Login with keys only: put a key in
# ~/.ssh/authorized_keys to log in (the password is a known default, so it never logs in by SSH).
set -euo pipefail

TOOLS="/Volumes/My Shared Files/tools"
PROJECT="/Volumes/My Shared Files/project"
PORT="${1:-8765}"
LOG="$HOME/Library/Logs/vm-sandbox-mcp.log"

[[ -x "$TOOLS/sandbox-mcp" ]] || { echo "$TOOLS/sandbox-mcp is missing: start the VM with vmsandbox run, from dist/."; exit 1; }
[[ -d "$PROJECT" ]] || { echo "$PROJECT is missing: start the VM with vmsandbox run --share PROJECT_DIR."; exit 1; }

# The aggregator needs nothing else installed. The git tools need the Command Line Tools,
# which base-setup.sh installs, so their absence is only a warning here.
if ! xcode-select -p >/dev/null 2>&1; then
  echo "Note: the Command Line Tools aren't installed yet, so the git tools won't work until they are."
fi

mkdir -p "$HOME/Library/LaunchAgents" "${LOG:h}"
# agent LABEL ARGS...: installs and (re)loads a LaunchAgent running sandbox-mcp ARGS at login.
agent() {
  local label=$1 plist="$HOME/Library/LaunchAgents/$1.plist" arg; shift
  {
    print '<?xml version="1.0" encoding="UTF-8"?>'
    print '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    print "<plist version=\"1.0\"><dict>"
    print "  <key>Label</key><string>$label</string>"
    print "  <key>ProgramArguments</key><array><string>$TOOLS/sandbox-mcp</string>"
    for arg in "$@"; do print "    <string>$arg</string>"; done
    print "  </array>"
    print "  <key>RunAtLoad</key><true/><key>KeepAlive</key><true/><key>ThrottleInterval</key><integer>10</integer>"
    print "  <key>StandardOutPath</key><string>$LOG</string><key>StandardErrorPath</key><string>$LOG</string>"
    print "</dict></plist>"
  } > "$plist"
  launchctl bootout "gui/$(id -u)" "$plist" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$plist" \
    || echo "Couldn't load $label now (an SSH session can't always reach the login session); it starts at the next login."
}
agent local.vm-sandbox.mcp aggregate --config "$TOOLS/servers.json" --listen "vsock:$PORT"
agent local.vm-sandbox.ssh relay --listen vsock:8722 --to 127.0.0.1:22

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
echo "Installed. The aggregator and the SSH relay start at every login; their log is $LOG."
