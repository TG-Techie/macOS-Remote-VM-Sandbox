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
/// moves received files into inbox/. With --expose PORT[:OUTER], a command may listen on
/// 127.0.0.1:PORT, and this process relays OUTER (default the same) on the MCP address to it.
/// `<root>/autostart.sh`, if present, starts at launch under the sandbox. Each launch is a new
/// sandbox: processes left from an earlier one keep running but can't be signalled from this one.
enum Host {
    static let rsyncPort: UInt16 = 8873

    static func run(_ options: Options, selfPath: String) throws -> Never {
        let root = try realPath(try options.require("root"))
        let mcp = try tcpAddress(options.value("listen") ?? "127.0.0.1", defaultPort: 8765)
        let rsync = try tcpAddress(options.value("rsync") ?? mcp.host, defaultPort: rsyncPort)
        let extraReads = (options.value("allow-read") ?? "")
            .split(separator: ",").map { ($0 as NSString).expandingTildeInPath }.filter { !$0.isEmpty }
        // rsync's daemon config lives where the sandbox can read it but not write it.
        guard let temp = userTempDir() else { throw ToolError("couldn't find this user's temporary folder") }
        let rsyncConfig = "\(temp)vm-sandbox-rsyncd-\(getpid()).conf"
        // --expose PORT[:OUTER]: commands may listen on 127.0.0.1:PORT, relayed from OUTER (default
        // the same port) on the MCP address.
        let exposeParts = try options.value("expose").map { value in
            let ports = value.split(separator: ":").map { UInt16($0) }
            guard (1...2).contains(ports.count), let inner = ports[0], inner > 0, let outer = ports.last ?? nil, outer > 0 else {
                throw ToolError("--expose takes PORT or PORT:OUTER, got '\(value)'")
            }
            return (inner: inner, outer: outer)
        }
        let expose = exposeParts?.inner
        let selfDir = (selfPath as NSString).deletingLastPathComponent
        let profile = makeProfile(root: root, selfDir: selfDir, reads: extraReads, files: [rsyncConfig], expose: expose)
        // openrsync's daemon looks up its own user at start; it is fixed code serving only the folder.
        let rsyncProfile = makeProfile(root: root, selfDir: selfDir, reads: extraReads, files: [rsyncConfig], userLookup: true)
        if options.flag("print-profile") { print(profile); exit(0) }
        let exposed = exposeParts.map { (host: mcp.host, port: $0.outer) }
        for address in [mcp, rsync] + (exposed.map { [$0] } ?? []) where tcpAnswers(host: address.host, port: address.port) {
            throw ToolError("something on this Mac already answers on \(address.host):\(address.port) (see: lsof -nP -iTCP:\(address.port) -sTCP:LISTEN); pick another port with --listen or --rsync")
        }

        // Every server inherits this environment, so it carries nothing of the terminal that started
        // this (tokens, sockets, names): only what tools need. Taildrop, outside the sandbox, gets the
        // real HOME and TMPDIR back as arguments.
        for dir in [".sandbox-home", ".sandbox-tmp"] {
            try FileManager.default.createDirectory(atPath: "\(root)/\(dir)", withIntermediateDirectories: true)
        }
        let realHome = NSHomeDirectory(), realTemp = FileManager.default.temporaryDirectory.path
        let lang = ProcessInfo.processInfo.environment["LANG"] ?? "en_US.UTF-8"
        for key in ProcessInfo.processInfo.environment.keys { unsetenv(key) }
        for (key, value) in ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", "LANG": lang,
                             "HOME": "\(root)/.sandbox-home", "TMPDIR": "\(root)/.sandbox-tmp"] {
            setenv(key, value, 1)
        }
        guard chdir(root) == 0 else { throw ToolError("couldn't enter \(root)") }

        try "use chroot = no\n[project]\n\tpath = \(root)\n\tread only = no\n\tmunge symlinks = yes\n"
            .write(toFile: rsyncConfig, atomically: true, encoding: .utf8)
        let rsyncFD = try listenSocket(.tcp(host: rsync.host, port: rsync.port))
        Thread.detachNewThread {
            acceptLoop(rsyncFD) { client in
                runAttached(["/usr/bin/sandbox-exec", "-p", rsyncProfile, "/usr/bin/rsync", "--daemon", "--config=\(rsyncConfig)"], socket: client)
            }
        }

        if let expose, let exposed {
            let fd = try listenSocket(.tcp(host: exposed.host, port: exposed.port))
            Thread.detachNewThread {
                acceptLoop(fd) { client in
                    guard let inner = try? tcpConnect(host: "127.0.0.1", port: expose) else { close(client); return }
                    relay(client, inner)
                }
            }
            print("exposed: \(hostName(exposed.host)):\(exposed.port) relays to 127.0.0.1:\(expose) inside")
        }

