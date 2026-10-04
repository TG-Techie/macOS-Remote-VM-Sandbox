# Findings and prior art

Notes from building and testing vm-sandbox, kept for anyone extending it.

## Verified, and not yet

Run on an Apple silicon test Mac on macOS 26, with a macOS 26.6.2 guest at 4 GiB unless noted:

- **Verified in the VM:**
  - The guest's MCP aggregator listens on vsock and answers through `vmsandbox run`'s
    forwarder.
  - The shares mount at `/Volumes/My Shared Files/{project,tools}`.
  - `sandbox-mcp` runs from the read-only tools share, under a LaunchAgent that comes back
    after a reboot. It answered 23 s after boot.
  - Ad-hoc signing with the entitlement is enough to install and run a VM.
  - MLX 0.32.3 sees the GPU ("Apple Paravirtual device", 2.86 GB recommended working set, two
    thirds of the guest's RAM). Its fp32 2048² matmul matches the CPU exactly and runs at 96%
    of host speed by wall clock (3,016 vs 3,154 GFLOP/s).
  - `run --memory-gb` sizes a boot; at 9 GiB the guest GPU's working set is 6.0 GiB, two thirds
    again.
- **Found:**
  - Symlinks in a shared folder fail in the guest with ELOOP, so pass trees in as tarballs.
  - Training a 210M-parameter MLX model in an 11 GiB guest ran 4–5 times slower than on the
    host by wall time between steps, with spikes on deep steps, though a single matmul runs at
    96%. Its MLX peak reached 7.80 GiB, past the 7.33 GiB recommended working set, without
    failing. The cause, measured on a host with too little RAM for both: with the VM's 11 GB
    resident, the host
    compressed and decompressed about 2.3 GB/s and swapped about 2 GB each way in 30 s, with
    kernel_task at 150–175% CPU. With the VM down and training on the host, those figures fell
    to roughly a tenth. A host with RAM for both shouldn't see this; unmeasured.
  - Dropping the guest's network mid-pull: 8 s was absorbed by TCP; 90 s made the pull fail
    loudly and the next pull recover, and training in the guest never stopped.
  - The NAT bridge's name changes between boots (bridge101, then bridge100); find it by its
    address on the VM network (192.168.64.1, macOS's default).
  - The guest's home folder was found world-writable (777), cause unknown, and sshd refused
    keys until it was set to 750.
  - A Tailscale exit node cuts the guest off from the internet and from the host: it reroutes
    the VM's subnet (192.168.64.0/24) to the LAN router, or into the tunnel without LAN access,
    over the bridge's own route (tailscale/tailscale#18653, open as of 2026-10-04). Seen on two
    Macs. With the exit node off and the bridge route restored, the guest pings 8.8.8.8; turning
    the exit node back on breaks it again. Binding to the VM's bridge reaches the guest regardless. MCP over vsock is
    unaffected.
  - A file the guest has opened through the share keeps its space on the host after the host
    deletes it, for as long as the guest keeps its vnode: measured on an M3 Max host (two 300 MB
    files; deleting the one the guest never read freed 300 MB, deleting the one it had read freed
    nothing). Purging the guest's caches, stopping its reader and listing the folder didn't release
    it. A guest reading every 2 GB checkpoint as the host replaced it held about 18 GiB. The hold
    is bounded by the guest's vnode table (`kern.maxvnodes`, 64,124 in a 4 GiB guest, full): a
    read-only walk of many files in the guest (`find /System/Library /usr /Library /Applications
    -type f | wc -l`, 366,035 files, 17 s) recycled it, and the host freed 18.5 GiB. So don't rotate
    files on the host that the guest reads through the share; copy them in (rsync over the
    network), or walk files in the guest to release what's held; install-guest.sh installs a walk
    that runs every 30 minutes.
- **Not yet:**
  - Copying a VM to another Mac (`scripts/pack.sh` and `scripts/setup-mac.sh --from`).
  - Sharing an iCloud folder with evicted files.
  - Apple's macOS 27 guest provisioning (`vmsandbox` reaches it dynamically; no macOS 27 host
    has run it).

## Prior art

Surveyed 2026-10-03 from each project's docs and repository; nothing was installed. Licences
are from GitHub's API and the licence files.

| | Tart (Cirrus Labs) | Lume (Cua) | vmsandbox |
|---|---|---|---|
| Licence | FSL-1.1-ALv2 (Fair Source): free on personal computers; organisations over 100 CPU cores pay | MIT | (this repo) |
| Create and install from an IPSW | yes, `tart create --from-ipsw` | yes, `lume create --ipsw` | yes |
| Skip Setup Assistant | not found in the docs I read | yes, `--unattended`: patches the installed disk offline to add a `lume`/`lume` admin, autologin and SSH | no; a person does it once |
| Folder shares, read-only option | yes, `--dir name:path[:ro]` | yes, `--shared-dir path[:ro]` | yes, project read-write and tools read-only |
| Commands in the guest | `tart exec`, through its guest agent | SSH, over the VM's network | MCP tools, over vsock |
| MCP or an agent API | not found in the docs I read | HTTP API on localhost:7777, and an MCP server (stdio) to list, create, run, stop, clone and resize VMs and to run SSH commands in guests | an MCP server inside the guest, scoped to one project |

Others I checked only by their repository descriptions and licences: VirtualBuddy (BSD-2-Clause)
and UTM (Apache-2.0) are GUI apps, and vfkit (Apache-2.0) is a Virtualization.framework CLI.
I didn't look at their features.

What Apple recommends (read 2026-10-03):

- **Skipping Setup Assistant in a VM, new in macOS 27.** `VZMacGuestProvisioningOptions` (with
  `VZMacOSVirtualMachineStartOptions.setGuestProvisioning`) gives the guest a username,
  password, automatic login and SSH. The guest applies them "on the first boot after restore".
  It "requires guest macOS 27 or later", and the host needs the macOS 27 SDK. Apple's sample
  "Running macOS in a virtual machine on Apple silicon" uses it. Sources:
  https://developer.apple.com/documentation/virtualization/vzmacguestprovisioningoptions and
  https://developer.apple.com/documentation/virtualization/running-macos-in-a-virtual-machine-on-apple-silicon
- **The same sample shows DiskImageKit, also new in macOS 27:** several VMs over a shared base
  disk image.
- **For managed fleets, Apple's route is MDM with Automated Device Enrollment** through Apple
  Business or School Manager, which "can skip all Setup Assistant panes"
  (https://support.apple.com/guide/deployment/manage-setup-assistant-depdeff4a547/web). It needs
  that whole infrastructure.
- **On a macOS 26 host such as this Mac,** none of these is available. A person clicks
  through Setup Assistant once, and the base image is reused after that.

What this means for vmsandbox (my reading):

- **Lume covers the host side.** Create, install, run and shares are all there, under MIT,
  and it has the step vmsandbox lacks: unattended first-boot setup. Its installer runs
  `lume serve` at login, though, which is a login item on the machine.
- **What vmsandbox still adds is the agent's boundary.** Lume's MCP server runs on the host
  and can create, delete and SSH into any VM, so an agent holding it holds the VM manager.
  vmsandbox's MCP server runs inside one guest. It reaches only that guest and its project
  folder, needs no guest network, and needs no SSH password.
- **A middle path:** keep vmsandbox and borrow Lume's offline-setup technique, crediting it
  as MIT requires. Its source notes are sobering on fragility. For example, the autologin
  password file was encoded wrongly and still "worked", so nothing looked broken.

Sources (read 2026-10-03):
- Tart:
  - https://github.com/cirruslabs/tart (LICENSE)
  - https://tart.run/licensing/
  - https://tart.run/quick-start/
  - https://github.com/cirruslabs/tart-guest-agent (README: "`tart exec` support (`--run-rpc`)")
- Lume:
  - https://cua.ai/docs/lume
  - https://cua.ai/docs/lume/guides/api-and-mcp
  - https://cua.ai/docs/lume/guides/manage-vms
  - https://github.com/trycua/cua (LICENSE.md: MIT; `libs/lume/src/Unattended/MacOSOfflineSetupPatcher.swift`)
- Others: https://github.com/insidegui/VirtualBuddy, https://github.com/utmapp/UTM, and
  https://github.com/crc-org/vfkit.
