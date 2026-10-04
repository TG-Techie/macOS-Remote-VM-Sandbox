import Foundation
import SandboxKit

/// `sandbox-mcp host`: the same tools as in the VM (shell, files, git, plus Taildrop), for one folder
/// on this Mac, with no VM. The shell, files and git servers, and everything they run, live under
/// macOS's kernel sandbox (sandbox-exec) with srt's profile plus GPU access (makeProfile): writes
/// only inside the folder, and no reads of /Users or /Volumes beyond it, this binary's folder and the
/// read-only paths given. HOME and TMPDIR point inside the folder, so tools' caches land there too.
/// Two parts run outside it, both fixed code that takes no commands: this process, which listens and
/// relays MCP calls, and the Taildrop server, which only moves received files into inbox/.
enum Host {
    static func run(_ options: Options, selfPath: String) throws -> Never {
        let root = try realPath(try options.require("root"))
        let listenValue = options.value("listen") ?? "127.0.0.1:8765"
        guard case .tcp(let host, let port) = try ListenAddress.parse(listenValue.contains(":") ? listenValue : "\(listenValue):8765") else {
            throw ToolError("--listen takes tailscale or HOST[:PORT]")
        }
        let address = ListenAddress.tcp(host: try resolveListenHost(host), port: port)
        let extraReads = (options.value("allow-read") ?? "")
            .split(separator: ",").map { ($0 as NSString).expandingTildeInPath }.filter { !$0.isEmpty }
        let profile = makeProfile(root: root, selfDir: (selfPath as NSString).deletingLastPathComponent, reads: extraReads)
        if options.flag("print-profile") { print(profile); exit(0) }
        if case .tcp(let h, let p) = address, tcpAnswers(host: h, port: p) {
            throw ToolError("something on this Mac already answers on \(h):\(p) (see: lsof -nP -iTCP:\(p) -sTCP:LISTEN); pick another port with --listen")
        }

        // The tool servers inherit these; Taildrop puts the real HOME back for Tailscale's CLI.
        for dir in [".sandbox-home", ".sandbox-tmp"] {
            try FileManager.default.createDirectory(atPath: "\(root)/\(dir)", withIntermediateDirectories: true)
        }
        setenv("VMSANDBOX_REAL_HOME", NSHomeDirectory(), 1)
        setenv("HOME", "\(root)/.sandbox-home", 1)
        setenv("TMPDIR", "\(root)/.sandbox-tmp", 1)
        guard chdir(root) == 0 else { throw ToolError("couldn't enter \(root)") }

        let sandboxed = ["shell", "files", "git"].map { name in
            AggregatorConfig.Server(name: name, command: "/usr/bin/sandbox-exec",
                                    args: ["-p", profile, selfPath, name, "--root", root] + (name == "shell" ? ["--no-login"] : []))
        }
        let taildrop = AggregatorConfig.Server(name: "taildrop", command: selfPath, args: ["taildrop", "--root", root])
        let instructions = "These tools run on a Mac, confined by macOS's sandbox to one folder: \(root). Paths and shell working directories are relative to it, and commands can't write outside it or read the rest of the user's files. HOME and TMPDIR point inside it. The GPU works through Metal (MLX runs). Files sent to this Mac with Taildrop arrive with taildrop_get into inbox/. Use shell_job_start for anything longer than a few minutes, such as a training run, and sandbox_status if a tool seems missing."
        let config = AggregatorConfig(instructions: instructions, servers: sandboxed + [taildrop])
        let server = MCPServer(name: "vm-sandbox-host", version: version, instructions: instructions, provider: Aggregator(config))
        let fd = try listenSocket(address)
        print("sandboxing tools to \(root)" + (extraReads.isEmpty ? "" : " (reads also: \(extraReads.joined(separator: ", ")))"))
        print("MCP: ready at http://\(hostName(address.host)):\(address.port)/mcp")
        let handler = mcpHTTPHandler(server)
        acceptLoop(fd) { serveHTTP($0, handler: handler) }
    }

    /// srt's baseline (HostProfile.swift) plus only what MLX and these tools need, each marked.
    static func makeProfile(root: String, selfDir: String, reads: [String]) -> String {
        func quoted(_ path: String) -> String { "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let readablePaths = [root, selfDir] + reads
        // Each folder above a readable path, so paths through them resolve (getcwd, realpath);
        // metadata only, so they can't be listed.
        var ancestors: Set<String> = []
        for path in readablePaths {
            var dir = (path as NSString).deletingLastPathComponent
            while dir != "/" && !dir.isEmpty { ancestors.insert(dir); dir = (dir as NSString).deletingLastPathComponent }
        }
        let readable = readablePaths.map { "(subpath \(quoted($0)))" }.joined(separator: " ")
        return """
        (version 1)
        \(srtBaseline)

        ; --- vm-sandbox additions ---
        ; GPU: Metal's device client and its shader compiler, so MLX runs (granted by the operator,
        ; 2026-10-04, for GPU access only).
        (allow iokit-open (iokit-user-client-class "AGXDeviceUserClient"))
        (allow mach-lookup (global-name-prefix "com.apple.MTLCompilerService"))
        ; Network: outbound IP only, so commands reach git remotes and package indexes (srt filters
        ; this through a proxy with a domain allowlist; this doesn't). No listening, and of the Unix
        ; sockets, which reach other programs' local services, only DNS's.
        (allow network-outbound (remote ip "*:*") (remote unix-socket (path-literal "/private/var/run/mDNSResponder")))
        ; Reads: everything, as srt's default, except people's files: /Users and /Volumes are denied
        ; but for the folder, this binary's folder and any --allow-read paths.
        (allow file-read*)
        (deny file-read* (subpath "/Users") (subpath "/Volumes"))
        (allow file-read* \(readable))
        (allow file-read-metadata (literal "/Users") (literal "/Volumes") \(ancestors.sorted().map { "(literal \(quoted($0)))" }.joined(separator: " ")))
        ; Writes: the folder only, plus the null and terminal devices, and xcrun's cache files in the
        ; per-user temporary folder (git and the other developer tools go through xcrun).
        (allow file-write* (subpath \(quoted(root))) (regex #"^/dev/(null|zero|tty.*|fd/.*|dtracehelper)$"))
        \(userTempDir().map { "(allow file-write* (prefix \(quoted($0 + "xcrun_db"))))" } ?? "")
        """
    }

    /// The per-user temporary folder, resolved through /var's symlink, ending in a slash.
    private static func userTempDir() -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0,
              let resolved = realpath(String(cString: buffer), nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved) + "/"
    }

    private static func realPath(_ path: String) throws -> String {
        guard let resolved = realpath((path as NSString).expandingTildeInPath, nil) else {
            throw ToolError("\(path): \(String(cString: strerror(errno)))")
        }
        defer { free(resolved) }
        var isDir: ObjCBool = false
        let result = String(cString: resolved)
        guard FileManager.default.fileExists(atPath: result, isDirectory: &isDir), isDir.boolValue else { throw ToolError("\(path) isn't a folder") }
        return result
    }
}
