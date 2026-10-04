import Foundation

/// Resolves tool paths against a root directory and refuses any that lead outside it, through
/// `..` or through a symlink.
public struct PathJail {
    public let root: URL

    public init(root: String) throws {
        let url = URL(fileURLWithPath: root).standardizedFileURL.resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw ToolError("root \(root) is not a directory")
        }
        self.root = url
    }

    /// The real location of `path` (relative to the root, or absolute), which may not exist yet.
    public func resolve(_ path: String) throws -> URL {
        let given = path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path)
        var existing = given.standardizedFileURL
        var missing: [String] = []
        while !Self.exists(existing.path), existing.path != "/" {
            missing.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath()
        if Self.isSymlink(resolved.path) {
            throw ToolError("\(path) goes through a symlink whose target doesn't exist")
        }
        for component in missing { resolved.appendPathComponent(component) }
        guard contains(resolved) else {
            throw ToolError("\(path) is outside the project folder \(root.path)")
        }
        return resolved
    }

    public func relative(_ url: URL) -> String {
        url.path == root.path ? "." : String(url.path.dropFirst(root.path.count + 1))
    }

    private func contains(_ url: URL) -> Bool {
        url.path == root.path || url.path.hasPrefix(root.path + "/")
    }

    private static func exists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    private static func isSymlink(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
    }
}
