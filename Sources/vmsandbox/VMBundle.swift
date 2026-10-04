import Foundation
import SandboxKit
import Virtualization

/// A VM on disk: a folder holding its config, its boot disk and its auxiliary storage.
struct VMBundle {
    struct Config: Codable {
        var cpuCount: Int
        var memoryBytes: UInt64
        var hardwareModel: Data
        var machineIdentifier: Data
        /// Fixed so the guest keeps its DHCP lease, which setup uses to find it.
        var macAddress: String?
        /// The installed macOS, which setup writes into Setup Assistant's state.
        var osVersion: String?
        var osBuild: String?
        /// Set by create for a macOS 27 or later guest: the account Apple's guest provisioning
        /// creates on the first boot. Cleared once that boot has started. The password is fixed
        /// and documented, not a secret: the boundary is the VM, which only this Mac can reach.
        var provision: Account?
        struct Account: Codable { var user: String; var password: String }
        /// The project folder the VM last ran with, used when `run` isn't given --share.
        var share: String?
    }

    let url: URL
    var configURL: URL { url.appendingPathComponent("config.json") }
    var diskURL: URL { url.appendingPathComponent("disk.img") }
    var auxURL: URL { url.appendingPathComponent("aux.img") }

    init(path: String) { url = URL(fileURLWithPath: path).standardizedFileURL }

    /// A VM by name, kept in the clone's vms/ (`sandbox` when none is given), or by a path to its
    /// bundle (anything with a slash or ending in .vmbundle).
    init(named name: String?) {
        let name = name ?? "sandbox"
        if name.contains("/") || name.hasSuffix(".vmbundle") { self.init(path: name); return }
        self.init(path: cloneDirectory().appendingPathComponent("vms/\(name).vmbundle").path)
    }

    func load() throws -> Config {
        guard let data = FileManager.default.contents(atPath: configURL.path) else {
            throw ToolError("no VM at \(url.path) (missing config.json)")
        }
        return try JSONDecoder().decode(Config.self, from: data)
    }

    /// Holds an exclusive lock on the bundle for as long as the process runs, so two processes
    /// never use one disk.
    func lock() throws {
        let fd = open(configURL.path, O_RDONLY)
        guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            throw ToolError("\(url.path) is in use by another sandbox-vm process")
        }
    }

    func save(_ config: Config) throws {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(config).write(to: configURL)
    }
}

/// The host folders the guest sees, under /Volumes/My Shared Files/<name>.
struct Share {
    let name: String
    let url: URL
    let readOnly: Bool
}

/// The VM's hardware: Apple's Mac platform with its paravirtualized GPU, one disk, optional NAT
/// networking, a virtio socket for the aggregator, and the shared folders.
func makeConfiguration(_ bundle: VMBundle, _ config: VMBundle.Config, shares: [Share], network: Bool) throws
    -> VZVirtualMachineConfiguration {
    guard let model = VZMacHardwareModel(dataRepresentation: config.hardwareModel),
          let machine = VZMacMachineIdentifier(dataRepresentation: config.machineIdentifier) else {
        throw ToolError("\(bundle.configURL.path) has an unreadable hardware model or machine identifier")
    }
    guard model.isSupported else { throw ToolError("this Mac can't run the VM's hardware model") }

    let platform = VZMacPlatformConfiguration()
    platform.hardwareModel = model
    platform.machineIdentifier = machine
    platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: bundle.auxURL)

    let c = VZVirtualMachineConfiguration()
    c.platform = platform
    c.bootLoader = VZMacOSBootLoader()
    c.cpuCount = config.cpuCount
    c.memorySize = config.memoryBytes

    let graphics = VZMacGraphicsDeviceConfiguration()
    graphics.displays = [VZMacGraphicsDisplayConfiguration(widthInPixels: 1920, heightInPixels: 1200, pixelsPerInch: 80)]
    c.graphicsDevices = [graphics]
    c.keyboards = [VZUSBKeyboardConfiguration()]
    c.pointingDevices = [VZUSBScreenCoordinatePointingDeviceConfiguration()]

    c.storageDevices = [VZVirtioBlockDeviceConfiguration(
        attachment: try VZDiskImageStorageDeviceAttachment(url: bundle.diskURL, readOnly: false))]
    if network {
        let nic = VZVirtioNetworkDeviceConfiguration()
        nic.attachment = VZNATNetworkDeviceAttachment()
        if let mac = config.macAddress.flatMap(VZMACAddress.init(string:)) { nic.macAddress = mac }
        c.networkDevices = [nic]
    }
    c.socketDevices = [VZVirtioSocketDeviceConfiguration()]
    c.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
    c.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

    if !shares.isEmpty {
        let fs = VZVirtioFileSystemDeviceConfiguration(tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
        var directories: [String: VZSharedDirectory] = [:]
        for share in shares { directories[share.name] = VZSharedDirectory(url: share.url, readOnly: share.readOnly) }
        fs.share = VZMultipleDirectoryShare(directories: directories)
        c.directorySharingDevices = [fs]
    }

    try c.validate()
    return c
}

/// The clone this binary was built in: dist/'s parent. Run from elsewhere (a development build),
/// the current folder.
func cloneDirectory() -> URL {
    let dir = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
    return dir.lastPathComponent == "dist" ? dir.deletingLastPathComponent() : URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
}

/// The shares `run` gives the guest: the project, and the tools folder (default dist/guest), which
/// is read-only so nothing in the guest can change the server it runs.
func guestShares(project projectPath: String, tools toolsPath: String?) throws -> [Share] {
    let project = URL(fileURLWithPath: (projectPath as NSString).expandingTildeInPath).standardizedFileURL
    let executableDir = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
    let tools = URL(fileURLWithPath: toolsPath ?? executableDir.appendingPathComponent("guest").path)
    for (what, url) in [("project", project), ("guest tools", tools)] {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw ToolError("\(what) folder \(url.path) doesn't exist")
        }
    }
    return [Share(name: "project", url: project, readOnly: false), Share(name: "tools", url: tools, readOnly: true)]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("sandbox-vm: \(message)\n".utf8))
    exit(1)
}
