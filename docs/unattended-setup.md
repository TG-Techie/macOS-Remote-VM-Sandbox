# Unattended first-boot setup: what exists and what it would take

Researched 2026-10-03 from source read with `gh api` and
from docs. Nothing was installed or run. Paths below are in github.com/trycua/cua (MIT, Cua AI,
Inc.) unless noted.

## Why it matters

A fresh vmsandbox VM boots to Setup Assistant, and a person has to click through it. Setting
vm-sandbox up on another Mac is the goal, so a step that needs someone at the screen is
the main obstacle to unattended setup.

## How Lume does it

The source is `libs/lume/src/Unattended/` and `libs/lume/src/Utils/DiskImageSession.swift`.

1. **Boot once, headless, then stop.** `UnattendedInstaller.swift` (`materializeFirstBootState`)
   runs the VM with no display for about 10 seconds and stops it, "to materialize first-boot
   state before offline patch".

2. **Attach the disk and mount the Data volume, as a normal user.**
   - `DiskImageSession.swift:56-60`: `hdiutil attach -readwrite -nomount <disk.img>`.
   - `MacOSOfflineSetupPatcher.swift:69-99` finds the APFS volume with role `Data`
     (`diskutil apfs list -plist`) and runs `diskutil mount`.
   - No sudo anywhere. Lume's installer refuses to run as root (`scripts/install.sh:15-17`).

3. **Edit the Data volume offline** (`MacOSOfflineSetupPatcher.swift:113-126`):
   - **User record.** `dslocal/nodes/Default/users/lume.plist` (`:139-172`): uid 501, gid 20,
     `ShadowHashData` = SALTED-SHA512-PBKDF2, 50,000 iterations, 32-byte salt, 128-byte key
     (`:372-386`). The user is also added to the admin groups (`:194`).
   - **Setup done.** It creates `private/var/db/.AppleSetupDone` (`:251`) and writes
     SetupAssistant preferences. These hard-code `LastSeenBuddyBuildVersion` "25F84" and
     `LastSeenCloudProductVersion` "26.5.2" (`:265-266`).
   - **Autologin.** It writes `autoLoginUser` and removes `AccountInfo.FirstLogins` (`:284-285`):
     "A FirstLogins entry causes macOS to launch Setup Assistant on the next graphical login,
     even when .AppleSetupDone is present". It also writes `private/etc/kcpassword`
     (`:304-306`), with a padding subtlety documented at `:425-436`: a wrong encoding still
     logs in, so the bug was invisible.
   - **SSH.** It sets `com.openssh.sshd` to false in launchd's `disabled.plist` (`:310-321`).
   - Existing system plists are rewritten in place, not replaced (`:13`).

4. **Ownership.** The patcher never chowns anything; `grep chown|owner` finds nothing in it.
   Root ownership is fixed later, inside the guest (step 5).
   - My inference, not verified: the host mounts the image with ownership ignored, so files it
     creates carry the "unknown" owner. macOS treats that owner as whoever accesses the file.

5. **Boot again and finish inside the guest, over SSH** (`UnattendedInstaller.swift`):
   - It waits for the guest's IP and an SSH health check as `lume`/`lume` (60 tries, 5 s apart).
   - It then runs `guestFinalizationScript` through `sudo -S` with that password (`:140`). The
     script runs `chown root:wheel /var/db/.AppleSetupDone`, sets the loginwindow and
     SetupAssistant defaults, enables sshd, and runs `diskutil apfs updatePreboot /`, which
     "publish[es] the offline-created administrator to the VM's paired Recovery environment"
     (`:6-7`).

6. **Versions.** It ships presets only for `sequoia.yml` and `tahoe.yml`
   (`libs/lume/src/Resources/unattended-presets/`).

## Porting it into vmsandbox: `vmsandbox setup BUNDLE`

This is my proposal, not built:

1. Boot headless for about 10 seconds, then stop.
2. Attach and mount, as Lume does: plain `hdiutil` and `diskutil`. **The host needs no root or
   sudo.**
3. Write the user record, the group memberships, `.AppleSetupDone`, the SetupAssistant
   preferences, autologin and `kcpassword`. Also write our LaunchAgent into the new user's
   `~/Library/LaunchAgents`, so sandbox-mcp starts at the first autologin.
