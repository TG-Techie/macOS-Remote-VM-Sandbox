import AppKit
import Foundation
import SandboxKit
import Virtualization

/// `sandbox-vm run`: boots a VM with the project folder shared into it, and forwards a TCP port on
/// the host to the aggregator's vsock port in the guest.
enum Run {
    private static var vm: VZVirtualMachine?
    private static var forwarder: Forwarder?
    private static var sshForwarder: Forwarder?
    private static var delegate: StopDelegate?
    private static var window: NSWindow?
    private static var signalSources: [DispatchSourceSignal] = []

    static func run(_ options: Options) throws -> Never {
        guard options.positional.count <= 1 else { throw ToolError("sandbox-vm run takes one NAME, got: \(options.positional.joined(separator: " "))") }
        let bundle = VMBundle(named: options.positional.first)
        var config = try bundle.load()
        // Memory and CPUs are chosen per boot; the bundle's values are only the defaults.
        if let gib = options.value("memory-gb") {
            guard let n = UInt64(gib), n > 0 else { throw ToolError("--memory-gb takes a whole number of GiB") }
            config.memoryBytes = n << 30
        }
        config.cpuCount = try options.int("cpus", default: config.cpuCount)

        try bundle.lock()
        // The project folder: --share, or the one this VM last ran with, which the bundle keeps.
        guard let sharePath = options.value("share") ?? config.share else {
            throw ToolError("this VM hasn't run with a project folder yet: give one with --share DIR (it's remembered after)")
        }
        let shares = try guestShares(project: sharePath, tools: options.value("tools"))
        if let given = options.value("share"), given != config.share {
            var stored = try bundle.load()
            stored.share = shares[0].url.path
            try bundle.save(stored)
        }
        print("share: \(shares[0].url.path)" + (options.value("share") == nil ? " (remembered from this VM's last run; --share DIR to change)" : "")
              + ", at /Volumes/My Shared Files/project in the guest")
        let network = options.flag("no-network") ? "none" : "nat"
        // MCP and SSH are served on 127.0.0.1, or with --tailnet on this Mac's Tailscale address.
        // SSH reaches the guest's sshd through the guest's relay (install-guest.sh), over vsock
        // like MCP, so it needs no route to the guest.
        let host = options.flag("tailnet") ? try resolveListenHost("tailscale") : "127.0.0.1"
        let listen = ListenAddress.tcp(host: host, port: try port(options, "mcp-port", default: 8765))
        let ssh = ListenAddress.tcp(host: host, port: try port(options, "ssh-port", default: 8722))
        let guestPort = UInt32(try port(options, "guest-port", default: 8765))
        // SO_REUSEADDR lets our bind share a port with a wildcard listener, so a bind that succeeds
        // doesn't prove the port is ours. Refuse before booting if anything already answers on it.
        for case .tcp(let host, let port) in [listen, ssh] where tcpAnswers(host: host, port: port) {
            throw ToolError("something on this Mac already answers on \(host):\(port) (see: lsof -nP -iTCP:\(port) -sTCP:LISTEN); pick another port")
        }

        let configuration = try makeConfiguration(bundle, config, shares: shares, network: network == "nat")
        print("VM mode: booting with \(config.cpuCount) CPUs and \(config.memoryBytes >> 30) GiB memory")
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
                    // From disk, so this boot's memory and CPUs don't become the defaults.
                    do {
                        var stored = try bundle.load()
                        stored.provision = nil
                        try bundle.save(stored)
                    } catch { fail("started, but couldn't record that provisioning ran: \(error)") }
                    print("provisioning the guest: account \(account.user), automatic login, SSH")
                }
                print("running \(bundle.url.path), network \(network)")
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
                        print("MCP: ready at http://\(hostName(listen.host)):\(listen.port)/mcp")
                    })
                } catch {
                    fail("couldn't listen on \(listen): \(error)")
                }
                do {
                    let forwarder = try Forwarder(device: socket, guestPort: 8722, listen: ssh)
                    forwarder.start()
                    self.sshForwarder = forwarder
                    print("SSH: ssh -p \(ssh.port) admin@\(hostName(ssh.host)) (keys only)")
                } catch {
                    fail("couldn't listen on \(ssh) for SSH: \(error)")
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
    var hostPort: String {
        switch self {
        case .tcp(let host, let port): return "\(host):\(port)"
        case .vsock(let port): return "vsock:\(port)"
        }
    }
}


