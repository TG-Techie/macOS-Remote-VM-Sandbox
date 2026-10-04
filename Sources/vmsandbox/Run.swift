import AppKit
import Foundation
import SandboxKit
import Virtualization

/// `vmsandbox run`: boots a VM with the project folder shared into it, and forwards a TCP port on
/// the host to the aggregator's vsock port in the guest.
enum Run {
    private static var vm: VZVirtualMachine?
    private static var forwarder: Forwarder?
    private static var sshForwarder: Forwarder?
    private static var delegate: StopDelegate?
    private static var window: NSWindow?
    private static var signalSources: [DispatchSourceSignal] = []

    static func run(_ options: Options) throws -> Never {
        guard let path = options.positional.first else { throw ToolError("name the VM bundle to run") }
        let bundle = VMBundle(path: path)
        var config = try bundle.load()
        // Memory and CPUs are chosen per boot; the bundle's values are only the defaults.
        if let gib = options.value("memory-gb") {
            guard let n = UInt64(gib), n > 0 else { throw ToolError("--memory-gb takes a whole number of GiB") }
            config.memoryBytes = n << 30
        }
        config.cpuCount = try options.int("cpus", default: config.cpuCount)

        try bundle.lock()
        let shares = try guestShares(options)
        let network = options.value("network") ?? "nat"
        guard ["nat", "none"].contains(network) else { throw ToolError("--network is nat or none") }
        guard case .tcp(let listenHost, let listenPort) = try ListenAddress.parse(listenText(options.value("listen"))) else {
            throw ToolError("--listen takes HOST:PORT on the host")
        }
        let listen = ListenAddress.tcp(host: try resolveListenHost(listenHost), port: listenPort)
        // --ssh forwards to the guest's sshd through the guest's relay (install-guest.sh), over
        // vsock like MCP, so it needs no route to the guest.
        let ssh = try options.value("ssh").map { text -> ListenAddress in
            let full = text.contains(":") ? text : "\(text):8722"
            guard case .tcp(let host, let port) = try ListenAddress.parse(full) else { throw ToolError("--ssh takes tailscale or HOST[:PORT]") }
            return .tcp(host: try resolveListenHost(host), port: port)
        }
        let guestPort = UInt32(try options.int("guest-port", default: 8765))
        // SO_REUSEADDR lets our bind share a port with a wildcard listener, so a bind that succeeds
        // doesn't prove the port is ours. Refuse before booting if anything already answers on it.
        for case .tcp(let host, let port) in [listen] + (ssh.map { [$0] } ?? []) where tcpAnswers(host: host, port: port) {
            throw ToolError("something on this Mac already answers on \(host):\(port) (see: lsof -nP -iTCP:\(port) -sTCP:LISTEN); pick another port")
        }

        let configuration = try makeConfiguration(bundle, config, shares: shares, network: network == "nat")
        print("booting with \(config.cpuCount) CPUs and \(config.memoryBytes >> 30) GiB memory")
        // A guest due for provisioning gets Apple's start options on this, its first boot.
        let startOptions = try config.provision.map { try Provisioning.startOptions(user: $0.user, password: $0.password) }
        let gui = options.flag("gui")

        // Just after an install, the installer's VM service can still hold the auxiliary storage
        // for a few seconds; starting then fails with EAGAIN, so wait and try again.
        func boot(attempt: Int) {
            let vm = VZVirtualMachine(configuration: configuration)
            self.vm = vm
            let delegate = StopDelegate()
            vm.delegate = delegate
            self.delegate = delegate
            let started: (Error?) -> Void = { error in
                if let error {
                    let posix = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
                    if posix?.domain == NSPOSIXErrorDomain, posix?.code == Int(EAGAIN), attempt < 30 {
                        if attempt == 1 { print("the VM's storage is still held by another process; waiting for it") }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { boot(attempt: attempt + 1) }
                        return
                    }
                    fail("couldn't start the VM: \(error)")
                }
                if let account = config.provision {
                    var updated = config
                    updated.provision = nil
                    do { try bundle.save(updated) } catch { fail("started, but couldn't record that provisioning ran: \(error)") }
                    print("provisioning the guest: account \(account.user), automatic login, SSH")
                }
                print("running \(bundle.url.path): project \(shares[0].url.path), network \(network)")
                guard let socket = vm.socketDevices.first as? VZVirtioSocketDevice else { fail("the VM has no virtio socket device") }
                do {
                    let forwarder = try Forwarder(device: socket, guestPort: guestPort, listen: listen)
                    forwarder.start()
                    self.forwarder = forwarder
                    print("MCP: listening on \(listen.hostPort); waiting for the guest's agent on vsock port \(guestPort)")
                    forwarder.whenGuestAnswers(warnAfter: 120, late: {
                        print("MCP: the guest's agent hasn't answered after 2 minutes. If this VM is new, run in its Terminal:")
                        print("  zsh \"/Volumes/My Shared Files/tools/install-guest.sh\"")
                    }, ready: {
                        print("MCP: ready at http://\(listen.hostPort)/mcp")
                    })
                } catch {
                    fail("couldn't listen on \(listen): \(error)")
                }
                if let ssh {
                    do {
                        let forwarder = try Forwarder(device: socket, guestPort: 8722, listen: ssh)
                        forwarder.start()
                        self.sshForwarder = forwarder
                        print("SSH: ssh -p \(ssh.port) admin@\(ssh.host) (key login; the guest relays to its sshd)")
                    } catch {
                        fail("couldn't listen on \(ssh) for SSH: \(error)")
                    }
                }
                if gui { showWindow(vm, title: bundle.url.deletingPathExtension().lastPathComponent) }
            }
            if let startOptions {
                vm.start(options: startOptions, completionHandler: started)
            } else {
                vm.start { result in
                    if case .failure(let error) = result { started(error) } else { started(nil) }
                }
            }
        }
        boot(attempt: 1)
        handleSignals()
        dispatchMain()
    }