        let sandboxed = ["shell", "files"].map { name in
            AggregatorConfig.Server(name: name, command: "/usr/bin/sandbox-exec",
                                    args: ["-p", profile, selfPath, name, "--root", root] + (name == "shell" ? ["--no-login"] : []))
        }
        let taildrop = AggregatorConfig.Server(name: "taildrop", command: selfPath, args: ["taildrop", "--root", root, "--home", realHome, "--tmp", realTemp])
        let rsyncURL = "rsync://\(hostName(rsync.host)):\(rsync.port)/project/"
        let instructions = "These tools run on a Mac, confined by macOS's sandbox to one folder: \(root). Paths and shell working directories are relative to it; commands can't write outside it, read the rest of this Mac (only system code, developer tools and Homebrew's software), use the network, or run git; this Mac is for compute only. HOME and TMPDIR point inside it.\(expose.map { " A command may listen on 127.0.0.1:\($0) (and no other port); it is reachable from outside at \(hostName(mcp.host)):\(exposed?.port ?? $0)." } ?? "") The GPU works through Metal (MLX runs). Move code and data in and out with rsync from your side: rsync -a ./src/ \(rsyncURL)src/ (and the reverse to fetch). With no network, bring packages in too, such as a uv cache rsynced to .sandbox-home/.cache/uv for uv sync --offline; Python can be one installed outside /Users (Homebrew's), or given with --allow-read. Files sent to this Mac with Taildrop arrive with taildrop_get into inbox/. Use shell_job_start for anything longer than a few minutes, such as a training run, and sandbox_status if a tool seems missing."
        let config = AggregatorConfig(instructions: instructions, servers: sandboxed + [taildrop])
        let server = MCPServer(name: "vm-sandbox-host", version: version, instructions: instructions, provider: Aggregator(config))
        let fd = try listenSocket(.tcp(host: mcp.host, port: mcp.port))
        // <root>/autostart.sh, if there, starts under the sandbox like any job, so work resumes when
        // host mode does; its output goes to .sandbox-tmp/autostart.log (redirected inside the sandbox).
        if FileManager.default.fileExists(atPath: "\(root)/autostart.sh") {
            let pid = try spawnProcess(["/usr/bin/sandbox-exec", "-p", profile, "/bin/zsh", "-c",
                                        "exec /bin/zsh ./autostart.sh >> .sandbox-tmp/autostart.log 2>&1"],
                                       cwd: root, stdout: "/dev/null")
            Thread.detachNewThread { var status: Int32 = 0; while waitpid(pid, &status, 0) < 0 && errno == EINTR {} }
            print("autostart: started autostart.sh (pid \(pid)); output in .sandbox-tmp/autostart.log")
        }
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
    static func makeProfile(root: String, selfDir: String, reads: [String], files: [String] = [], expose: UInt16? = nil,
                            userLookup: Bool = false) -> String {
        func quoted(_ path: String) -> String { "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let readablePaths = [root, selfDir] + reads
        // Each folder above a readable path, so paths through them resolve (getcwd, realpath);
        // metadata only, so they can't be listed.
        var ancestors: Set<String> = []
        for path in readablePaths {
            var dir = (path as NSString).deletingLastPathComponent
            while dir != "/" && !dir.isEmpty { ancestors.insert(dir); dir = (dir as NSString).deletingLastPathComponent }
        }
        // Metal's compiler cache, which MLX needs for kernels it builds at run time: Python's own
        // folder in the per-user cache (other apps' caches sit beside it and stay closed).
        let metalCacheRule = userCacheDir().map { cache in
            let base = cache.replacingOccurrences(of: ".", with: #"\."#)
            return #"""
            (allow file-read-metadata (literal "\#(cache.dropLast())"))
            (allow file-read* file-write* (regex #"^\#(base)(org\.python\.python|[Pp]ython[0-9.]*)(/com\.apple\.metal[^/]*(/.*)?)?$"))
            ; Metal passes that folder to its compiler service (MTLCompilerService) as a read-write
            ; sandbox extension; only for that folder.
            (allow file-issue-extension (require-all (extension-class "com.apple.app-sandbox.read-write")
              (regex #"^\#(base)(org\.python\.python|[Pp]ython[0-9.]*)(/com\.apple\.metal[^/]*(/.*)?)?$")))
            """#
        } ?? ""
        let readable = readablePaths.map { "(subpath \(quoted($0)))" }.joined(separator: " ")
        return """
        (version 1)
        \(srtBaseline)

        ; --- vm-sandbox additions ---
        ; GPU: Metal's device client and its shader compiler, so MLX runs (granted by the operator,
        ; 2026-10-04, for GPU access).
        (allow iokit-open (iokit-user-client-class "AGXDeviceUserClient"))
        (allow mach-lookup (global-name-prefix "com.apple.MTLCompilerService"))
        \(metalCacheRule)
        ; No network: none is allowed, as in srt with no proxy. rsync's daemon is handed its
        ; connection already open. Git is refused by name, wherever it is, so it only runs in a VM.
        (deny process-exec (regex #"/git(-[^/]*)?$"))
        \(expose.map { """
        ; --expose: one loopback port a command may listen on, such as an inference server; this
        ; process relays it outward (granted by the operator, 2026-10-04 06:45, for the inference
        ; engine in host mode).
        (allow network-bind network-inbound (local ip "localhost:\($0)"))
        """ } ?? "")
        ; Compute only (his rule, 2026-10-04: no machine content or system inspection beyond memory
        ; and resource monitoring). Reads are an allowlist: the system's code and data (/System,
        ; /usr, /bin, /sbin), developer tools, Homebrew's software (not its var/ or etc/), the few
        ; files a shell and Python read at start (/etc's zshenv, the time zone), the folder, this
        ; binary's folder and any --allow-read paths. So no /Applications, /Library, /private/var,
        ; /etc's hosts or passwd, or anyone's files.
        (deny file-read*)
        (allow file-read*
          (subpath "/System") (subpath "/usr") (subpath "/bin") (subpath "/sbin") (subpath "/dev")
          (subpath "/opt/homebrew")
          (subpath "/Library/Developer/CommandLineTools") (subpath "/Applications/Xcode.app")
          (literal "/private/var/db/xcode_select_link") (literal "/Library/Preferences/com.apple.dt.Xcode.plist")
          (literal "/") (literal "/etc") (literal "/var") (literal "/tmp") (literal "/private/etc/zshenv")
          (subpath "/private/var/select")
          (literal "/private/etc/localtime") (subpath "/private/var/db/timezone")
          \(readable) \(files.map { "(literal \(quoted($0)))" }.joined(separator: " ")))
        (deny file-read* (subpath "/opt/homebrew/var") (subpath "/opt/homebrew/etc"))
        (allow file-read-metadata (literal "/") (literal "/Users") (literal "/Volumes") (literal "/private") (literal "/private/var") (literal "/private/etc") (literal "/opt") (literal "/Applications") (literal "/Library") (literal "/Library/Developer") \(ancestors.sorted().map { "(literal \(quoted($0)))" }.joined(separator: " ")))
        ; Of srt's baseline, what identifies or inspects the machine and compute doesn't need: boot
        ; arguments and the routing table (the hostname stays: uname, which Python calls, needs it);
        ; the serial number and hardware UUID; and the
        ; services for user and group lookup, installed apps (LaunchServices), the keychain
        ; (securityd), fonts, sound, power control and distributed notifications.
        ; Memory monitoring, which he allows: swap use and memory pressure, beside srt's hw.memsize;
        ; and whether this is a VM, for a machine's name in results.
        (allow sysctl-read (sysctl-name "vm.swapusage") (sysctl-name "kern.memorystatus_vm_pressure_level") (sysctl-name "kern.hv_vmm_present"))
        (deny sysctl-read (sysctl-name "kern.bootargs") (sysctl-name-prefix "net.routetable."))
        (deny iokit-get-properties (iokit-property "IOPlatformSerialNumber") (iokit-property "IOPlatformUUID") (iokit-property "serial-number"))
        (deny mach-lookup
          \(userLookup ? "" : #"(global-name "com.apple.system.opendirectoryd.libinfo") (global-name "com.apple.system.opendirectoryd.membership")"#)
          (global-name "com.apple.lsd.mapdb") (global-name "com.apple.coreservices.launchservicesd")
          (global-name "com.apple.securityd.xpc") (global-name "com.apple.SecurityServer")
          (global-name "com.apple.FontObjectsServer") (global-name "com.apple.fonts")
          (global-name "com.apple.audio.systemsoundserver") (global-name "com.apple.PowerManagement.control")
          (global-name "com.apple.distributed_notifications@Uv3"))
        ; Writes: the folder only, plus the null and terminal devices.
        (allow file-write* (subpath \(quoted(root))) (regex #"^/dev/(null|zero|tty.*|fd/.*|dtracehelper)$"))
        """
    }

    /// The per-user cache folder, resolved through /var's symlink, ending in a slash.
    private static func userCacheDir() -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, buffer.count) > 0,
              let resolved = realpath(String(cString: buffer), nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved) + "/"
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
