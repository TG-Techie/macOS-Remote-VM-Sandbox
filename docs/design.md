# Design

## What limits the agent

- The VM is the boundary. Of the host, the guest sees only the project folder and a read-only
  folder holding its own tools, so nothing in the guest can change the server it runs.
- The MCP server listens on vsock, not on a network address, so only the host process that owns
  the VM can reach it. `sandbox-vm run` forwards it to `127.0.0.1` by default (`--tailnet` for the Tailscale address).
- `files` and `git` refuse paths outside the project folder, including through `..` and
  symlinks. `shell` is not confined within the guest: it can reach the whole VM, and the network
  if the VM has one (`--no-network` removes it).
- The server has no authentication of its own. Exposing it beyond the Mac (`--tailnet`) is a
  decision for the machine's owner.

## How it fits together

```
host Mac                                        macOS guest (Virtualization.framework)
───────────────────────────────────            ──────────────────────────────────────────
agent ── HTTP ──► sandbox-vm run                sandbox-mcp aggregate   (LaunchAgent)
                  127.0.0.1:8765/mcp ─ vsock ──► vsock:8765/mcp
                                                  ├─ sandbox-mcp shell   (stdio MCP)
PROJECT_DIR ── VirtioFS, read-write ─────────►    ├─ sandbox-mcp files   (stdio MCP)
dist/guest  ── VirtioFS, read-only ──────────►    └─ sandbox-mcp git     (stdio MCP)
                                                /Volumes/My Shared Files/{project,tools}
```

- **`sandbox-vm`** (host; the binary is `vmsandbox`): `create` installs macOS into a VM bundle;
  `run` boots it, shares the folders and forwards the MCP and SSH ports; `exec` runs a script over
  SSH; `ipsw-url` and `ipsw-info` describe restore images. `--help` prints its usage.
- **`sandbox-host`** (host, no VM; the binary is `sandbox-mcp host`): the shell and file tools on
  the Mac itself, under macOS's sandbox (`Sources/sandbox-mcp/Host.swift`).
- **`sandbox-mcp aggregate`** (guest): runs the stdio MCP servers listed in
  `guest/servers.json` and serves their tools as one MCP server, each named `<server>_<tool>`,
  over Streamable HTTP (the stateless, JSON-response subset). Adding another stdio MCP server is
  a config entry.
- **`sandbox-mcp shell | files | git`**: the tool servers.
