import Foundation
import SandboxKit

/// `sandbox-mcp host`: shell and file tools, plus Taildrop, for one folder on this Mac, with no VM.
/// The shell and files servers, and everything they run, live under macOS's kernel sandbox
/// (sandbox-exec) with srt's profile plus GPU access (makeProfile): no network, no git, writes only
/// inside the folder, and no reads of /Users or /Volumes beyond it, this binary's folder and the
/// read-only paths given. HOME and TMPDIR point inside the folder. Code and data move in and out
/// with rsync: each connection to the rsync port gets openrsync's daemon, under the same profile,
/// serving the folder as module `project`. Three parts run outside the sandbox, all fixed code that
/// takes no commands: this process, which listens and relays, and the Taildrop server, which only
/// moves received files into inbox/.
enum Host {
    static let rsyncPort: UInt16 = 8873

    static func run(_ options: Options, selfPath: String) throws -> Never {
        let root = try realPath(try options.require("root"))
        let mcp = try tcpAddress(options.value("listen") ?? "127.0.0.1", defaultPort: 8765)
        let rsync = try tcpAddress(options.value("rsync") ?? mcp.host, defaultPort: rsyncPort)
        let extraReads = (options.value("allow-read") ?? "")
            .split(separator: ",").map { ($0 as NSString).expandingTildeInPath }.filter { !$0.isEmpty }
        let profile = makeProfile(root: root, selfDir: (selfPath as NSString).deletingLastPathComponent, reads: extraReads)
        if options.flag("print-profile") { print(profile); exit(0) }
        for address in [mcp, rsync] where tcpAnswers(host: address.host, port: address.port) {
            throw ToolError("something on this Mac already answers on \(address.host):\(address.port) (see: lsof -nP -iTCP:\(address.port) -sTCP:LISTEN); pick another port with --listen or --rsync")
        }

        // The sandboxed servers inherit these; Taildrop puts the real HOME back for Tailscale's CLI.
        for dir in [".sandbox-home", ".sandbox-tmp"] {
            try FileManager.default.createDirectory(atPath: "\(root)/\(dir)", withIntermediateDirectories: true)
        }
        setenv("VMSANDBOX_REAL_HOME", NSHomeDirectory(), 1)
        setenv("VMSANDBOX_REAL_TMPDIR", FileManager.default.temporaryDirectory.path, 1)
        setenv("HOME", "\(root)/.sandbox-home", 1)
        setenv("TMPDIR", "\(root)/.sandbox-tmp", 1)
        guard chdir(root) == 0 else { throw ToolError("couldn't enter \(root)") }

        // The daemon's config lives where the sandbox can read it but not write it.
        guard let temp = userTempDir() else { throw ToolError("couldn't find this user's temporary folder") }
        let rsyncConfig = "\(temp)vm-sandbox-rsyncd-\(getpid()).conf"
        try "use chroot = no\n[project]\n\tpath = \(root)\n\tread only = no\n\tmunge symlinks = yes\n"
            .write(toFile: rsyncConfig, atomically: true, encoding: .utf8)
        let rsyncFD = try listenSocket(.tcp(host: rsync.host, port: rsync.port))
        Thread.detachNewThread {
            acceptLoop(rsyncFD) { client in
                runAttached(["/usr/bin/sandbox-exec", "-p", profile, "/usr/bin/rsync", "--daemon", "--config=\(rsyncConfig)"], socket: client)
            }
        }

        let sandboxed = ["shell", "files"].map { name in
            AggregatorConfig.Server(name: name, command: "/usr/bin/sandbox-exec",
                                    args: ["-p", profile, selfPath, name, "--root", root] + (name == "shell" ? ["--no-login"] : []))
        }
        let taildrop = AggregatorConfig.Server(name: "taildrop", command: selfPath, args: ["taildrop", "--root", root])
        let rsyncURL = "rsync://\(hostName(rsync.host)):\(rsync.port)/project/"
        let instructions = "These tools run on a Mac, confined by macOS's sandbox to one folder: \(root). Paths and shell working directories are relative to it; commands can't write outside it, read the rest of the user's files, use the network, or run git. HOME and TMPDIR point inside it. The GPU works through Metal (MLX runs). Move code and data in and out with rsync from your side: rsync -a ./src/ \(rsyncURL)src/ (and the reverse to fetch). With no network, bring packages in too, such as a uv cache rsynced to .sandbox-home/.cache/uv for uv sync --offline; Python can be one installed outside /Users (Homebrew's), or given with --allow-read. Files sent to this Mac with Taildrop arrive with taildrop_get into inbox/. Use shell_job_start for anything longer than a few minutes, such as a training run, and sandbox_status if a tool seems missing."
        let config = AggregatorConfig(instructions: instructions, servers: sandboxed + [taildrop])
        let server = MCPServer(name: "vm-sandbox-host", version: version, instructions: instructions, provider: Aggregator(config))
        let fd = try listenSocket(.tcp(host: mcp.host, port: mcp.port))
        print("sandboxing tools to \(root)" + (extraReads.isEmpty ? "" : " (reads also: \(extraReads.joined(separator: ", ")))"))
        print("rsync: ready at \(rsyncURL)")
        print("MCP: ready at http://\(hostName(mcp.host)):\(mcp.port)/mcp")
        let handler = mcpHTTPHandler(server)
        acceptLoop(fd) { serveHTTP($0, handler: handler) }
    }

