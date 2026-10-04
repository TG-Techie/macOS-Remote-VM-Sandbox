import Foundation
import SandboxKit
import Virtualization

// The host side of vm-sandbox: creates and runs a macOS VM under Apple's Virtualization
// framework, with one project folder shared into it and its MCP aggregator forwarded to a host
// port. The binary needs the com.apple.security.virtualization entitlement to start a VM.

let usage = """
VM mode: a macOS VM with one project folder shared in, serving shell, file and git tools.
(No VM, on this Mac: dist/sandbox-host.) NAME is a VM in vms/, default sandbox.

usage: dist/sandbox-vm run [NAME] [--share DIR] [--memory-gb N] [--cpus N] [--tailnet] [--gui]
                          [--no-network] [--mcp-port N] [--ssh-port N]
  --share DIR       The project folder, read-write in the guest. Default: the one this VM last
                    ran with (needed the first time).
  --memory-gb N     Memory for this boot. Default: the VM's own, from create.
  --cpus N          CPUs for this boot. Default: the VM's own.
  --tailnet         Serve MCP and SSH on this Mac's Tailscale address. Default: 127.0.0.1 only.
  --gui             Open the VM's window.
  --no-network      No network in the guest. MCP and SSH still work (over vsock).
  --mcp-port N      MCP's port, default 8765. --ssh-port N: SSH's, default 8722.

       dist/sandbox-vm create [NAME] [--memory-gb N] [--cpus N] [--disk-gb 64] [--ipsw FILE]
  Make a VM and install macOS. Without --ipsw, downloads the newest restore image this Mac
  supports into vms/ (about 15-20 GB) and keeps it.

       dist/sandbox-vm exec SCRIPT|- [--vm NAME] [--as-root]
  Run a zsh script in a running VM over SSH (account admin/admin; --user, --password, --host).

       dist/sandbox-vm ip [NAME]           a running VM's address on its private network
       dist/sandbox-vm ipsw-url            the newest restore image's URL (downloads nothing)
       dist/sandbox-vm ipsw-info FILE      a restore image's macOS version and needs
"""

/// What to use instead of an option the VM doesn't take: host mode's, and old spellings.
let vmInstead = Dictionary(uniqueKeysWithValues: ["root", "expose", "rsync", "rsync-port", "allow-read", "print-profile"].map {
    ($0, "--\($0) is host mode's (no VM): dist/sandbox-host DIR")
}).merging([
    "listen": "--tailnet for this Mac's Tailscale address, --mcp-port N for the port",
    "ssh": "SSH is always served, beside MCP: --tailnet puts it on the Tailscale address, --ssh-port N moves it",
    "network": "--no-network",
]) { $1 }

signal(SIGPIPE, SIG_IGN)
setvbuf(stdout, nil, _IOLBF, 0) // progress lines show up promptly in logs and pipes
let argv = Array(CommandLine.arguments.dropFirst())
if argv.contains("--help") || argv.contains("-h") { print(usage); exit(0) }

do {
    switch argv.first {
    case "ipsw-url":
        VZMacOSRestoreImage.fetchLatestSupported { result in
            switch result {
            case .success(let image):
                print("macOS \(image.operatingSystemVersion.string) (\(image.buildVersion)): \(image.url.absoluteString)")
                exit(0)
            case .failure(let error):
                fail("couldn't fetch the restore image catalog: \(error)")
            }
        }
        dispatchMain()
    case "ipsw-info":
        guard argv.count == 2 else { throw ToolError("name the restore image") }
        VZMacOSRestoreImage.load(from: URL(fileURLWithPath: argv[1])) { result in
            do {
                let image = try result.get()
                guard let needs = image.mostFeaturefulSupportedConfiguration else {
                    fail("this Mac can't run macOS \(image.operatingSystemVersion.string) from that image")
                }
                print("macOS \(image.operatingSystemVersion.string) (\(image.buildVersion)): at least \(needs.minimumSupportedCPUCount) CPUs and \(needs.minimumSupportedMemorySize >> 20) MiB memory")
                exit(0)
            } catch {
                fail("couldn't read the restore image: \(error)")
            }
        }
        dispatchMain()
    case "create":
        try Create.run(try Options(Array(argv.dropFirst()), command: "sandbox-vm create",
                                   values: ["ipsw", "cpus", "memory-gb", "disk-gb", "user", "password"], elsewhere: vmInstead))
    case "ip":
        guard argv.count <= 2 else { throw ToolError("sandbox-vm ip takes one NAME") }
        print(try Exec.address(VMBundle(named: argv.count == 2 ? argv[1] : nil)))
        exit(0)
    case "exec":
        try Exec.run(try Options(Array(argv.dropFirst()), command: "sandbox-vm exec",
                                 values: ["vm", "user", "password", "host"], flags: ["as-root"],
                                 elsewhere: vmInstead.merging(["root": "--as-root"]) { $1 }))
    case "run":
        try Run.run(try Options(Array(argv.dropFirst()), command: "sandbox-vm run",
                                values: ["share", "memory-gb", "cpus", "tools", "mcp-port", "ssh-port", "guest-port"],
                                flags: ["gui", "tailnet", "no-network"], elsewhere: vmInstead))
    default:
        print(usage)
        exit(argv.isEmpty || argv.first == "help" ? 0 : 64)
    }
} catch {
    fail("\(error)")
}
