import Foundation
import SandboxKit
import Virtualization

/// `sandbox-vm create [NAME]`: a new VM with macOS installed, from --ipsw or else the newest restore
/// image this Mac supports, downloaded into the clone's vms/ (kept there for the next create).
enum Create {
    private static var installer: VZMacOSInstaller?
    private static var progress: NSKeyValueObservation?

    static func run(_ options: Options) throws -> Never {
        guard options.positional.count <= 1 else { throw ToolError("sandbox-vm create takes one NAME, got: \(options.positional.joined(separator: " "))") }
        let bundle = VMBundle(named: options.positional.first)
        guard !FileManager.default.fileExists(atPath: bundle.url.path) else {
            throw ToolError("\(bundle.url.path) already exists")
        }
        let ipsw = try options.value("ipsw").map { URL(fileURLWithPath: $0) } ?? downloadLatest(into: bundle.url.deletingLastPathComponent())
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

    /// The newest restore image this Mac supports, downloaded once (resuming a partial download)
    /// into `folder` and reused after.
    private static func downloadLatest(into folder: URL) throws -> URL {
        var found: Result<VZMacOSRestoreImage, Error>?
        let done = DispatchSemaphore(value: 0)
        VZMacOSRestoreImage.fetchLatestSupported { found = $0; done.signal() }
        done.wait()
        guard let image = try found?.get() else { throw ToolError("couldn't fetch the restore image catalog") }
        let ipsw = folder.appendingPathComponent(image.url.lastPathComponent)
        if FileManager.default.fileExists(atPath: ipsw.path) { print("using \(ipsw.path)"); return ipsw }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let partial = ipsw.path + ".partial"
        print("downloading macOS \(image.operatingSystemVersion.string) (\(image.buildVersion)) to \(ipsw.path)")
        let curl = Process()
        curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        curl.arguments = ["-fL", "-C", "-", "-o", partial, image.url.absoluteString]
        try curl.run()
        curl.waitUntilExit()
        guard curl.terminationStatus == 0 else { throw ToolError("the download failed (curl exited \(curl.terminationStatus)); run create again to resume it") }
        try FileManager.default.moveItem(atPath: partial, toPath: ipsw.path)
        return ipsw
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
                print("installed. The first sandbox-vm run creates the account \(account.user) with automatic login and SSH, through Apple's guest provisioning.")
                exit(0)
            case .success:
                print("installed macOS into \(bundle.url.path)")
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
