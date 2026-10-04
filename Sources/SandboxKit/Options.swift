import Foundation

/// Command-line options: positionals, `--name value` or `--name=value`, and named boolean flags.
/// Only the options a command takes are accepted, so one given to the wrong command (or tool) is
/// refused rather than silently ignored.
public struct Options {
    public private(set) var positional: [String] = []
    private var values: [String: String] = [:]
    private var flags: Set<String> = []

    /// `command` names the command in errors; `elsewhere` maps options this command doesn't take
    /// to where they belong, for the error.
    public init(_ args: [String], command: String, values takes: Set<String>, flags known: Set<String> = [],
                elsewhere: [String: String] = [:]) throws {
        func refuse(_ name: String) -> ToolError {
            let accepted = (takes.union(known)).sorted().map { "--\($0)" }.joined(separator: ", ")
            let hint = elsewhere[name].map { " --\(name) belongs to \($0)." } ?? ""
            return ToolError("\(command) doesn't take --\(name).\(hint) It takes: \(accepted.isEmpty ? "no options" : accepted).")
        }
        var i = 0
        while i < args.count {
            let arg = args[i]
            i += 1
            guard arg.hasPrefix("--") else { positional.append(arg); continue }
            let name = String(arg.dropFirst(2))
            if let eq = name.firstIndex(of: "=") {
                let key = String(name[..<eq])
                guard takes.contains(key) else { throw refuse(key) }
                values[key] = String(name[name.index(after: eq)...])
                continue
            }
            if known.contains(name) { flags.insert(name); continue }
            guard takes.contains(name) else { throw refuse(name) }
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
