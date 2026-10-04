import Foundation

/// Where a server listens: TCP on the host, or a virtio socket port inside the guest.
public enum ListenAddress: CustomStringConvertible {
    case tcp(host: String, port: UInt16)
    case vsock(port: UInt32)

    /// `tcp:HOST:PORT`, `HOST:PORT`, or `vsock:PORT`.
    public static func parse(_ text: String) throws -> ListenAddress {
        if text.hasPrefix("vsock:") {
            guard let port = UInt32(text.dropFirst(6)) else { throw ToolError("bad vsock port in '\(text)'") }
            return .vsock(port: port)
        }
        let hostPort = text.hasPrefix("tcp:") ? String(text.dropFirst(4)) : text
        guard let colon = hostPort.lastIndex(of: ":"), let port = UInt16(hostPort[hostPort.index(after: colon)...]) else {
            throw ToolError("expected HOST:PORT, got '\(text)'")
        }
        return .tcp(host: String(hostPort[..<colon]), port: port)
    }

    public var description: String {
        switch self {
        case .tcp(let host, let port): return "tcp:\(host):\(port)"
        case .vsock(let port): return "vsock:\(port)"
        }
    }
}

/// sockaddr_vm from <sys/vsock.h>, which Swift's Darwin module doesn't import. Its natural
/// layout matches the header's packed one: 1+1+2+4+4 bytes.
private struct SockaddrVM {
    var len: UInt8 = UInt8(MemoryLayout<SockaddrVM>.size)
    var family: UInt8 = 40 // AF_VSOCK
    var reserved: UInt16 = 0
    var port: UInt32
    var cid: UInt32 = UInt32.max // VMADDR_CID_ANY
}

/// A listening socket's descriptor.
public func listenSocket(_ address: ListenAddress) throws -> Int32 {
    func check(_ rc: Int32, _ what: String) throws {
        if rc != 0 { throw ToolError("\(what) \(address): \(String(cString: strerror(errno)))") }
    }
    switch address {
    case .tcp(let host, let port):
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ToolError("socket: \(String(cString: strerror(errno)))") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { throw ToolError("'\(host)' is not an IPv4 address") }
        try check(withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }, "bind")
        try check(listen(fd, 64), "listen")
        return fd
    case .vsock(let port):
        let fd = socket(40, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ToolError("vsock socket: \(String(cString: strerror(errno)))") }
        var addr = SockaddrVM(port: port)
        try check(withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<SockaddrVM>.size)) }
        }, "bind")
        try check(listen(fd, 64), "listen")
        return fd
    }
}

/// Accepts connections on `fd` forever, calling `handle` on a thread of its own for each.
public func acceptLoop(_ fd: Int32, handle: @escaping (Int32) -> Void) -> Never {
    while true {
        let client = accept(fd, nil, nil)
        if client < 0 {
            if errno == EINTR || errno == ECONNABORTED { continue }
            fatalError("accept: \(String(cString: strerror(errno)))")
        }
        var yes: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        Thread.detachNewThread { handle(client) }
    }
}

/// Writes all of `data`, or returns false.
@discardableResult
public func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { raw -> Bool in
        guard var p = raw.baseAddress else { return true }
        var left = raw.count
        while left > 0 {
            let n = write(fd, p, left)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return false }
            p += n
            left -= n
        }
        return true
    }
}

public struct HTTPRequest {
    public let method: String
    public let path: String
    public let headers: [String: String] // names lowercased
    public let body: Data
}

public struct HTTPResponse {
    public var status: Int
    public var headers: [String: String] = [:]
    public var body = Data()

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    static func reason(_ status: Int) -> String {
        [200: "OK", 202: "Accepted", 400: "Bad Request", 403: "Forbidden", 404: "Not Found",
         405: "Method Not Allowed", 411: "Length Required", 413: "Payload Too Large"][status] ?? "Status"
    }
}

/// A minimal HTTP/1.1 server loop for one connection: Content-Length bodies, keep-alive.
public func serveHTTP(_ fd: Int32, handler: (HTTPRequest) -> HTTPResponse) {
    defer { close(fd) }
    var timeout = timeval(tv_sec: 600, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 65536)
    let maxBody = 64 << 20

    func fill() -> Bool {
        let n = read(fd, &chunk, chunk.count)
        if n <= 0 { return false }
        buffer.append(contentsOf: chunk[0..<n])
        return true
    }
    func respond(_ r: HTTPResponse, close: Bool) {
        var head = "HTTP/1.1 \(r.status) \(HTTPResponse.reason(r.status))\r\n"
        for (k, v) in r.headers { head += "\(k): \(v)\r\n" }
        head += "Content-Length: \(r.body.count)\r\n"
        if close { head += "Connection: close\r\n" }
        head += "\r\n"
        writeAll(fd, Data(head.utf8) + r.body)
    }

    while true {
        let separator = Data("\r\n\r\n".utf8)
        var headerEnd = buffer.range(of: separator)
        while headerEnd == nil {
            if buffer.count > 1 << 20 || !fill() { return }
            headerEnd = buffer.range(of: separator)
        }
        let head = String(decoding: buffer[buffer.startIndex..<headerEnd!.lowerBound], as: UTF8.self)
        buffer = Data(buffer[headerEnd!.upperBound...])
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count == 3 else { respond(HTTPResponse(status: 400), close: true); return }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let closeAfter = headers["connection"]?.lowercased() == "close" || requestLine[2] == "HTTP/1.0"
        if headers["transfer-encoding"] != nil { respond(HTTPResponse(status: 411), close: true); return }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        if length > maxBody { respond(HTTPResponse(status: 413), close: true); return }
        while buffer.count < length { if !fill() { return } }
        let body = Data(buffer.prefix(length))
        buffer = Data(buffer.dropFirst(length))

        let request = HTTPRequest(method: String(requestLine[0]), path: String(requestLine[1]), headers: headers, body: body)
        respond(handler(request), close: closeAfter)
        if closeAfter { return }
    }
}

/// MCP's Streamable HTTP transport, the stateless subset: each POST carries one JSON-RPC message
/// and a request gets its response as application/json. There's no server-to-client stream, so
/// GET is refused, as the spec allows.
public func mcpHTTPHandler(_ server: MCPServer, path: String = "/mcp") -> (HTTPRequest) -> HTTPResponse {
    return { request in
        let route = request.path.split(separator: "?").first.map(String.init) ?? request.path
        guard route == path else { return HTTPResponse(status: 404) }
        // DNS-rebinding guard from the spec: a browser page may only reach us from localhost.
        if let origin = request.headers["origin"], let host = URL(string: origin)?.host,
           !["localhost", "127.0.0.1", "::1"].contains(host) {
            return HTTPResponse(status: 403)
        }
        guard request.method == "POST" else { return HTTPResponse(status: 405, headers: ["Allow": "POST"]) }
        guard let message = try? JSON.parse(request.body), message.object != nil else {
            let error: JSON = ["jsonrpc": "2.0", "id": nil, "error": ["code": -32700, "message": "expected one JSON-RPC message"]]
            return HTTPResponse(status: 400, headers: ["Content-Type": "application/json"], body: error.encoded())
        }
        guard let response = server.handle(message) else { return HTTPResponse(status: 202) }
        return HTTPResponse(status: 200, headers: ["Content-Type": "application/json"], body: response.encoded())
    }
}
