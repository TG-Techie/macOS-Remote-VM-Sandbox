# Setting up vm-sandbox on a Mac

These steps are for a person at the Mac. Each step changes the
machine in some way, so its owner decides it. Steps 1–4, 6 and 7 have run on a macOS 26 host;
the README lists what has and hasn't been verified. Step 5 needs the guest to reach the
internet.

## You need

- Apple silicon, on macOS 13 or later. 14 or later lets the window resize the guest display.
- Xcode or the Command Line Tools, with Swift 5.9 or later. Check with `swift --version`.
- Disk space:
  - the restore image, about 15–20 GB, which you can delete after install;
  - the VM disk, sparse, which grows as the guest writes (64 GB maximum by default);
  - room for whatever the project's runs produce.

## The short way

From this repo, on the new Mac:

```sh
scripts/setup-mac.sh --from base-generic.tar.gz   # a VM packed on another Mac with scripts/pack.sh
scripts/setup-mac.sh --fresh sandbox               # or: download macOS, install it, open the window
```

Either one builds and signs vmsandbox. `--from` unpacks a ready VM into `vms/`, so nobody
clicks through anything. `--fresh` does steps 2–4 below and opens the window for Setup
Assistant; after it and one command in the VM's Terminal (see the README), `scripts/finalize-mac.sh` does step 5 over vsock and snapshots the VM. The steps below are what the script does.

## 1. Build

```sh
git clone <this repo> vm-sandbox    # or copy the folder; there is no remote yet
cd vm-sandbox
scripts/build.sh                     # produces dist/vmsandbox and dist/guest/
scripts/sign.sh                      # ad-hoc signs vmsandbox with the virtualization entitlement
```

## 2. Get a restore image

```sh
dist/vmsandbox ipsw-url              # prints the URL of the newest image this Mac supports
curl -L -o vms/restore.ipsw '<that URL>'
```

By default everything stays inside this folder: the build in `dist/`, and the restore image,
VMs and snapshots in `vms/`, all git-ignored.

## 3. Create the VM

```sh
dist/vmsandbox create vms/sandbox.vmbundle --ipsw vms/restore.ipsw
```

The defaults are all CPUs, physical memory less 8 GiB, and a 64 GiB disk. Override them with
`--cpus`, `--memory-gb` and `--disk-gb`. The guest's memory is the most MLX can use inside it.
While the VM runs, that memory is taken from the host's unified memory. The install takes a
while and prints its progress.

## 4. First boot

The guest account is `admin`, password `admin`, as in Tart's images. That password isn't a
secret: the boundary is the VM, which only this Mac can reach, so the guest account protects
nothing beyond it.

**With macOS 27 on both the host and the guest,** nobody needs to be at the screen. `create`
records the account. The first `run` hands it to Apple's guest provisioning
(`VZMacGuestProvisioningOptions`), which creates it with automatic login and SSH and skips
Setup Assistant. Its `--user` and `--password` options override the defaults. On a macOS 26
host, a run that's due to provision fails with an error rather than stopping at Setup
Assistant. The provisioning path is untested so far: no macOS 27 Mac has run it yet.

**With macOS 26,** a person does about 5 minutes once:

```sh
dist/vmsandbox run vms/sandbox.vmbundle --share /path/to/project --gui
```

1. In Setup Assistant, create the user `admin` with password `admin`. Skip the Apple Account,
   Siri, analytics and FileVault.
2. In System Settings › General › Sharing, turn on Remote Login.

## 5. Base setup, from the host

```sh
dist/vmsandbox exec vms/sandbox.vmbundle --root dist/guest/base-setup.sh
```

This sets up automatic login, passwordless sudo, no sleep, the Command Line Tools and Homebrew,
using only Apple's tools and Homebrew's installer. It's safe to run again. After this, the VM is
a plain base image. Copy it with `cp -c -R` (an APFS clone: instant, and no extra disk until the
copies diverge) before customising it for a project.

## 6. Project tools

On the project's copy of the VM, run `vmsandbox exec BUNDLE "dist/guest/install-guest.sh"`, or
run it in the guest's Terminal. It installs the LaunchAgent that serves the project's MCP
tools.

## 7. Day to day

```sh
dist/vmsandbox run vms/sandbox.vmbundle --share /path/to/project --memory-gb 4
```

- `--memory-gb` and `--cpus` set this boot's size; without them, the values from `create`
  apply. The GPU's recommended working set inside the guest is two thirds of its memory
  (measured at 4 and 9 GiB), so size the VM at 1.5 times the GPU memory a job needs.
- This runs headless. MCP is at `http://127.0.0.1:8765/mcp`. Point an MCP client at it, for
  example `claude mcp add --transport http vm-sandbox http://127.0.0.1:8765/mcp`.
- Ctrl-C asks the guest to shut down. A second Ctrl-C, or 60 seconds without the guest
  shutting down, stops the VM outright.
- `--network none` gives the guest no network at all. MCP still works, because it goes over
  vsock.

## Reaching it from another machine

`--listen` takes another address, but the server has no authentication. Anyone who can reach
the port can run commands in the VM. Putting it on the tailnet, for example with
`tailscale serve` in front of the loopback port, is the owner's decision. Make it after
deciding who on the tailnet should reach it.

## If something's wrong

- **The MCP client can't connect:** `vmsandbox run` prints "nothing answered on guest vsock
  port" when the aggregator isn't up. In the guest, check
  `~/Library/Logs/vm-sandbox-mcp.log` and
  `launchctl print gui/$(id -u)/local.vm-sandbox.mcp`.
- **A tool is missing:** call `sandbox_status`.
- **The VM won't start, with an entitlement error:** rerun `scripts/sign.sh`. Every
  `scripts/build.sh` replaces the signed binary.
