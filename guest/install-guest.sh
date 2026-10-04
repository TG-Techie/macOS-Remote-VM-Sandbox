#!/bin/zsh
# Run once inside the guest, in Terminal, as the user the guest logs in as:
#   zsh "/Volumes/My Shared Files/tools/install-guest.sh" [PORT]
# Installs a LaunchAgent that runs the MCP aggregator at login, listening on vsock PORT
# (default 8765, which must match vmsandbox run --guest-port).
set -euo pipefail

TOOLS="/Volumes/My Shared Files/tools"
PROJECT="/Volumes/My Shared Files/project"
PORT="${1:-8765}"
AGENT="$HOME/Library/LaunchAgents/local.vm-sandbox.mcp.plist"
LOG="$HOME/Library/Logs/vm-sandbox-mcp.log"

[[ -x "$TOOLS/sandbox-mcp" ]] || { echo "$TOOLS/sandbox-mcp is missing: start the VM with vmsandbox run, from dist/."; exit 1; }
[[ -d "$PROJECT" ]] || { echo "$PROJECT is missing: start the VM with vmsandbox run --share PROJECT_DIR."; exit 1; }

# The aggregator needs nothing else installed. The git tools need the Command Line Tools,
# which base-setup.sh installs, so their absence is only a warning here.
if ! xcode-select -p >/dev/null 2>&1; then
  echo "Note: the Command Line Tools aren't installed yet, so the git tools won't work until they are."
fi

mkdir -p "${AGENT:h}" "${LOG:h}"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>local.vm-sandbox.mcp</string>
  <key>ProgramArguments</key>
  <array>
    <string>$TOOLS/sandbox-mcp</string>
    <string>aggregate</string>
    <string>--config</string><string>$TOOLS/servers.json</string>
    <string>--listen</string><string>vsock:$PORT</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)" "$AGENT" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$AGENT" \
  || echo "Couldn't load it now (an SSH session can't always reach the login session); it starts at the next login."
sleep 1
tail -n 5 "$LOG" || true
echo "Installed. The aggregator starts at every login; its log is $LOG."
