import Foundation
import SandboxKit

/// Moves files sent to this Mac with Taildrop out of Tailscale's inbox into the project's `inbox/`.
/// Tailscale's inbox is the one place outside the project these tools take files from.
final class TaildropServer {
    private let inbox: URL

    init(root: String) throws {
        inbox = URL(fileURLWithPath: root).appendingPathComponent("inbox")
    }

    var tools: [Tool] {
        [Tool(name: "get",
              description: "Move every file waiting in this Mac's Taildrop inbox into the project's inbox/ folder (a same-named file gets a number suffix), and list inbox/.",
              properties: [:], run: { _ in try self.get() })]
    }

    private func get() throws -> String {
        let candidates = ["/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]
        guard let cli = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw ToolError("no Tailscale command line found (looked in \(candidates.joined(separator: ", ")))")
        }
        // On a host this runs outside the sandbox, where a symlink planted at inbox/ would send files
        // anywhere. So Tailscale writes to a private staging folder, and files move into inbox/
        // through a handle opened without following links.
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: false)
        let dir = open(inbox.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard dir >= 0 else { throw ToolError("inbox/ isn't a plain folder (a symlink?); refusing to move files into it") }
        defer { close(dir) }
        let realTemp = ProcessInfo.processInfo.environment["VMSANDBOX_REAL_TMPDIR"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
        let staging = realTemp.appendingPathComponent("vm-sandbox-taildrop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["file", "get", "--conflict=rename", "--verbose", staging.path]
        var env = ProcessInfo.processInfo.environment
        if let home = env["VMSANDBOX_REAL_HOME"] { env["HOME"] = home }
        if let temp = env["VMSANDBOX_REAL_TMPDIR"] { env["TMPDIR"] = temp }
        process.environment = env
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        var moved: [String] = []
        for name in (try? FileManager.default.contentsOfDirectory(atPath: staging.path).sorted()) ?? [] {
            var target = name, n = 1
            var info = stat()
            while fstatat(dir, target, &info, AT_SYMLINK_NOFOLLOW) == 0 {
                target = "\((name as NSString).deletingPathExtension) (\(n))" + ((name as NSString).pathExtension.isEmpty ? "" : ".\((name as NSString).pathExtension)")
                n += 1
            }
            guard renameat(AT_FDCWD, staging.appendingPathComponent(name).path, dir, target) == 0 else {
                throw ToolError("couldn't move \(name) into inbox/: \(String(cString: strerror(errno)))")
            }
            moved.append(target)
        }
        let status = process.terminationStatus == 0 ? "ok" : "tailscale exited \(process.terminationStatus)"
        return "\(status)\n\(text.trimmingCharacters(in: .whitespacesAndNewlines))\nmoved into inbox/: \(moved.isEmpty ? "(none)" : moved.joined(separator: ", "))"
    }
}
