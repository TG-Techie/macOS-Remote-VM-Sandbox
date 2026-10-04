import Foundation

/// Command-line options: positionals, `--name value` or `--name=value`, and named boolean flags.
public struct Options {
    public private(set) var positional: [String] = []
    private var values: [String: String] = [:]
    private var flags: Set<String> = []

    public init(_ args: [String], flags known: Set<String> = []) throws {
        var i = 0
        while i < args.count {
            let arg = args[i]
            i += 1
            guard arg.hasPrefix("--") else { positional.append(arg); continue }
            let name = String(arg.dropFirst(2))
            if let eq = name.firstIndex(of: "=") {
                values[String(name[..<eq])] = String(name[name.index(after: eq)...])
                continue
            }
            if known.contains(name) { flags.insert(name); continue }
            guard i < args.count else { throw ToolError("--\(name) needs a value") }
            values[name] = args[i]
            i += 1
        }
    }

    public func value(_ name: String) -> String? { values[name] }
    public func flag(_ name: String) -> Bool { flags.contains(name) }

    public func require(_ name: String) throws -> String {
        guard let v = values[name] else { throw ToolError("--\(name) is required") }
        return v
    }

    public func int(_ name: String, default fallback: Int) throws -> Int {
        guard let v = values[name] else { return fallback }
        guard let n = Int(v) else { throw ToolError("--\(name) must be a whole number, got '\(v)'") }
        return n
    }
}
