# macOS Remote VM Sandbox

A macOS virtual machine that gives an AI agent a Mac's compute, including its GPU through Metal
(MLX works), while limiting what the agent can reach on the host to one project folder. The agent
works through MCP tools for shell commands, file edits and git that run inside the VM, reached
over a private host–VM channel (vsock), not the network.

## Requirements

- An Apple silicon Mac on macOS 26 (macOS 27 also works, and can skip Setup Assistant; untested).
- Xcode or the Command Line Tools, with Swift 5.9 or later (`swift --version`).
- Disk: about 18 GB for the macOS restore image, which you can delete after setup, plus the VM's
  disk, which starts around 20 GB and grows to at most 64 GB.
- Memory: the VM takes what you give it while it runs. 4 GB is the minimum; MLX in the VM can
  use about two thirds of the VM's memory on the GPU.

Everything stays inside this folder: the build in `dist/`, and the restore image, VMs and
snapshots in `vms/`, all git-ignored and excluded from iCloud Drive sync. `--vms DIR` puts the
VMs elsewhere.

## Setup

1. Build, download macOS, install it and open the VM's window:

   ```sh
   scripts/setup-mac.sh --fresh sandbox
   ```

   Install and first setup get half the Mac's memory (4 to 16 GB) so they go faster. If the
   window closes or you stop here, the same command reopens it.

2. In the VM's window, finish Setup Assistant: create the user `admin` with password `admin`,
   and skip the Apple Account, Siri, analytics and FileVault. Then open Terminal in the VM and
   start the guest's agent:

   ```sh
   zsh "/Volumes/My Shared Files/tools/install-guest.sh"
   ```

   Leave the VM running.

3. Back on the Mac, in this folder:

   ```sh
   scripts/finalize-mac.sh
   ```

   This sets up the guest through its agent (passwordless sudo, automatic login, no sleep, the
   Command Line Tools and Homebrew), shuts it down and snapshots it as
   `vms/sandbox-base-<date>.vmbundle`. The Command Line Tools and Homebrew need the VM to reach
   the internet; if it can't, finalize says so and snapshots everything before that.

The `admin`/`admin` account isn't a secret: the boundary is the VM, which only this Mac can
reach.

## Commands

The ones used day to day, from this folder:

```sh
# Open the VM's window (for setup, or to look at it); nothing shared but an empty folder
dist/vmsandbox run vms/sandbox.vmbundle --share vms/empty-share --gui

# Run it headless with a project and 12 GB of memory; MCP at http://127.0.0.1:8765/mcp
dist/vmsandbox run vms/sandbox.vmbundle --share ~/path/to/project --memory-gb 12

# Check the guest's agent answers
curl -s -X POST http://127.0.0.1:8765/mcp -d '{"jsonrpc":"2.0","id":1,"method":"ping"}'

# Snapshot a stopped VM, and go back to it later
cp -c -R vms/sandbox.vmbundle vms/sandbox-snap.vmbundle
rm -rf vms/sandbox.vmbundle && cp -c -R vms/sandbox-snap.vmbundle vms/sandbox.vmbundle

# In the VM's Terminal: start (or restart) the agent, and read its log
zsh "/Volumes/My Shared Files/tools/install-guest.sh"
tail ~/Library/Logs/vm-sandbox-mcp.log

# If the Mac routes the VM's network away from its bridge (see Troubleshooting); the bridge
# is the interface holding 192.168.64.1, often bridge100
route -n get 192.168.64.2 | grep interface   # any guest address; should say bridge…
sudo sh -c 'route -n delete 192.168.64.0/24; route -n add -net 192.168.64.0/24 -interface bridge100'
```

Stop a running VM with Ctrl-C in its terminal (twice to force it).

## Using it

Boot the VM with a project folder shared into it:

```sh
dist/vmsandbox run vms/sandbox.vmbundle --share ~/path/to/project --memory-gb 12
```

| Option | Meaning |
|---|---|
| `--share DIR` | The folder the guest sees, read-write, at `/Volumes/My Shared Files/project`. Required. |
| `--memory-gb N` | Memory for this boot. Default: the value from install. |
| `--cpus N` | CPUs for this boot. Default: the value from install (all of them). |
| `--gui` | Open a window on the VM's screen. Without it, the VM runs headless. |
| `--network nat\|none` | `none` gives the guest no network at all; MCP still works. Default `nat`. |
| `--listen HOST:PORT` | Where MCP is served on the Mac. Default `127.0.0.1:8765`. |

Then point an MCP client at it, for example Claude Code:

```sh
claude mcp add --transport http vm-sandbox http://127.0.0.1:8765/mcp
```

