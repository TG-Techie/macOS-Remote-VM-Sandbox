import Foundation
import SandboxKit

/// Git in the project folder, run directly rather than through a shell, so arguments are never
/// reinterpreted. Commits stage only the paths named.
final class GitServer {
    private let jail: PathJail
    private let git: String

    init(root: String, git: String = "/usr/bin/git") throws {
        jail = try PathJail(root: root)
        self.git = git
    }

    var tools: [Tool] {
        let paths: JSON = ["type": "array", "items": ["type": "string"], "description": "Paths relative to the project folder."]
        return [
            Tool(name: "status", description: "git status --short --branch.", properties: [:]) { _ in
                try self.run(["status", "--short", "--branch"])
            },
            Tool(name: "diff",
                 description: "git diff of the working tree, or of what's staged with staged: true, optionally limited to paths.",
                 properties: ["staged": ["type": "boolean"], "paths": paths]) { args in
                var argv = ["diff"]
                if args.bool("staged", default: false) { argv.append("--staged") }
                return try self.run(argv + ["--"] + self.checked(try args.strings("paths") ?? []))
            },
            Tool(name: "log",
                 description: "git log, one line per commit: hash, date, author, subject. Default 20 commits.",
                 properties: ["max_count": ["type": "integer"], "paths": paths]) { args in
                try self.run(["log", "-n", String(args.int("max_count", default: 20)),
                              "--format=%h %ad %an: %s", "--date=short", "--"] + self.checked(try args.strings("paths") ?? []))
            },
            Tool(name: "commit",
                 description: "Stage exactly the given paths and commit them with message. Nothing else that's staged or modified goes in.",
                 properties: ["message": ["type": "string"], "paths": paths],
                 required: ["message", "paths"]) { args in
                let message = try args.string("message")
                let paths = try self.checked(try args.strings("paths") ?? [])
                guard !paths.isEmpty else { throw ToolError("name at least one path to commit") }
                _ = try self.run(["add", "--"] + paths)
                return try self.run(["commit", "-m", message, "--only", "--"] + paths)
            },
            Tool(name: "run",
                 description: "Any other git command, as an argument list without the leading 'git', run in the project folder.",
                 properties: ["args": ["type": "array", "items": ["type": "string"]]],
                 required: ["args"]) { args in
                try self.run(try args.strings("args") ?? [])
            },
        ]
    }

    /// Paths as git should see them, each checked to be inside the project.
    private func checked(_ paths: [String]) throws -> [String] {
        try paths.map { jail.relative(try jail.resolve($0)) }
    }

    private func run(_ args: [String]) throws -> String {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("git-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: out) }
        let pid = try spawnProcess([git, "-C", jail.root.path] + args, cwd: jail.root.path, stdout: out.path)
        let status = waitForExit(pid, timeout: 300) ?? terminateGroup(pid)
        let output = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
        guard status == 0 else { throw ToolError("git \(args.first ?? ""): \(describeExit(status))\n\(output)") }
        return output.isEmpty ? "(no output)" : output
    }
}
