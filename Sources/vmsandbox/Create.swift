import Foundation
import SandboxKit
import Virtualization

/// `vmsandbox create`: a new VM bundle with macOS installed from a local restore image.
enum Create {
    private static var installer: VZMacOSInstaller?
    private static var progress: NSKeyValueObservation?

    static func run(_ options: Options) throws -> Never {
        guard let path = options.positional.first else { throw ToolError("name the bundle to create") }
        let bundle = VMBundle(path: path)
        guard !FileManager.default.fileExists(atPath: bundle.url.path) else {
            throw ToolError("\(bundle.url.path) already exists")
        }
        let ipsw = URL(fileURLWithPath: try options.require("ipsw"))
        let cpus = try options.int("cpus", default: ProcessInfo.processInfo.processorCount)
        let physicalGiB = Int(ProcessInfo.processInfo.physicalMemory >> 30)
        let memoryGiB = try options.int("memory-gb", default: max(physicalGiB - 8, 8))
        let diskGiB = try options.int("disk-gb", default: 64)
        let account = VMBundle.Config.Account(user: options.value("user") ?? "admin", password: options.value("password") ?? "admin")

        print("reading \(ipsw.path)")
        VZMacOSRestoreImage.load(from: ipsw) { result in
            DispatchQueue.main.async {
                do {
                    try install(bundle, image: try result.get(), ipsw: ipsw, cpus: cpus, account: account,
                                memory: UInt64(memoryGiB) << 30, disk: UInt64(diskGiB) << 30)
                } catch {
                    fail("\(error)")
                }
            }
        }
        dispatchMain()
    }

    private static func install(_ bundle: VMBundle, image: VZMacOSRestoreImage, ipsw: URL,
                                cpus: Int, account: VMBundle.Config.Account, memory: UInt64, disk: UInt64) throws {
        guard let requirements = image.mostFeaturefulSupportedConfiguration else {
            throw ToolError("this Mac can't run macOS \(image.operatingSystemVersion.string) from that restore image")
        }
        guard requirements.hardwareModel.isSupported else { throw ToolError("the restore image's hardware model isn't supported here") }
        guard cpus >= requirements.minimumSupportedCPUCount else {
            throw ToolError("macOS \(image.operatingSystemVersion.string) needs at least \(requirements.minimumSupportedCPUCount) CPUs")
        }
        guard memory >= requirements.minimumSupportedMemorySize else {
            throw ToolError("macOS \(image.operatingSystemVersion.string) needs at least \(requirements.minimumSupportedMemorySize >> 30) GiB")
        }

        let fm = FileManager.default
        try fm.createDirectory(at: bundle.url, withIntermediateDirectories: true)
        // A sparse file: it takes space only as the guest writes.
        guard fm.createFile(atPath: bundle.diskURL.path, contents: nil) else { throw ToolError("can't create \(bundle.diskURL.path)") }
        let handle = try FileHandle(forWritingTo: bundle.diskURL)
        try handle.truncate(atOffset: disk)
        try handle.close()
        _ = try VZMacAuxiliaryStorage(creatingStorageAt: bundle.auxURL, hardwareModel: requirements.hardwareModel, options: [])
        let config = VMBundle.Config(cpuCount: cpus, memoryBytes: memory,
                                     hardwareModel: requirements.hardwareModel.dataRepresentation,
                                     machineIdentifier: VZMacMachineIdentifier().dataRepresentation,
                                     macAddress: VZMACAddress.randomLocallyAdministered().string,
                                     osVersion: image.operatingSystemVersion.string, osBuild: image.buildVersion,
                                     provision: image.operatingSystemVersion.majorVersion >= 27 ? account : nil)
        try bundle.save(config)

        let vm = VZVirtualMachine(configuration: try makeConfiguration(bundle, config, shares: [], network: true))
        let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: ipsw)
        print("installing macOS \(image.operatingSystemVersion.string) into \(bundle.url.path): \(cpus) CPUs, \(memory >> 30) GiB memory, \(disk >> 30) GiB disk")
        progress = installer.progress.observe(\Progress.fractionCompleted) { p, _ in
            print(String(format: "  %3.0f%%", p.fractionCompleted * 100))
        }
        self.installer = installer
        installer.install { result in
            switch result {
            case .success where config.provision != nil:
                print("installed. The first vmsandbox run creates the account \(account.user) with automatic login and SSH, through Apple's guest provisioning.")
                exit(0)
            case .success:
                print("installed. Next: vmsandbox run \(bundle.url.path) --share PROJECT --gui, and finish Setup Assistant in the window.")
                exit(0)
            case .failure(let error):
                fail("install failed: \(error). The partial bundle is at \(bundle.url.path); delete it before trying again.")
            }
        }
    }
}

extension OperatingSystemVersion {
    var string: String { "\(majorVersion).\(minorVersion).\(patchVersion)" }
}
