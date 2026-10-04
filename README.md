# macOS Remote VM Sandbox

macOS VM with GPU access (MLX works) that exposes shell, file and git MCP tools to an agent,
scoped to one shared project folder. Apple silicon, macOS 26+, Xcode or CLT, ~40 GB disk.

Two ways to run it, each refusing the other's options (`--help` on either lists its own):

- `dist/sandbox-vm run`: in a VM (shell, files, git).
- `dist/sandbox-host DIR`: on this Mac, no VM, sandboxed to one folder, compute only (shell, files).
  [Below](#no-vm-the-tools-on-this-mac-sandboxed-to-one-folder).

## Setup

```sh
scripts/setup-mac.sh --fresh sandbox     # build, download macOS, install, open the VM window
```

In the VM: Setup Assistant with user `admin` / password `admin`, then in its Terminal:

```sh
zsh "/Volumes/My Shared Files/tools/install-guest.sh"
```

Back on the Mac, VM still running:

```sh
scripts/finalize-mac.sh                  # base setup, shut down, snapshot to vms/sandbox-base-<date>
```

## Resume an existing VM (setup failed, window closed)

```sh
scripts/setup-mac.sh --open sandbox
# or directly:
dist/sandbox-vm run --share vms/empty-share --gui
```

Every run mounts the setup scripts (`dist/guest`, read-only) at `/Volumes/My Shared Files/tools`;
`--share` is the project, left empty for the base image. A VM is named by its bundle in `vms/`
(`sandbox` when none is given).

## Run

```sh
dist/sandbox-vm run --share ~/path/to/project --memory-gb 12 [--gui]   # --share remembered after
claude mcp add --transport http vm-sandbox http://127.0.0.1:8765/mcp
```

Serve it to another Mac over Tailscale (this Mac's tailnet address, found at start; no auth of its own,
so your tailnet ACLs are the gate):

```sh
dist/sandbox-vm run --memory-gb 12 --tailnet
claude mcp add --transport http vm-sandbox http://<this-mac's-tailscale-name>:8765/mcp   # on the other Mac
```

SSH to the guest is served beside MCP, over vsock like it (works with no route to the guest). Keys
only: add yours to `~/.ssh/authorized_keys` in the VM first.

```sh
ssh -p 8722 admin@<this-mac's-tailscale-name>                                            # on the other Mac
```

Options: `--cpus N`, `--no-network`, `--mcp-port N` (8765), `--ssh-port N` (8722). Ctrl-C stops (twice forces).

## No VM: the tools on this Mac, sandboxed to one folder

Shell and file tools (plus Taildrop) for one folder, with no VM, under macOS's sandbox, for compute
only: no network, no git, no writes outside the folder, and no reads beyond it except system code,
developer tools and Homebrew's software. The GPU works (MLX, including kernels compiled at run
time). Commands get only `PATH`, `HOME`, `TMPDIR` and `LANG`; `HOME` and `TMPDIR` point inside the
folder. Code and data move with rsync, to a daemon under the same sandbox.

```sh
scripts/build.sh
dist/sandbox-host ~/path/to/project --tailnet                # MCP 8766, rsync 8873 (beside a VM's 8765)
dist/sandbox-host ~/path/to/project --tailnet --expose 8780  # + a server on 127.0.0.1:8780 inside, reachable at :8780
claude mcp add --transport http vm-sandbox http://<this-mac's-tailscale-name>:8766/mcp   # on the other Mac
rsync -a ./src/ rsync://<this-mac's-tailscale-name>:8873/project/src/                  # on the other Mac
dist/sandbox-host ~/path/to/project --print-profile          # the exact sandbox rules
```

- Packages come in by rsync too: a uv cache into `.sandbox-home/.cache/uv`, then `uv sync --offline`.
  Python is Homebrew's, or make another readable with `--allow-read PATH,PATH`.
- `<folder>/autostart.sh`, if present, runs at start under the sandbox (output in
  `.sandbox-tmp/autostart.log`).
- Each start is a new sandbox: jobs from an earlier start keep running, but can't be signalled from
  the new one.
- `monitor_resources` reports the folder's volume (free now, and available once macOS purges local
  snapshots and caches) and memory. Inside, `vm_stat`, `memory_pressure` and sysctlbyname
  (`hw.memsize`, `vm.swapusage`) work; `ps`, `top` and the `sysctl` command don't.
- `taildrop_get` moves files sent with Taildrop into `inbox/`. Add `.sandbox-home/` and
  `.sandbox-tmp/` to the project's `.gitignore`. No port has auth of its own; your tailnet ACLs are
  the gate.
- The profile is [sandbox-runtime](https://github.com/anthropics/sandbox-runtime)'s baseline plus GPU
  access and the folder; see `Sources/sandbox-mcp/Host.swift`.

## Snapshots (VM stopped)

```sh
cp -c -R vms/sandbox.vmbundle vms/sandbox-snap.vmbundle                                   # take
rm -rf vms/sandbox.vmbundle && cp -c -R vms/sandbox-snap.vmbundle vms/sandbox.vmbundle    # restore
```

## Move a VM to another Mac (untested)

```sh
scripts/pack.sh vms/sandbox.vmbundle sandbox.tar.gz     # on this Mac, VM stopped
scripts/setup-mac.sh --from sandbox.tar.gz              # on the other Mac
```

## Troubleshooting

```sh
# Is the guest agent up?
curl -s -X POST http://127.0.0.1:8765/mcp -d '{"jsonrpc":"2.0","id":1,"method":"ping"}'

# No internet in the guest: a Tailscale exit node reroutes the VM's subnet off its bridge
# (tailscale/tailscale#18653, open). Set Exit Node to None, then re-point the route:
route -n get 192.168.64.2 | grep interface      # should say bridgeN
sudo sh -c 'route -n delete 192.168.64.0/24; route -n add -net 192.168.64.0/24 -interface bridge100'

# Disk space vanishing on the host: files the guest opened through the share keep their space after
# the host deletes them, while the guest keeps their vnodes. Don't rotate shared files the guest reads;
# copy them in. install-guest.sh runs a release walk every 30 min; to run one now, in the guest:
find /System/Library /usr /Library /Applications -type f | wc -l                  # in the guest
```

Docs: [setup details](docs/setup.md) · [design](docs/design.md) · [findings](docs/findings.md) · MIT
