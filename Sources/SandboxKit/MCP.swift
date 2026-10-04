import Foundation

/// The protocol versions this server can speak. It uses only initialize, ping, tools/list and
/// tools/call, which haven't changed shape across these.
public let supportedProtocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

public struct ToolError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// Where an MCP server's tools come from: a fixed local set, or the aggregator's children.
public protocol ToolProvider: AnyObject {
    /// Tool descriptors as MCP's tools/list returns them.
    func listTools() throws -> [JSON]
    /// An MCP CallToolResult. A tool that fails returns a result with isError, not a throw;
    /// a throw means the call couldn't be made at all.
    func callTool(name: String, arguments: [String: JSON]) throws -> JSON
}

public enum CallResult {
    public static func text(_ text: String, isError: Bool = false) -> JSON {
        ["content": [["type": "text", "text": .string(text)]], "isError": .bool(isError)]
    }
}

/// A tool's arguments, with the checks every tool would otherwise repeat.
public struct Arguments {
    public let raw: [String: JSON]
    public init(_ raw: [String: JSON]) { self.raw = raw }

    public func string(_ key: String) throws -> String {
        guard let s = raw[key]?.string else { throw ToolError("missing string argument '\(key)'") }
        return s
    }
    public func optionalString(_ key: String) -> String? { raw[key]?.string }
    public func int(_ key: String, default value: Int) -> Int { raw[key]?.double.map { Int($0) } ?? value }
    public func bool(_ key: String, default value: Bool) -> Bool { raw[key]?.bool ?? value }
    public func strings(_ key: String) throws -> [String]? {
        guard let v = raw[key] else { return nil }
        guard let a = v.array, a.allSatisfy({ $0.string != nil }) else {
            throw ToolError("argument '\(key)' must be an array of strings")
        }
        return a.compactMap(\.string)
    }
}

public struct Tool {
    public let name: String
    public let description: String
    public let inputSchema: JSON
    public let run: (Arguments) throws -> String

    public init(name: String, description: String, properties: [String: JSON], required: [String] = [],
                run: @escaping (Arguments) throws -> String) {
        self.name = name
        self.description = description
        self.inputSchema = [
            "type": "object",
            "properties": .object(properties),
            "required": .array(required.map { .string($0) }),
        ]
        self.run = run
    }

    var descriptor: JSON {
        ["name": .string(name), "description": .string(description), "inputSchema": inputSchema]
    }
}

public final class LocalTools: ToolProvider {
    private let tools: [Tool]
    public init(_ tools: [Tool]) { self.tools = tools }

    public func listTools() -> [JSON] { tools.map(\.descriptor) }

    public func callTool(name: String, arguments: [String: JSON]) throws -> JSON {
        guard let tool = tools.first(where: { $0.name == name }) else { throw ToolError("unknown tool '\(name)'") }
        do {
            return CallResult.text(try tool.run(Arguments(arguments)))
        } catch {
            return CallResult.text("\(error)", isError: true)
        }
    }
}

/// The JSON-RPC side of an MCP server, independent of transport.
public final class MCPServer {
    let name: String
    let version: String
    let instructions: String?
    let provider: ToolProvider

    public init(name: String, version: String, instructions: String? = nil, provider: ToolProvider) {
        self.name = name
        self.version = version
        self.instructions = instructions
        self.provider = provider
    }

    /// The response to a request, or nil for a notification or a stray response.
    public func handle(_ message: JSON) -> JSON? {
        guard let method = message["method"]?.string else { return nil }
        let id = message["id"]
        let params = message["params"]?.object ?? [:]

        func reply(_ result: JSON) -> JSON? {
            id.map { ["jsonrpc": "2.0", "id": $0, "result": result] }
        }
        func fail(_ code: Int, _ text: String) -> JSON? {
            id.map { ["jsonrpc": "2.0", "id": $0, "error": ["code": .number(Double(code)), "message": .string(text)]] }
        }

        switch method {
        case "initialize":
            let asked = params["protocolVersion"]?.string ?? ""
            let version = supportedProtocolVersions.contains(asked) ? asked : supportedProtocolVersions[0]
            var result: [String: JSON] = [
                "protocolVersion": .string(version),
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": .string(name), "version": .string(self.version)],
            ]
            if let instructions { result["instructions"] = .string(instructions) }
            return reply(.object(result))
        case "ping":
            return reply([:])
        case "tools/list":
            do { return reply(["tools": .array(try provider.listTools())]) }
            catch { return fail(-32603, "\(error)") }
        case "tools/call":
            guard let tool = params["name"]?.string else { return fail(-32602, "tools/call needs a name") }
            do { return reply(try provider.callTool(name: tool, arguments: params["arguments"]?.object ?? [:])) }
            catch { return fail(-32602, "\(error)") }
        default:
            return fail(-32601, "method not found: \(method)")
        }
    }
}

/// Serves newline-delimited JSON-RPC on stdin and stdout until stdin closes. Requests run
/// concurrently, so one long call doesn't hold up the rest.
public func serveStdio(_ server: MCPServer) -> Never {
    let out = FileHandle.standardOutput
    let writeLock = NSLock()
    let calls = DispatchQueue(label: "mcp.calls", attributes: .concurrent)
    let inFlight = DispatchGroup()

    func send(_ message: JSON) {
        writeLock.lock()
        out.write(message.encoded() + Data("\n".utf8))
        writeLock.unlock()
    }

    while let line = readLine(strippingNewline: true) {
        if line.allSatisfy(\.isWhitespace) { continue }
        guard let message = try? JSON.parse(Data(line.utf8)) else {
            send(["jsonrpc": "2.0", "id": nil, "error": ["code": -32700, "message": "parse error"]])
            continue
        }
        calls.async(group: inFlight) {
            if let response = server.handle(message) { send(response) }
        }
    }
    inFlight.wait()
    exit(0)
}
