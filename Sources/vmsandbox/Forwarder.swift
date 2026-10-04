import Foundation
import SandboxKit
import Virtualization

/// Accepts TCP connections on the host and joins each to a new virtio socket connection to the
/// guest port. The guest needs no network for this, and nothing in it listens on an IP address.
final class Forwarder {
    private let device: VZVirtioSocketDevice
    private let guestPort: UInt32
    private let listenFD: Int32
    /// Open guest connections. Each one's descriptor closes when it's released, so it's held
    /// here until both directions finish. Touched only on the main queue.
    private var open: [ObjectIdentifier: VZVirtioSocketConnection] = [:]

    init(device: VZVirtioSocketDevice, guestPort: UInt32, listen: ListenAddress) throws {
        self.device = device
        self.guestPort = guestPort
        listenFD = try listenSocket(listen)
    }

    /// Polls the guest port until the agent accepts a connection, then calls `ready` once on the
    /// main queue. Calls `late` once if it hasn't after `warnAfter` seconds, and keeps polling.
    func whenGuestAnswers(warnAfter: TimeInterval, late: @escaping () -> Void, ready: @escaping () -> Void) {
        let started = Date()
        var warned = false
        func attempt() {
            var settled = false
            func retry() {
                guard !settled else { return }
                settled = true
                if !warned, Date().timeIntervalSince(started) > warnAfter { warned = true; late() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { attempt() }
            }
            // As in connect(_:): with nothing listening, the completion may never run.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { retry() }
            device.connect(toPort: guestPort) { result in
                DispatchQueue.main.async {
                    guard case .success(let connection) = result else { return retry() }
                    connection.close()
                    guard !settled else { return }
                    settled = true
                    ready()
                }
            }
        }
        attempt()
    }

    func start() {
        Thread.detachNewThread { [self] in
            acceptLoop(listenFD) { client in
                DispatchQueue.main.async { self.connect(client) }
            }
        }
    }

    /// Runs on the main queue, which is the VM's queue.
    private func connect(_ client: Int32) {
        var settled = false
        // Apple: if the guest isn't listening, connect(toPort:) "does nothing", so the completion
        // may never run. Give up after 10 seconds.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            guard !settled else { return }
            settled = true
            FileHandle.standardError.write(Data("vmsandbox: nothing answered on guest vsock port \(self.guestPort); is sandbox-mcp running in the guest?\n".utf8))
            close(client)
        }
        device.connect(toPort: guestPort) { result in
            DispatchQueue.main.async {
                guard !settled else {
                    if case .success(let connection) = result { connection.close() }
                    return
                }
                settled = true
                switch result {
                case .failure(let error):
                    FileHandle.standardError.write(Data("vmsandbox: guest connection failed: \(error)\n".utf8))
                    close(client)
                case .success(let connection):
                    self.bridge(client, connection)
                }
            }
        }
    }

    private func bridge(_ client: Int32, _ connection: VZVirtioSocketConnection) {
        let key = ObjectIdentifier(connection)
        open[key] = connection
        let guest = connection.fileDescriptor
        let finished = DispatchGroup()
        for (from, to) in [(client, guest), (guest, client)] {
            finished.enter()
            Thread.detachNewThread {
                Self.pump(from, to)
                finished.leave()
            }
        }
        finished.notify(queue: .main) {
            close(client)
            connection.close()
            self.open[key] = nil
        }
    }

    private static func pump(_ from: Int32, _ to: Int32) {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(from, &buffer, buffer.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            if !writeAll(to, Data(buffer[0..<n])) { break }
        }
        shutdown(to, SHUT_WR)
    }
}

