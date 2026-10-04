import Foundation

/// Whether something accepts a TCP connection at host:port right now.
public func tcpAnswers(host: String, port: UInt16) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    guard inet_pton(AF_INET, host == "0.0.0.0" ? "127.0.0.1" : host, &addr.sin_addr) == 1 else { return false }
    return withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    } == 0
}

/// An IPv4 address to bind for `--listen`'s HOST: an address as given; `tailscale` for this Mac's
/// Tailscale address (the interface holding one in 100.64.0.0/10, Tailscale's range); or a host
/// name, such as this Mac's MagicDNS name, resolved to IPv4.
public func resolveListenHost(_ host: String) throws -> String {
    var probe = in_addr()
    if inet_pton(AF_INET, host, &probe) == 1 { return host }
    if host == "tailscale" {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { throw ToolError("couldn't list this Mac's network interfaces") }
        defer { freeifaddrs(list) }
        var next = list
        while let entry = next?.pointee {
            defer { next = entry.ifa_next }
            guard let sa = entry.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
            let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            if addr & 0xFFC0_0000 == 0x6440_0000 { // 100.64.0.0/10
                return "\(addr >> 24).\(addr >> 16 & 0xFF).\(addr >> 8 & 0xFF).\(addr & 0xFF)"
            }
        }
        throw ToolError("--listen tailscale: no Tailscale address on this Mac; is Tailscale connected?")
    }
    var hints = addrinfo()
    hints.ai_family = AF_INET
    hints.ai_socktype = SOCK_STREAM
    var result: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result, let sa = first.pointee.ai_addr else {
        throw ToolError("--listen: couldn't resolve '\(host)' to an IPv4 address")
    }
    defer { freeaddrinfo(result) }
    var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    var sin = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
    inet_ntop(AF_INET, &sin, &buffer, socklen_t(INET_ADDRSTRLEN))
    return String(cString: buffer)
}

/// The name an IPv4 address reverse-resolves to, such as this Mac's MagicDNS name for its Tailscale
/// address, without the trailing dot; the address itself if it has none.
public func hostName(_ address: String) -> String {
    guard address != "127.0.0.1" else { return address }
    var sin = sockaddr_in()
    sin.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    sin.sin_family = sa_family_t(AF_INET)
    guard inet_pton(AF_INET, address, &sin.sin_addr) == 1 else { return address }
    var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    let rc = withUnsafePointer(to: &sin) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size), &name, socklen_t(name.count), nil, 0, NI_NAMEREQD)
        }
    }
    guard rc == 0 else { return address }
    let found = String(cString: name)
    return found.hasSuffix(".") ? String(found.dropLast()) : found
}

extension ListenAddress {
    public var host: String { if case .tcp(let host, _) = self { host } else { "localhost" } }
    public var port: UInt32 {
        switch self {
        case .tcp(_, let port): UInt32(port)
        case .vsock(let port): port
        }
    }
}
