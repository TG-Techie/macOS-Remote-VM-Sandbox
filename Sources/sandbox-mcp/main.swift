import Foundation
import SandboxKit

// The guest side of vm-sandbox. `aggregate` is the long-running process: it serves the tools of
// the stdio servers named in its config as one MCP server, over HTTP on a vsock or TCP port.
// `shell`, `files` and `git` are those stdio servers. `relay` joins a vsock port to a TCP port in the
// guest, so the host can reach the guest's sshd with no network route. `host` serves the same tools
// on a Mac with no VM, confined to one folder by macOS's sandbox (Host.swift).

let usage = """
usage:
  sandbox-mcp aggregate --config SERVERS.json --listen vsock:PORT|HOST:PORT
  sandbox-mcp shell|files|git --root PROJECT_DIR
  sandbox-mcp relay --listen vsock:PORT --to HOST:PORT
  sandbox-mcp host --root DIR [--listen tailscale|HOST[:PORT]] [--rsync HOST[:PORT]] [--expose PORT[:OUTER]] [--allow-read PATH,PATH] [--print-profile]
  sandbox-mcp taildrop|monitor --root DIR
"""
let version = "0.1"

signal(SIGPIPE, SIG_IGN)
setvbuf(stdout, nil, _IOLBF, 0)
let argv = Array(CommandLine.arguments.dropFirst())

do {
    let options = try Options(Array(argv.dropFirst()), flags: ["no-login", "print-profile"])
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
        try Host.run(options, selfPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
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
    FileHandle.standardError.write(Data("sandbox-mcp: \(error)\n".utf8))
    exit(1)
}
