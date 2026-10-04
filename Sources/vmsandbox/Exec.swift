import Foundation
import SandboxKit

/// `vmsandbox ip` and `vmsandbox exec`: reaching a running guest over SSH on its private NAT
/// network, so scripts can customise a VM with no one at its screen. The guest account's
/// password is fixed and documented (admin/admin by default, Tart's convention). It isn't a
/// secret: the boundary is the VM, which only this Mac can reach.
enum Exec {
    /// The guest's address, from the host's DHCP leases for the bundle's fixed MAC address.
    static func address(_ bundle: VMBundle) throws -> String {
        guard let mac = try bundle.load().macAddress.map(normalizeMAC) else {
            throw ToolError("\(bundle.url.path) has no fixed MAC address, so its lease can't be found")
        }
        let leases = (try? String(contentsOfFile: "/var/db/dhcpd_leases", encoding: .utf8)) ?? ""
        var ip: String?
        for block in leases.components(separatedBy: "}") {
            var fields: [String: String] = [:]
            for line in block.split(separator: "\n") {
                let parts = line.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
                if parts.count == 2 { fields[String(parts[0])] = String(parts[1]) }
            }
            // hw_address is "1,<mac>"; leases for the same MAC are listed newest first.
            if let hw = fields["hw_address"]?.split(separator: ",").last, normalizeMAC(String(hw)) == mac {
                ip = fields["ip_address"]
                break
            }
        }
        guard let ip else { throw ToolError("no DHCP lease for \(mac) yet; is the VM running with --network nat?") }
        return ip
    }

    /// `exec BUNDLE [--root] [--user U --password P] [--host IP] SCRIPT|-`: runs a zsh script in the guest,
    /// streaming its output, and exits with its status.
    static func run(_ options: Options) throws -> Never {
        guard options.positional.count == 2 else { throw ToolError("usage: vmsandbox exec BUNDLE [--root] SCRIPT|-") }
        let bundle = VMBundle(path: options.positional[0])
        let user = options.value("user") ?? "admin"
        let password = options.value("password") ?? "admin"
        guard !password.contains("'") else { throw ToolError("the password can't contain a single quote") }
        let script = options.positional[1]
        let input = script == "-" ? FileHandle.standardInput : try FileHandle(forReadingFrom: URL(fileURLWithPath: script))

        // As root, sudo first validates with the password, then runs the script from stdin.
        let remote = options.flag("root")
            ? "printf '%s\\n' '\(password)' | sudo -S -v -p '' && sudo -n /bin/zsh -s"
            : "/bin/zsh -s"
        let host = try options.value("host") ?? address(bundle)
        let status = try ssh(host, user: user, password: password, command: remote, input: input)
        exit(status)
    }

    /// Runs `command` in the guest over SSH with password authentication through SSH_ASKPASS.
    static func ssh(_ host: String, user: String, password: String, command: String, input: FileHandle) throws -> Int32 {
        let askpass = FileManager.default.temporaryDirectory.appendingPathComponent("vmsandbox-askpass-\(getpid())")
        try "#!/bin/sh\nprintf '%s\\n' '\(password)'\n".write(to: askpass, atomically: true, encoding: .utf8)
        chmod(askpass.path, 0o700)
        defer { try? FileManager.default.removeItem(at: askpass) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR",
            "-o", "ConnectTimeout=10", "-o", "PubkeyAuthentication=no", "-o", "NumberOfPasswordPrompts=1",
            "-o", "PreferredAuthentications=password,keyboard-interactive",
            "\(user)@\(host)", command,
        ]
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["SSH_ASKPASS": askpass.path, "SSH_ASKPASS_REQUIRE": "force", "DISPLAY": ":0"]) { $1 }
        process.standardInput = input
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    /// Lowercase, colon-separated, two digits per byte: leases drop leading zeros.
    private static func normalizeMAC(_ mac: String) -> String {
        mac.split(separator: ":").map { String(format: "%02x", Int($0, radix: 16) ?? 0) }.joined(separator: ":")
    }
}
