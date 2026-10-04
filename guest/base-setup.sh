#!/bin/zsh
# Makes a freshly set-up macOS guest into a plain base image that scripts can customise with no
# one at the screen. Run as root from the host, once Remote Login is on:
#   dist/sandbox-vm exec --as-root dist/guest/base-setup.sh
# It uses only Apple's tools and Homebrew's official installer, and it's safe to run again.
set -euo pipefail
USER_NAME="${VMSANDBOX_USER:-admin}"
USER_PASSWORD="${VMSANDBOX_PASSWORD:-admin}"

step() { print -- "--- $*" }

step "passwordless sudo for $USER_NAME (the VM is the boundary, not the guest account)"
print -- "$USER_NAME ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/vmsandbox
chmod 440 /etc/sudoers.d/vmsandbox
visudo -cf /etc/sudoers.d/vmsandbox

step "automatic login as $USER_NAME"
sysadminctl -autologin set -userName "$USER_NAME" -password "$USER_PASSWORD"

step "no sleep, no screen lock"
pmset -a sleep 0 displaysleep 0 disksleep 0
sudo -u "$USER_NAME" defaults -currentHost write com.apple.screensaver idleTime 0

step "Command Line Tools"
if xcode-select -p >/dev/null 2>&1; then
  print "already installed at $(xcode-select -p)"
else
  # This marker makes softwareupdate list the Command Line Tools without the GUI prompt.
  touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
  label=$(softwareupdate -l 2>&1 | sed -n 's/^\* Label: \(Command Line Tools.*\)$/\1/p' | sort -V | tail -n 1)
  [[ -n "$label" ]] || { print -u2 "softwareupdate lists no Command Line Tools"; exit 1 }
  softwareupdate -i "$label" --verbose
  rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
  xcode-select -p
fi

step "Homebrew"
if [[ -x /opt/homebrew/bin/brew ]]; then
  print "already installed"
else
  sudo -u "$USER_NAME" -H env NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi
grep -q 'brew shellenv' "/Users/$USER_NAME/.zprofile" 2>/dev/null \
  || print 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "/Users/$USER_NAME/.zprofile"
chown "${USER_NAME}:staff" "/Users/$USER_NAME/.zprofile"

step "check"
sudo -u "$USER_NAME" -i /bin/zsh -c 'brew --version | head -n 1; git --version; sudo -n true && print "sudo ok"'
print "autologin user: $(defaults read /Library/Preferences/com.apple.loginwindow autoLoginUser)"
