import Foundation

/// The aggregator's config: the stdio MCP servers to run and what to tell clients about them.
public struct AggregatorConfig: Decodable {
    public struct Server: Decodable {
        public let name: String
        public let command: String
        public let args: [String]?
    }
    public let instructions: String?
    public let servers: [Server]

    /// Reads the config, replacing `${SELF}` in commands and arguments with `selfPath`.
    public static func load(_ path: String, selfPath: String) throws -> AggregatorConfig {
        let text = try String(contentsOfFile: path, encoding: .utf8).replacingOccurrences(of: "${SELF}", with: selfPath)
        return try JSONDecoder().decode(AggregatorConfig.self, from: Data(text.utf8))
    }
}

/// One stdio MCP server run as a child process, started on first use and restarted after it dies.
final class ChildServer {
    let spec: AggregatorConfig.Server
    private let lock = NSLock()
    private let startLock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var pending: [Int: (JSON) -> Void] = [:]
    private var nextID = 1
    private(set) var tools: [JSON] = []
    private(set) var lastError: String?

    init(_ spec: AggregatorConfig.Server) { self.spec = spec }

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return process?.isRunning == true }

    /// Starts the child and does the MCP handshake if it isn't running.
    func ensureStarted() throws {
        startLock.lock()
        defer { startLock.unlock() }
        if isRunning { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: spec.command)
        p.arguments = spec.args ?? []
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = FileHandle.standardError
        do { try p.run() } catch {
            record("couldn't start: \(error)")
            throw ToolError("\(spec.name): couldn't start \(spec.command): \(error)")
        }
        lock.lock()
        process = p
        input = stdin.fileHandleForWriting
        lock.unlock()
        let reader = stdout.fileHandleForReading
        Thread.detachNewThread { [weak self] in self?.readLoop(reader) }

        do {
            _ = try request("initialize", [
                "protocolVersion": .string(supportedProtocolVersions[1]),
                "capabilities": [:],
                "clientInfo": ["name": "sandbox-mcp-aggregator", "version": "0.1"],
            ], timeout: 30)
            send(["jsonrpc": "2.0", "method": "notifications/initialized"])
            let listed = try request("tools/list", [:], timeout: 30)
            tools = listed["tools"]?.array ?? []
            record(nil)
        } catch {
            record("handshake failed: \(error)")
            p.terminate()
            throw error
        }
    }

    /// Sends a request and waits for its result.
    func request(_ method: String, _ params: JSON, timeout: TimeInterval) throws -> JSON {
        let done = DispatchSemaphore(value: 0)
        var response: JSON?
        lock.lock()
        let id = nextID
        nextID += 1
        pending[id] = { response = $0; done.signal() }
        lock.unlock()
        send(["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params])
        if done.wait(timeout: .now() + timeout) == .timedOut {
            lock.lock(); pending[id] = nil; lock.unlock()
            throw ToolError("\(spec.name): no answer to \(method) within \(Int(timeout))s")
        }
        if let error = response?["error"] {
            throw ToolError("\(spec.name): \(error["message"]?.string ?? "error")")
        }
        return response?["result"] ?? .null
    }

    private func send(_ message: JSON) {
        lock.lock()
        defer { lock.unlock() }
        input?.write(message.encoded() + Data("\n".utf8))
    }

    private func record(_ error: String?) {
        lock.lock(); lastError = error; lock.unlock()
        if let error { FileHandle.standardError.write(Data("aggregator: \(spec.name): \(error)\n".utf8)) }
    }

    private func readLoop(_ handle: FileHandle) {
        var buffer = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer = Data(buffer[buffer.index(after: newline)...])
                guard let message = try? JSON.parse(Data(line)),
                      let id = message["id"]?.double.map({ Int($0) }) else { continue }
                lock.lock()
                let waiter = pending.removeValue(forKey: id)
                lock.unlock()
                waiter?(message)
            }
        }
        // The child exited: fail whatever was waiting on it.
        lock.lock()
        let waiters = pending.values
        pending.removeAll()
        process = nil
        input = nil
        lock.unlock()
        record("exited")
        let error: JSON = ["error": ["code": -32603, "message": .string("\(spec.name) exited")]]
        waiters.forEach { $0(error) }
    }
}

/// Serves the tools of several stdio MCP servers as one, each named `<server>_<tool>`, plus
/// `sandbox_status`, which reports each server's state so a failure is visible to the client.
public final class Aggregator: ToolProvider {
    private let children: [ChildServer]
    private let lock = NSLock()
    private var routes: [String: (ChildServer, String)] = [:]
    /// Long enough for the shell server's longest synchronous command, an hour.
    public var callTimeout: TimeInterval = 3700

    public init(_ config: AggregatorConfig) {
        children = config.servers.map(ChildServer.init)
    }

    public func listTools() -> [JSON] {
        var tools: [JSON] = [statusTool]
        var newRoutes: [String: (ChildServer, String)] = [:]
        for child in children {
            guard (try? child.ensureStarted()) != nil else { continue }
            for tool in child.tools {
                guard case .object(var descriptor) = tool, let name = descriptor["name"]?.string else { continue }
                let exposed = "\(child.spec.name)_\(name)"
                descriptor["name"] = .string(exposed)
                newRoutes[exposed] = (child, name)
                tools.append(.object(descriptor))
            }
        }
        lock.lock(); routes = newRoutes; lock.unlock()
        return tools
    }

    public func callTool(name: String, arguments: [String: JSON]) throws -> JSON {
        if name == "sandbox_status" { return CallResult.text(status()) }
        lock.lock()
        var route = routes[name]
        lock.unlock()
        if route == nil {
            _ = listTools()
            lock.lock(); route = routes[name]; lock.unlock()
        }
        guard let (child, tool) = route else { throw ToolError("unknown tool '\(name)'") }
        do {
            try child.ensureStarted()
            return try child.request("tools/call", ["name": .string(tool), "arguments": .object(arguments)], timeout: callTimeout)
        } catch {
            return CallResult.text("\(error)", isError: true)
        }
    }

    private var statusTool: JSON {
        ["name": "sandbox_status",
         "description": "Reports each tool server inside the VM: running or not, and its last error.",
         "inputSchema": ["type": "object", "properties": [:]]]
    }

    private func status() -> String {
        children.map { child in
            let state = child.isRunning ? "running, \(child.tools.count) tools" : "not running"
            return "\(child.spec.name): \(state)" + (child.lastError.map { "; last error: \($0)" } ?? "")
        }.joined(separator: "\n")
    }
}
