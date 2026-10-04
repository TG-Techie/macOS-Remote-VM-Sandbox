import AppKit
import Foundation
import SandboxKit
import Virtualization

/// `vmsandbox run`: boots a VM with the project folder shared into it, and forwards a TCP port on
/// the host to the aggregator's vsock port in the guest.
enum Run {
    private static var vm: VZVirtualMachine?
    private static var forwarder: Forwarder?
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
        let listen = try ListenAddress.parse(options.value("listen") ?? "127.0.0.1:8765")
        guard case .tcp = listen else { throw ToolError("--listen takes HOST:PORT on the host") }
        let guestPort = UInt32(try options.int("guest-port", default: 8765))

        let configuration = try makeConfiguration(bundle, config, shares: shares, network: network == "nat")
        print("booting with \(config.cpuCount) CPUs and \(config.memoryBytes >> 30) GiB memory")
        let vm = VZVirtualMachine(configuration: configuration)
        self.vm = vm
        let delegate = StopDelegate()
        vm.delegate = delegate
        self.delegate = delegate

        // A guest due for provisioning gets Apple's start options on this, its first boot.
        let startOptions = try config.provision.map { try Provisioning.startOptions(user: $0.user, password: $0.password) }
        let started: (Error?) -> Void = { error in
            if let error { fail("couldn't start the VM: \(error)") }
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
                print("MCP: http://\(listen.hostPort)/mcp → guest vsock port \(guestPort)")
            } catch {
                fail("couldn't listen on \(listen): \(error)")
            }
        }
        if let startOptions {
            vm.start(options: startOptions, completionHandler: started)
        } else {
            vm.start { result in
                if case .failure(let error) = result { started(error) } else { started(nil) }
            }
        }
        handleSignals()

        if options.flag("gui") { showWindow(vm, title: bundle.url.deletingPathExtension().lastPathComponent) }
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
    var hostPort: String {
        switch self {
        case .tcp(let host, let port): return "\(host):\(port)"
        case .vsock(let port): return "vsock:\(port)"
        }
    }
}