4. Boot and wait for vsock port 8765 to answer. Then run the root-only steps through our own
   `shell_exec` with `sudo -S`: chown `.AppleSetupDone` and run `updatePreboot`. This uses our
   own channel, so the guest needs no SSH and no network.
5. Install the Command Line Tools without the GUI dialog, which git needs. One known approach is
   to touch `/tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress`, then
   `softwareupdate -l` and `softwareupdate -i <label>`. I haven't verified that.

**Size:** about 500 lines of Swift. Lume's patcher is 559 lines, including the PBKDF2 and
kcpassword code; the boot, wait and finalize logic adds about 100. Allow 1–2 days, including
testing against a VM already installed.

**Risks:**
- These are private, undocumented formats (dslocal, kcpassword, loginwindow state), and Apple
  can change them in any release.
- Lume pins build strings and has presets only for Sequoia and Tahoe.
- A mistake can fail silently. Lume's kcpassword bug is the example.
- Verify each new macOS release with a test boot.

**Credit:** MIT requires keeping Cua's copyright and licence notice with any substantial portion
copied. Put it at the top of the ported file and in a `THIRD_PARTY_NOTICES` file.

**Open decision:** the guest admin's password. Lume uses a fixed `lume`/`lume`. A fixed,
documented local password is low risk here: the guest is reachable only from its own host,
through NAT and vsock. A generated password would become a secret passing through agents. This
is the owner's call.

## Option (c): Lume on the host, sandbox-mcp in the guest

- **Installing it:** `curl … install.sh` puts `lume` in `~/.local/bin` and data in
  `~/.local/share/lume` (`install.sh:26-30`). By default it adds a LaunchAgent that runs
  `lume serve` on port 7777; `--no-background-service` skips that (`:73`, `:101`).
- **Telemetry** is on by default. It records "pseudonymous installation, release, command, and
  API-event metadata" (`libs/lume/README.md`, Telemetry); `lume config telemetry disable` turns
  it off.
- **No vsock.** GitHub code search found no `VZVirtioSocket`, `socketDevices` or `vsock` under
  `libs/lume`. Code search can miss things, so this isn't proven absent. If it's true, sandbox-mcp
  would have to listen on TCP inside the guest and be reached at the guest's NAT IP or through an
  SSH tunnel, which gives up vmsandbox's no-network property.
- **Agent scope:** Lume's MCP server, if handed to an agent, can create, delete and SSH into
  any VM.
- **My view:** it saves the host code, but it costs a login item, telemetry, guest networking
  and a broader agent scope. Not recommended over porting.

## Tart

- Its unattended path is Packer: github.com/cirruslabs/macos-image-templates (MIT, pushed
  2026-09-22). `templates/vanilla-tahoe.pkr.hcl` drives Setup Assistant with timed VNC
  keystrokes, for example `"<wait60s><click 'Select Your Country or Region'>…"`, and creates an
  `admin`/`admin` user.
- That needs Packer and Tart installed, and the keystroke timing is tied to each macOS
  release's UI.
- The licence is FSL-1.1-ALv2: "Usage on personal computers including personal workstations is
  royalty-free" (tart.run/licensing). Personal use is free.

## Recommendation (mine)

Port Lume's offline-patch approach into `vmsandbox setup`, crediting it under MIT, and finish
the root-only steps over our own vsock channel rather than SSH. The host needs no root.

## What I couldn't establish

- Whether ownership-ignored writes really appear root-owned to the guest. That's inferred, and
  Lume's later chown suggests it isn't fully relied on.
- Whether the first headless boot is essential, or a workaround.
- Whether `updatePreboot` matters if Recovery is never used.
- Whether unattended CLT install via `softwareupdate` works on macOS 26.
- Whether Lume truly lacks vsock (only code search was used).

## Decision, 2026-10-03

The owner approved skipping Setup Assistant "provided it's not hacky". By that measure, porting Lume's patcher is hacky, so it was stopped before anything
was written to a guest disk:

- It writes formats Apple doesn't document or support for this: the dslocal user record and
  its shadow hash, kcpassword's XOR encoding, loginwindow and SetupAssistant state, and launchd's
  disabled list.
- Checks after setup would catch a broken result. They wouldn't make the method supported, and
  any macOS release can break it.

Instead, a person clicks through Setup Assistant once. Everything after that uses Apple's own
tools inside the guest (`install-guest.sh`, `softwareupdate`, `launchctl`). The finished VM is
then kept as a base image and copied.
