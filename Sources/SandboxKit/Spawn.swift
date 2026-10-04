import Foundation

/// A folder for a tool's temporary files: $TMPDIR when set (a host sandbox points it inside the
/// project), else Foundation's per-user temporary folder.
public func temporaryFolder() -> URL {
    ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
}

/// Writes `data` to `url` atomically: a temporary file beside it, then a rename. Foundation's
/// .atomic stages in a system folder, which a host sandbox doesn't let it write.
public func writeAtomically(_ data: Data, to url: URL) throws {
    let staging = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
    try data.write(to: staging)
    guard rename(staging.path, url.path) == 0 else {
        let message = String(cString: strerror(errno))
        try? FileManager.default.removeItem(at: staging)
        throw ToolError("couldn't write \(url.path): \(message)")
    }
}

/// Starts `argv` in a process group of its own, so the whole tree can be signalled together,
/// with stdin from /dev/null and output to files. No other descriptor is inherited.
public func spawnProcess(_ argv: [String], cwd: String?, stdout: String, stderr: String? = nil) throws -> pid_t {
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 1, stdout, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    if let stderr {
        posix_spawn_file_actions_addopen(&actions, 2, stderr, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    } else {
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
    }
    if let cwd { posix_spawn_file_actions_addchdir_np(&actions, cwd) }

    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    // Signal dispositions and masks are inherited through exec; a child that inherited an ignored
    // SIGTERM couldn't be stopped gracefully. Start it with the defaults.
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
        | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
    posix_spawnattr_setpgroup(&attr, 0)
    var all = sigset_t(), none = sigset_t()
    sigfillset(&all)
    sigemptyset(&none)
    posix_spawnattr_setsigdefault(&attr, &all)
    posix_spawnattr_setsigmask(&attr, &none)

    let cArgs = argv.map { strdup($0) } + [nil]
    let cEnv = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer { (cArgs + cEnv).forEach { free($0) } }
    var pid: pid_t = 0
    let rc = posix_spawn(&pid, argv[0], &actions, &attr, cArgs, cEnv)
    guard rc == 0 else { throw ToolError("couldn't start \(argv[0]): \(String(cString: strerror(rc)))") }
    return pid
}

/// How a process ended, from its wait status.
public func describeExit(_ status: Int32) -> String {
    let signal = status & 0x7f
    return signal == 0 ? "exit \((status >> 8) & 0xff)" : "killed by signal \(signal)"
}

/// Waits for `pid` up to `timeout` seconds. Returns its wait status, or nil if it's still running.
public func waitForExit(_ pid: pid_t, timeout: TimeInterval) -> Int32? {
    let deadline = Date().addingTimeInterval(timeout)
    var status: Int32 = 0
    repeat {
        let r = waitpid(pid, &status, WNOHANG)
        if r == pid { return status }
        if r < 0 { return status }
        usleep(50_000)
    } while Date() < deadline
    return nil
}

/// SIGTERM to the process group, then SIGKILL if it hasn't gone after `grace` seconds. Reaps it.
public func terminateGroup(_ pid: pid_t, grace: TimeInterval = 3) -> Int32 {
    kill(-pid, SIGTERM)
    if let status = waitForExit(pid, timeout: grace) { return status }
    kill(-pid, SIGKILL)
    var status: Int32 = 0
    waitpid(pid, &status, 0)
    return status
}
