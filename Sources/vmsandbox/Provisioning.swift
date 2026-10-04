import Foundation
import SandboxKit
import Virtualization

/// Apple's way to skip Setup Assistant, new in macOS 27: VZMacGuestProvisioningOptions gives a
/// macOS 27 guest a user account, automatic login and SSH on its first boot after install
/// (developer.apple.com/documentation/virtualization/vzmacguestprovisioningoptions).
///
/// It's reached through the Objective-C runtime because the macOS 26 SDK this builds with
/// doesn't declare it. When the SDK does, this should become ordinary Swift. On a host without
/// it, this throws rather than starting a VM that would stop at Setup Assistant.
enum Provisioning {
    static func startOptions(user: String, password: String) throws -> VZMacOSVirtualMachineStartOptions {
        guard let optionsClass = NSClassFromString("VZMacGuestProvisioningOptions") as? NSObject.Type else {
            throw ToolError("this Mac's Virtualization framework has no VZMacGuestProvisioningOptions; guest provisioning needs macOS 27 on the host")
        }
        let guest = optionsClass.init()
        guest.setValue(user, forKey: "fullName")
        guest.setValue(user, forKey: "username")
        guest.setValue(password, forKey: "password")
        guest.setValue(true, forKey: "logsInAutomatically")
        guest.setValue(true, forKey: "enablesRemoteLogin")

        let start = VZMacOSVirtualMachineStartOptions()
        let selector = NSSelectorFromString("setGuestProvisioningOptions:error:")
        guard start.responds(to: selector) else {
            throw ToolError("VZMacOSVirtualMachineStartOptions has no setGuestProvisioningOptions:error: on this Mac")
        }
        typealias Setter = @convention(c) (AnyObject, Selector, AnyObject, AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool
        let set = unsafeBitCast(start.method(for: selector), to: Setter.self)
        var error: NSError?
        guard set(start, selector, guest, &error) else {
            throw ToolError("couldn't set guest provisioning: \(error.map { "\($0)" } ?? "unknown error")")
        }
        return start
    }
}
