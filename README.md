# vm-sandbox

A macOS VM that gives an agent a Mac's compute, including its GPU through Metal, while limiting
what the agent can reach on the host to one project folder. The agent works through MCP tools
for shell commands, file edits and git that run inside the VM.

Status (2026-10-03): working on an Apple silicon test Mac. A macOS 26.6.2 guest serves its MCP tools over
vsock, and MLX inside it uses the GPU. See "Verified, and not yet" below. Setup steps: [docs/setup.md](docs/setup.md). Whether MLX gets the GPU
in a guest: [docs/feasibility-mlx-in-macos-guest.md](docs/feasibility-mlx-in-macos-guest.md).

## Setup

On an Apple silicon Mac with Xcode or the Command Line Tools, from this folder:

1. `scripts/setup-mac.sh --fresh sandbox` builds the tool, downloads macOS, installs it into a
   new VM and opens the VM's window.
2. In the window: create the user `admin` with password `admin` in Setup Assistant, then turn
   on Remote Login in System Settings › General › Sharing. Leave the window open.
3. `scripts/finalize-mac.sh` sets up the guest (passwordless sudo, automatic login, no sleep,
   the Command Line Tools, Homebrew, and the MCP agent), shuts it down and snapshots it.

Then boot it with your project: `dist/vmsandbox run vms/sandbox.vmbundle --share PROJECT
--memory-gb N`. Details, and moving a VM to another Mac: [docs/setup.md](docs/setup.md).

## How it fits together

```
host Mac                                        macOS guest (Virtualization.framework)
───────────────────────────────────            ──────────────────────────────────────────
agent ── HTTP ──► vmsandbox run                 sandbox-mcp aggregate   (LaunchAgent)
                  127.0.0.1:8765/mcp ─ vsock ──► vsock:8765/mcp
                                                  ├─ sandbox-mcp shell   (stdio MCP)
PROJECT_DIR ── VirtioFS, read-write ─────────►    ├─ sandbox-mcp files   (stdio MCP)
dist/guest  ── VirtioFS, read-only ──────────►    └─ sandbox-mcp git     (stdio MCP)
                                                /Volumes/My Shared Files/{project,tools}
```

- **`vmsandbox`** (host): `ipsw-url` and `ipsw-info` describe restore images; `create` installs macOS from a local restore image into a VM bundle;
  `run` boots it, shares the project folder read-write and the guest tools read-only, and
  forwards a host TCP port to the aggregator's vsock port. `--gui` opens a window, which
  first-boot setup needs.
- **`sandbox-mcp aggregate`** (guest): runs the stdio MCP servers listed in
  `guest/servers.json` and serves their tools as one MCP server, each named
  `<server>_<tool>`, over Streamable HTTP (the stateless, JSON-response subset). Its own
  `sandbox_status` tool reports any server that failed to start. Adding another stdio MCP
  server is a config entry.
- **`sandbox-mcp shell | files | git`**: the tool servers. `shell` runs `zsh -l -c` to
  completion or as background jobs, for training runs that outlast a tool call. `files` reads,
  writes, edits and lists. `git` has status, diff, log, a commit that stages only the paths
  it's given, and `run` for anything else.

## What limits the agent

- The VM is the boundary. Of the host, the guest sees only the two shared folders, and the
  tools folder is read-only, so nothing in the guest can change the server it runs.
- The aggregator listens on vsock, not on a network address, so only the host process that
  owns the VM can reach it. `vmsandbox run` forwards it to `127.0.0.1` by default.
- `files` and `git` refuse paths outside the project folder, including through `..` and
  symlinks. `shell` is not confined within the guest: it can reach the whole VM, and the
  network if the VM has one (`--network none` removes it).
- Exposing the port beyond the host, such as on a tailnet, is a separate step and a
  decision for the machine's owner. The server has no authentication of its own.

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
  - The test Mac's own network setup cut the guest off from the internet and from the host's
    NAT routing; binding to the VM's bridge worked around the latter. MCP over vsock is
    unaffected.
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

## Layout

- `Sources/vmsandbox/`: the host CLI.
- `Sources/sandbox-mcp/`: the guest binary.
- `Sources/SandboxKit/`: MCP over stdio and HTTP, the aggregator, path confinement, and
  process spawning.
- `guest/`: the aggregator's config and the guest install script.
- `scripts/`: `build.sh` assembles `dist/`, and `sign.sh` adds the entitlement. `pack.sh`
  packs a stopped VM into one file, and `setup-mac.sh` sets up a Mac from it, or from scratch.
- `swift test` runs the path-confinement tests.
