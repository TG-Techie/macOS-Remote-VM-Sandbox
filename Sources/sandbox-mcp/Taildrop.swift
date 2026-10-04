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
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        // This runs outside the host sandbox, so inbox/ must be a real folder in the project: a
        // symlink planted by a sandboxed command would send files elsewhere.
        var info = stat()
        guard lstat(inbox.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw ToolError("inbox/ isn't a plain folder (a symlink?); refusing to move files into it")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["file", "get", "--conflict=rename", "--verbose", inbox.path]
        var env = ProcessInfo.processInfo.environment
        if let home = env["VMSANDBOX_REAL_HOME"] { env["HOME"] = home }
        process.environment = env
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let listing = (try? FileManager.default.contentsOfDirectory(atPath: inbox.path).sorted()) ?? []
        let status = process.terminationStatus == 0 ? "ok" : "tailscale exited \(process.terminationStatus)"
        return "\(status)\n\(text.trimmingCharacters(in: .whitespacesAndNewlines))\ninbox/: \(listing.isEmpty ? "(empty)" : listing.joined(separator: ", "))"
    }
}
