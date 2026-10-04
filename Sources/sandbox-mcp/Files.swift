import Foundation
import SandboxKit

/// Reading and editing files, confined to the project folder.
final class FilesServer {
    private let jail: PathJail

    init(root: String) throws { jail = try PathJail(root: root) }

    var tools: [Tool] {
        let path: JSON = ["type": "string", "description": "Relative to the project folder, or absolute inside it."]
        return [
            Tool(name: "read",
                 description: "Read a text file, with line numbers. Returns up to limit lines (default 2000) from line offset (default 1).",
                 properties: ["path": path, "offset": ["type": "integer"], "limit": ["type": "integer"]],
                 required: ["path"], run: read),
            Tool(name: "write",
                 description: "Write a file, replacing it if it exists and creating parent folders as needed.",
                 properties: ["path": path, "content": ["type": "string"]],
                 required: ["path", "content"], run: write),
            Tool(name: "edit",
                 description: "Replace old_string with new_string in a file. old_string must occur exactly once unless replace_all is true.",
                 properties: ["path": path, "old_string": ["type": "string"], "new_string": ["type": "string"],
                              "replace_all": ["type": "boolean"]],
                 required: ["path", "old_string", "new_string"], run: edit),
            Tool(name: "list",
                 description: "List a folder (default: the project folder). Folders end in /. With recursive, walks subfolders, skipping .git, up to max_entries (default 1000).",
                 properties: ["path": path, "recursive": ["type": "boolean"], "max_entries": ["type": "integer"]],
                 run: list),
        ]
    }

    private func text(at url: URL) throws -> String {
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw ToolError("can't read \(jail.relative(url))")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ToolError("\(jail.relative(url)) isn't UTF-8 text")
        }
        return text
    }

    private func read(_ args: Arguments) throws -> String {
        let url = try jail.resolve(try args.string("path"))
        var lines = try text(at: url).components(separatedBy: "\n")
        if lines.count > 1, lines.last == "" { lines.removeLast() }
        let offset = max(args.int("offset", default: 1), 1)
        let limit = max(args.int("limit", default: 2000), 1)
        guard offset <= lines.count else { return "(\(jail.relative(url)) has \(lines.count) lines)" }
        let end = min(offset - 1 + limit, lines.count)
        let body = (offset - 1..<end).map { "\($0 + 1)\t\(lines[$0])" }.joined(separator: "\n")
        return end < lines.count ? body + "\n(\(lines.count - end) more lines)" : body
    }

    private func write(_ args: Arguments) throws -> String {
        let url = try jail.resolve(try args.string("path"))
        let content = try args.string("content")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeAtomically(Data(content.utf8), to: url)
        return "wrote \(content.utf8.count) bytes to \(jail.relative(url))"
    }

    private func edit(_ args: Arguments) throws -> String {
        let url = try jail.resolve(try args.string("path"))
        let old = try args.string("old_string")
        let new = try args.string("new_string")
        guard !old.isEmpty else { throw ToolError("old_string is empty") }
        let original = try text(at: url)
        let count = original.components(separatedBy: old).count - 1
        guard count > 0 else { throw ToolError("old_string isn't in \(jail.relative(url))") }
        let all = args.bool("replace_all", default: false)
        guard all || count == 1 else {
            throw ToolError("old_string occurs \(count) times in \(jail.relative(url)); make it unique or set replace_all")
        }
        let updated: String
        if all {
            updated = original.replacingOccurrences(of: old, with: new)
        } else {
            updated = original.replacingCharacters(in: original.range(of: old)!, with: new)
        }
        try writeAtomically(Data(updated.utf8), to: url)
        return "replaced \(all ? count : 1) occurrence\(all && count > 1 ? "s" : "") in \(jail.relative(url))"
    }

    private func list(_ args: Arguments) throws -> String {
        let dir = try jail.resolve(args.optionalString("path") ?? ".")
        let max = Swift.max(args.int("max_entries", default: 1000), 1)
        let fm = FileManager.default
        var entries: [String] = []
        var truncated = false

        func isDirectory(_ url: URL) -> Bool {
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        if args.bool("recursive", default: false) {
            guard let walker = fm.enumerator(atPath: dir.path) else {
                throw ToolError("can't list \(jail.relative(dir))")
            }
            while let rel = walker.nextObject() as? String {
                if (rel as NSString).lastPathComponent == ".git" { walker.skipDescendants(); continue }
                if entries.count == max { truncated = true; break }
                entries.append(isDirectory(dir.appendingPathComponent(rel)) ? rel + "/" : rel)
            }
        } else {
            for name in try fm.contentsOfDirectory(atPath: dir.path).sorted() {
                if entries.count == max { truncated = true; break }
                entries.append(isDirectory(dir.appendingPathComponent(name)) ? name + "/" : name)
            }
        }
        return entries.joined(separator: "\n") + (truncated ? "\n(stopped at \(max) entries)" : "")
    }
}