The agent gets `shell_exec` and background jobs (`shell_job_start`, `shell_job_output`, …) for
long runs, `files_read`, `files_write`, `files_edit` and `files_list`, the `git_*` tools, and
`sandbox_status`.

To stop the VM, press Ctrl-C in the terminal running it: that asks the guest to shut down, and a
second Ctrl-C (or 60 seconds) stops it outright. Shutting down from the VM's Apple menu works too.

### Snapshots

A snapshot is an APFS clone of the stopped VM: instant, and it takes no extra disk until the copies
diverge. Take one before anything you might want to undo:

```sh
cp -c -R vms/sandbox.vmbundle vms/sandbox-before-x.vmbundle
```

To go back, delete the VM and clone the snapshot to its name. To start a new project from the
base, clone `vms/sandbox-base-<date>.vmbundle` to a new name and run that.

### Moving a VM to another Mac

`scripts/pack.sh vms/sandbox.vmbundle sandbox.tar.gz` packs a stopped VM into one file, keeping
its disk sparse. On the other Mac, `scripts/setup-mac.sh --from sandbox.tar.gz` builds the tool,
unpacks the VM and offers to delete the archive. Not yet tried between two Macs.

## Troubleshooting

- **`finalize-mac.sh` says nothing answers at 127.0.0.1:8765.** The VM isn't running, or the
  agent wasn't started: run step 2's command in the VM's Terminal. Its log in the guest is
  `~/Library/Logs/vm-sandbox-mcp.log`. `vmsandbox run` prints "guest connection failed" while the
  agent isn't up.
- **The VM has no internet, or the Mac can't reach it at 192.168.64.x.** Check
  `route -n get 192.168.64.2` on the Mac: it should name a `bridge` interface. VPNs and Tailscale
  can route the VM's network (192.168.64.0/24, macOS's default) elsewhere; we've seen a static
  route to the LAN router appear on Macs running Tailscale. MCP over vsock is unaffected, so the
  agent keeps working; only internet access from the guest and SSH need the route.
- **"Failed to lock auxiliary storage" right after install.** The installer was still releasing
  the VM; `run` now waits and retries. If it persists, check nothing else is running the VM.
- **An entitlement error when starting a VM.** Run `scripts/sign.sh`; every build replaces the
  signed binary. `setup-mac.sh` does both.
- **A tool is missing.** Call `sandbox_status`.

## What limits the agent

- The VM is the boundary. Of the host, the guest sees only the project folder and a read-only
  folder holding its own tools, so nothing in the guest can change the server it runs.
- The MCP server listens on vsock, not on a network address, so only the host process that owns
  the VM can reach it. `vmsandbox run` forwards it to `127.0.0.1` by default.
- `files` and `git` refuse paths outside the project folder, including through `..` and
  symlinks. `shell` is not confined within the guest: it can reach the whole VM, and the network
  if the VM has one (`--network none` removes it).
- The server has no authentication of its own. Exposing it beyond the Mac, for example with
  `tailscale serve` in front of the loopback port, is a decision for the machine's owner.

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

- **`vmsandbox`** (host): `create` installs macOS from a restore image into a VM bundle; `run`
  boots it, shares the folders and forwards the MCP port; `exec` runs a script over SSH;
  `ipsw-url` and `ipsw-info` describe restore images. `dist/vmsandbox` with no arguments prints
  its usage.
- **`sandbox-mcp aggregate`** (guest): runs the stdio MCP servers listed in
  `guest/servers.json` and serves their tools as one MCP server, each named `<server>_<tool>`,
  over Streamable HTTP (the stateless, JSON-response subset). Adding another stdio MCP server is
  a config entry.
- **`sandbox-mcp shell | files | git`**: the tool servers.

## Layout

- `Sources/vmsandbox/`: the host CLI.
- `Sources/sandbox-mcp/`: the guest binary.
- `Sources/SandboxKit/`: MCP over stdio and HTTP, the aggregator, path confinement, and process
  spawning. `swift test` runs the path-confinement tests.
- `guest/`: the aggregator's config, the agent's install script, and the base setup script.
- `scripts/`: `setup-mac.sh` and `finalize-mac.sh` (setup), `build.sh` and `sign.sh`, and
  `pack.sh` (moving a VM).
- `docs/`: [step-by-step setup](docs/setup.md), [findings and prior art](docs/findings.md),
  [whether MLX gets the GPU in a guest](docs/feasibility-mlx-in-macos-guest.md), and
  [unattended setup](docs/unattended-setup.md).

## License

MIT; see [LICENSE](LICENSE).
