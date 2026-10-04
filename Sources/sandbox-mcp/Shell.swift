import Foundation
import SandboxKit

/// Commands run by zsh as a login shell in the guest, either to completion or as background jobs
/// for work that outlasts a tool call, such as a training run. The guest is the boundary here:
/// commands can reach the whole VM, but nothing of the host beyond the shared folder.
final class ShellServer {
    private let jail: PathJail
    private let scratch: URL
    private let lock = NSLock()
    private var jobs: [Int: Job] = [:]
    private var nextJob = 1
    private static let outputLimit = 30_000

    final class Job {
        let id: Int
        let command: String
        let cwd: String
        let pid: pid_t
        let log: URL
        let started = Date()
        var ended: (Date, String)?
        init(id: Int, command: String, cwd: String, pid: pid_t, log: URL) {
            self.id = id; self.command = command; self.cwd = cwd; self.pid = pid; self.log = log
        }
    }

    init(root: String) throws {
        jail = try PathJail(root: root)
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("sandbox-mcp-\(getpid())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    var tools: [Tool] {
        let command: JSON = ["type": "string", "description": "Run by zsh -l -c."]
        let cwd: JSON = ["type": "string", "description": "Working directory, relative to the project folder. Default: the project folder."]
        return [
            Tool(name: "exec",
                 description: "Run a shell command to completion and return its exit status, stdout and stderr (each cut to the last \(Self.outputLimit) characters). For anything longer than a few minutes, use job_start.",
                 properties: ["command": command, "cwd": cwd,
                              "timeout_seconds": ["type": "integer", "description": "Kill it after this long. Default 120, at most 3600."]],
                 required: ["command"], run: exec),
            Tool(name: "job_start",
                 description: "Start a shell command in the background, with stdout and stderr going to one log. Returns the job id.",
                 properties: ["command": command, "cwd": cwd], required: ["command"], run: jobStart),
            Tool(name: "job_status",
                 description: "List the background jobs this server has started: id, state, command, and how long they've run.",
                 properties: [:], run: { _ in self.jobStatus() }),
            Tool(name: "job_output",
                 description: "Read a job's log: the last tail_bytes (default 20000), or from byte offset onward.",
                 properties: ["id": ["type": "integer"], "tail_bytes": ["type": "integer"], "offset": ["type": "integer"]],
                 required: ["id"], run: jobOutput),
            Tool(name: "job_stop",
                 description: "Stop a job and everything it started: SIGTERM, then SIGKILL after 3 seconds.",
                 properties: ["id": ["type": "integer"]], required: ["id"], run: jobStop),
        ]
    }

    private func directory(_ args: Arguments) throws -> URL {
        let dir = try jail.resolve(args.optionalString("cwd") ?? ".")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
            throw ToolError("\(jail.relative(dir)) is not a directory")
        }
        return dir
    }

    private func exec(_ args: Arguments) throws -> String {
        let command = try args.string("command")
        let dir = try directory(args)
        let timeout = TimeInterval(min(max(args.int("timeout_seconds", default: 120), 1), 3600))
        let out = scratch.appendingPathComponent(UUID().uuidString + ".out")
        let err = scratch.appendingPathComponent(UUID().uuidString + ".err")
        defer { try? FileManager.default.removeItem(at: out); try? FileManager.default.removeItem(at: err) }

        let pid = try spawnProcess(["/bin/zsh", "-l", "-c", command], cwd: dir.path, stdout: out.path, stderr: err.path)
        var outcome: String
        if let status = waitForExit(pid, timeout: timeout) {
            outcome = describeExit(status)
        } else {
            outcome = "timed out after \(Int(timeout))s; " + describeExit(terminateGroup(pid))
        }
        let stdout = Self.tail(of: out)
        let stderr = Self.tail(of: err)
        if !stdout.isEmpty { outcome += "\n--- stdout ---\n" + stdout }
        if !stderr.isEmpty { outcome += "\n--- stderr ---\n" + stderr }
        return outcome
    }

    private func jobStart(_ args: Arguments) throws -> String {
        let command = try args.string("command")
        let dir = try directory(args)
        lock.lock()
        let id = nextJob
        nextJob += 1
        lock.unlock()
        let log = scratch.appendingPathComponent("job-\(id).log")
        let pid = try spawnProcess(["/bin/zsh", "-l", "-c", command], cwd: dir.path, stdout: log.path)
        let job = Job(id: id, command: command, cwd: jail.relative(dir), pid: pid, log: log)
        lock.lock(); jobs[id] = job; lock.unlock()
        Thread.detachNewThread { [weak self] in
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            self?.lock.lock()
            job.ended = (Date(), describeExit(status))
            self?.lock.unlock()
        }
        return "started job \(id) (pid \(pid)); log at \(log.path)"
    }

    private func job(_ args: Arguments) throws -> Job {
        let id = args.int("id", default: -1)
        lock.lock(); defer { lock.unlock() }
        guard let job = jobs[id] else { throw ToolError("no job \(id)") }
        return job
    }

    private func jobStatus() -> String {
        lock.lock(); defer { lock.unlock() }
        if jobs.isEmpty { return "no jobs" }
        return jobs.keys.sorted().map { id in
            let job = jobs[id]!
            let state: String
            if let (end, how) = job.ended {
                state = "\(how) after \(Int(end.timeIntervalSince(job.started)))s"
            } else {
                state = "running for \(Int(Date().timeIntervalSince(job.started)))s"
            }
            return "\(id): \(state); in \(job.cwd): \(job.command)"
        }.joined(separator: "\n")
    }

    private func jobOutput(_ args: Arguments) throws -> String {
        let job = try self.job(args)
        guard let handle = try? FileHandle(forReadingFrom: job.log) else { return "" }
        defer { try? handle.close() }
        let size = handle.seekToEndOfFile()
        let start: UInt64
        if let offset = args.raw["offset"]?.double {
            start = min(UInt64(max(offset, 0)), size)
        } else {
            start = size - min(size, UInt64(max(args.int("tail_bytes", default: 20_000), 0)))
        }
        handle.seek(toFileOffset: start)
        let data = handle.readDataToEndOfFile()
        return "bytes \(start)–\(start + UInt64(data.count)) of \(size)\n" + String(decoding: data, as: UTF8.self)
    }

    private func jobStop(_ args: Arguments) throws -> String {
        let job = try self.job(args)
        lock.lock()
        let ended = job.ended
        lock.unlock()
        if let (_, how) = ended { return "job \(job.id) had already ended: \(how)" }
        kill(-job.pid, SIGTERM)
        for _ in 0..<60 {
            usleep(50_000)
            lock.lock(); let done = job.ended != nil; lock.unlock()
            if done { return "job \(job.id) stopped" }
        }
        kill(-job.pid, SIGKILL)
        return "job \(job.id) didn't stop on SIGTERM; sent SIGKILL"
    }

    private static func tail(of url: URL) -> String {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return "" }
        let text = String(decoding: data, as: UTF8.self)
        guard text.count > outputLimit else { return text }
        return "[…cut \(text.count - outputLimit) characters…]\n" + text.suffix(outputLimit)
    }
}