    /// `tailscale`, a name or an IP, with an optional `:PORT`.
    private static func tcpAddress(_ value: String, defaultPort: UInt16) throws -> (host: String, port: UInt16) {
        guard case .tcp(let host, let port) = try ListenAddress.parse(value.contains(":") ? value : "\(value):\(defaultPort)") else {
            throw ToolError("expected tailscale or HOST[:PORT], got '\(value)'")
        }
        return (try resolveListenHost(host), port)
    }

    /// Runs `argv` with `socket` as its stdin and stdout (as inetd would) and this process's stderr,
    /// and waits for it.
    private static func runAttached(_ argv: [String], socket: Int32) {
        defer { close(socket) }
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, socket, 0)
        posix_spawn_file_actions_adddup2(&actions, socket, 1)
        posix_spawn_file_actions_adddup2(&actions, 2, 2)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF))
        var all = sigset_t()
        sigfillset(&all)
        posix_spawnattr_setsigdefault(&attr, &all)
        let cArgs = argv.map { strdup($0) } + [nil]
        let cEnv = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (cArgs + cEnv).forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, argv[0], &actions, &attr, cArgs, cEnv)
        guard rc == 0 else { FileHandle.standardError.write(Data("rsync: couldn't start: \(String(cString: strerror(rc)))\n".utf8)); return }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
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
        ; 2026-10-04, for GPU access).
        (allow iokit-open (iokit-user-client-class "AGXDeviceUserClient"))
        (allow mach-lookup (global-name-prefix "com.apple.MTLCompilerService"))
        ; No network: none is allowed, as in srt with no proxy. rsync's daemon is handed its
        ; connection already open. Git is refused by name, wherever it is, so it only runs in a VM.
        (deny process-exec (regex #"/git(-[^/]*)?$"))
        ; Reads: everything, as srt's default, except people's files: /Users and /Volumes are denied
        ; but for the folder, this binary's folder and any --allow-read paths.
        (allow file-read*)
        (deny file-read* (subpath "/Users") (subpath "/Volumes"))
        (allow file-read* \(readable))
        (allow file-read-metadata (literal "/Users") (literal "/Volumes") \(ancestors.sorted().map { "(literal \(quoted($0)))" }.joined(separator: " ")))
        ; Writes: the folder only, plus the null and terminal devices.
        (allow file-write* (subpath \(quoted(root))) (regex #"^/dev/(null|zero|tty.*|fd/.*|dtracehelper)$"))
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
