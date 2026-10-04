import Foundation
import SandboxKit
import Virtualization

// The host side of vm-sandbox: creates and runs a macOS VM under Apple's Virtualization
// framework, with one project folder shared into it and its MCP aggregator forwarded to a host
// port. The binary needs the com.apple.security.virtualization entitlement to start a VM.

let usage = """
usage:
  vmsandbox ipsw-url
      Print the URL of the latest macOS restore image this Mac supports. Downloads nothing.
  vmsandbox ipsw-info RESTORE.ipsw
      Print the macOS version in a restore image and the least CPUs and memory it needs here.
  vmsandbox create BUNDLE --ipsw RESTORE.ipsw [--cpus N] [--memory-gb N] [--disk-gb N]
      Make a VM bundle and install macOS into it. Defaults: all CPUs, physical memory less
      8 GiB, a 64 GiB sparse disk.
  vmsandbox ip BUNDLE
      Print a running VM's address on its private NAT network.
  vmsandbox exec BUNDLE [--root] [--user U] [--password P] [--host IP] SCRIPT|-
      Run a zsh script in a running VM over SSH (account admin/admin by default), as root
      with --root. Needs Remote Login on in the guest.
  vmsandbox run BUNDLE --share PROJECT_DIR [--memory-gb N] [--cpus N] [--tools DIR] [--gui]
                [--network nat|none] [--listen HOST:PORT|tailnet:PORT] [--guest-port N]
      Boot the VM. The guest sees PROJECT_DIR read-write at /Volumes/My Shared Files/project
      and DIR (default: guest/ beside this binary) read-only at .../tools. MCP is forwarded
      from http://HOST:PORT/mcp (default 127.0.0.1:8765) to guest vsock port N (default 8765).
      --memory-gb and --cpus apply to this boot only; the defaults are the values from create.
"""

signal(SIGPIPE, SIG_IGN)
setvbuf(stdout, nil, _IOLBF, 0) // progress lines show up promptly in logs and pipes
let argv = Array(CommandLine.arguments.dropFirst())

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
        try Create.run(try Options(Array(argv.dropFirst())))
    case "ip":
        guard argv.count == 2 else { throw ToolError("name the VM bundle") }
        print(try Exec.address(VMBundle(path: argv[1])))
        exit(0)
    case "exec":
        try Exec.run(try Options(Array(argv.dropFirst()), flags: ["root"]))
    case "run":
        try Run.run(try Options(Array(argv.dropFirst()), flags: ["gui"]))
    default:
        print(usage)
        exit(argv.isEmpty || argv.first == "help" ? 0 : 64)
    }
} catch {
    fail("\(error)")
}
