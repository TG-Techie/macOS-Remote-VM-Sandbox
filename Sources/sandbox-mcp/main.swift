import Foundation
import SandboxKit

// The guest side of vm-sandbox. `aggregate` is the long-running process: it serves the tools of
// the stdio servers named in its config as one MCP server, over HTTP on a vsock or TCP port.
// `shell`, `files` and `git` are those stdio servers. `relay` joins a vsock port to a TCP port in the
// guest, so the host can reach the guest's sshd with no network route. `host` serves the same tools
// on a Mac with no VM, confined to one folder by macOS's sandbox (Host.swift).

let usage = """
Host mode: shell and file tools for one folder on this Mac, with no VM, sandboxed to the folder,
for compute only. (In a VM instead: dist/sandbox-vm.)

usage: dist/sandbox-host DIR [--tailnet] [--expose PORT[:OUTER]] [--mcp-port N] [--rsync-port N]
                        [--allow-read PATH,PATH] [--print-profile]
  DIR                 The folder: tools can read and write only inside it.
  --tailnet           Serve on this Mac's Tailscale address. Default: 127.0.0.1, this Mac only.
  --expose PORT       Let a command listen on 127.0.0.1:PORT inside, reachable at the same port
                      outside (PORT:OUTER for another outside port).
  --mcp-port N        MCP's port. Default 8766 (the VM's is 8765, so both can run).
  --rsync-port N      rsync's port, for moving files in and out. Default 8873.
  --allow-read PATHS  Also let commands read these paths, comma-separated.
  --print-profile     Print the sandbox rules and exit.

Inside the VM (started by install-guest.sh, not by hand): sandbox-mcp aggregate | relay |
shell | files | git | taildrop | monitor.
"""
let version = "0.1"

signal(SIGPIPE, SIG_IGN)
setvbuf(stdout, nil, _IOLBF, 0)
// Invoked as `sandbox-host` (dist/ links that name to this binary), it is host mode itself.
let invokedAsHost = (CommandLine.arguments[0] as NSString).lastPathComponent == "sandbox-host"
let argv = invokedAsHost ? ["host"] + CommandLine.arguments.dropFirst() : Array(CommandLine.arguments.dropFirst())
if argv.contains("--help") || argv.contains("-h") { print(usage); exit(0) }

/// What to use instead of an option host mode doesn't take: VM mode's, and host mode's old spellings.
let hostInstead = Dictionary(uniqueKeysWithValues: ["share", "memory-gb", "cpus", "ssh", "gui", "no-network", "tools", "guest-port", "ssh-port"].map {
    ($0, "--\($0) is VM mode's: dist/sandbox-vm run")
}).merging([
    "root": "give the folder as the argument, dist/sandbox-host DIR",
    "listen": "--tailnet for this Mac's Tailscale address, --mcp-port N for the port (default 8766)",
    "rsync": "--rsync-port N; rsync listens where MCP does",
]) { $1 }
let commandOptions: [String: (values: Set<String>, flags: Set<String>)] = [
    "aggregate": (["config", "listen"], []),
    "relay": (["listen", "to"], []),
    "host": (["mcp-port", "rsync-port", "expose", "allow-read"], ["tailnet", "print-profile"]),
    "monitor": (["root"], []),
    "taildrop": (["root", "home", "tmp"], []),
    "shell": (["root"], ["no-login"]),
    "files": (["root"], []),
    "git": (["root"], []),
]

do {
    let takes = commandOptions[argv.first ?? ""] ?? ([], [])
    let options = try Options(Array(argv.dropFirst()), command: argv.first == "host" ? "sandbox-host" : "sandbox-mcp \(argv.first ?? "")",
                              values: takes.values, flags: takes.flags, elsewhere: argv.first == "host" ? hostInstead : [:])
    switch argv.first {
    case "aggregate":
        let selfPath = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let config = try AggregatorConfig.load(try options.require("config"), selfPath: selfPath)
        let address = try ListenAddress.parse(try options.require("listen"))
        let server = MCPServer(name: "vm-sandbox", version: version, instructions: config.instructions,
                               provider: Aggregator(config))
        let fd = try listenSocket(address)
        FileHandle.standardError.write(Data("sandbox-mcp: serving MCP at \(address)/mcp\n".utf8))
        let handler = mcpHTTPHandler(server)
        acceptLoop(fd) { serveHTTP($0, handler: handler) }
    case "relay":
        let address = try ListenAddress.parse(try options.require("listen"))
        guard case .tcp(let host, let port) = try ListenAddress.parse(try options.require("to")) else {
            throw ToolError("--to takes HOST:PORT")
        }
        let fd = try listenSocket(address)
        FileHandle.standardError.write(Data("sandbox-mcp: relaying \(address) to \(host):\(port)\n".utf8))
        acceptLoop(fd) { client in
            do { relay(client, try tcpConnect(host: host, port: port)) } catch {
                FileHandle.standardError.write(Data("sandbox-mcp: \(error)\n".utf8))
                close(client)
            }
        }
    case "host":
        // The real binary, not the sandbox-host link, since it starts itself for each server.
        let selfPath = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).resolvingSymlinksInPath().path
        try Host.run(options, selfPath: selfPath)
    case "monitor":
        serveStdio(MCPServer(name: "vm-sandbox-monitor", version: version,
                             provider: LocalTools(MonitorServer(root: try options.require("root")).tools)))
    case "taildrop":
        serveStdio(MCPServer(name: "vm-sandbox-taildrop", version: version,
                             provider: LocalTools(try TaildropServer(root: try options.require("root"), home: options.value("home"), temp: options.value("tmp")).tools)))
    case "shell", "files", "git":
        let root = try options.require("root")
        let tools: [Tool]
        switch argv[0] {
        case "shell": tools = try ShellServer(root: root, login: !options.flag("no-login")).tools
        case "files": tools = try FilesServer(root: root).tools
        default: tools = try GitServer(root: root).tools
        }
        serveStdio(MCPServer(name: "vm-sandbox-\(argv[0])", version: version, provider: LocalTools(tools)))
    default:
        print(usage)
        exit(argv.isEmpty ? 0 : 64)
    }
} catch {
    FileHandle.standardError.write(Data("\(invokedAsHost ? "sandbox-host" : "sandbox-mcp"): \(error)\n".utf8))
    exit(1)
}