    /// The first SIGINT or SIGTERM asks the guest to shut down; a second, or 60 seconds without
    /// it shutting down, stops the VM outright.
    private static func handleSignals() {
        var asked = false
        for sig in [SIGINT, SIGTERM] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                guard let vm else { exit(0) }
                if asked || !vm.canRequestStop {
                    print("stopping the VM")
                    vm.stop { _ in exit(0) }
                    return
                }
                asked = true
                print("asking the guest to shut down; send the signal again to stop it outright")
                try? vm.requestStop()
                DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
                    print("the guest didn't shut down within 60s; stopping the VM")
                    vm.stop { _ in exit(0) }
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private static func showWindow(_ vm: VZVirtualMachine, title: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let view = VZVirtualMachineView()
        view.virtualMachine = vm
        view.capturesSystemKeys = true
        if #available(macOS 14, *) { view.automaticallyReconfiguresDisplay = true }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.contentView = view
        window.title = title
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        app.activate(ignoringOtherApps: true)
        app.run()
    }
}

final class StopDelegate: NSObject, VZVirtualMachineDelegate {
    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        print("the guest shut down")
        exit(0)
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        fail("the VM stopped with an error: \(error)")
    }
}

extension ListenAddress {
    var host: String { if case .tcp(let host, _) = self { host } else { "localhost" } }
    var port: UInt32 {
        switch self {
        case .tcp(_, let port): UInt32(port)
        case .vsock(let port): port
        }
    }
    var hostPort: String {
        switch self {
        case .tcp(let host, let port): return "\(host):\(port)"
        case .vsock(let port): return "vsock:\(port)"
        }
    }
}

/// `--listen` as HOST:PORT. Default 127.0.0.1:8765; a bare HOST gets port 8765.
func listenText(_ value: String?) -> String {
    guard let value else { return "127.0.0.1:8765" }
    return value.contains(":") ? value : "\(value):8765"
}

/// An IPv4 address to bind for `--listen`'s HOST: an address as given; `tailscale` for this Mac's
/// Tailscale address (the interface holding one in 100.64.0.0/10, Tailscale's range); or a host
/// name, such as this Mac's MagicDNS name, resolved to IPv4.
func resolveListenHost(_ host: String) throws -> String {
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
