# macOS Remote VM Sandbox

macOS VM with GPU access (MLX works) that exposes shell, file and git MCP tools to an agent,
scoped to one shared project folder. Apple silicon, macOS 26+, Xcode or CLT, ~40 GB disk.

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
dist/vmsandbox run vms/sandbox.vmbundle --share vms/empty-share --gui
```

## Run

```sh
dist/vmsandbox run vms/sandbox.vmbundle --share ~/path/to/project --memory-gb 12 [--gui]
claude mcp add --transport http vm-sandbox http://127.0.0.1:8765/mcp
```

Options: `--cpus N`, `--network none`, `--listen HOST:PORT`. Ctrl-C stops (twice forces).

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

# No internet in the guest: this should say bridgeN; if not (VPN/Tailscale), re-point it
route -n get 192.168.64.2 | grep interface
sudo sh -c 'route -n delete 192.168.64.0/24; route -n add -net 192.168.64.0/24 -interface bridge100'
```

Docs: [setup details](docs/setup.md) · [design](docs/design.md) · [findings](docs/findings.md) · MIT
