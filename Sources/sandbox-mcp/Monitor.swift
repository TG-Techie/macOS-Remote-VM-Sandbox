import Foundation
import SandboxKit

/// Resource monitoring for a host sandbox, which allows only that: free space on the project's
/// volume (including what macOS can purge, such as local snapshots) and memory. It runs outside the
/// sandbox, as fixed code that takes no arguments, because the purgeable figure comes from a system
/// service the sandbox doesn't reach.
final class MonitorServer {
    private let root: URL

    init(root: String) {
        self.root = URL(fileURLWithPath: root)
    }

    var tools: [Tool] {
        [Tool(name: "resources",
              description: "Free space on the project folder's volume (free now, and available once macOS purges what it can, such as local snapshots and caches) and memory (total, free, compressed, swap, pressure).",
              properties: [:], run: { _ in try self.resources() })]
    }

    private func resources() throws -> String {
        func gib(_ bytes: some BinaryInteger) -> String { String(format: "%.1f GiB", Double(bytes) / 1_073_741_824) }
        var lines: [String] = []

        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey,
                                         .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityForOpportunisticUsageKey]
        let disk = try root.resourceValues(forKeys: keys)
        lines.append("disk: \(disk.volumeTotalCapacity.map(gib) ?? "?") total, \(disk.volumeAvailableCapacity.map(gib) ?? "?") free now, "
            + "\(disk.volumeAvailableCapacityForImportantUsage.map(gib) ?? "?") available for important use (free plus purgeable), "
            + "\(disk.volumeAvailableCapacityForOpportunisticUsage.map(gib) ?? "?") for opportunistic use")

        func sysctl<T: BitwiseCopyable>(_ name: String, _ value: inout T) -> Bool {
            var size = MemoryLayout<T>.size
            return withUnsafeMutableBytes(of: &value) { sysctlbyname(name, $0.baseAddress, &size, nil, 0) } == 0
        }
        var memsize: UInt64 = 0, pressure: Int32 = 0
        var swap = xsw_usage()
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let page = UInt64(vm_kernel_page_size)
        let statsOK = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        } == KERN_SUCCESS
        var memory = "memory: \(sysctl("hw.memsize", &memsize) ? gib(memsize) : "?") total"
        if statsOK {
            memory += ", \(gib(UInt64(stats.free_count) * page)) free, \(gib(UInt64(stats.inactive_count) * page)) inactive, "
                + "\(gib(UInt64(stats.compressor_page_count) * page)) compressed"
        }
        if sysctl("vm.swapusage", &swap) { memory += ", swap \(gib(swap.xsu_used)) used of \(gib(swap.xsu_total))" }
        if sysctl("kern.memorystatus_vm_pressure_level", &pressure) {
            memory += ", pressure " + (pressure >= 4 ? "critical" : pressure >= 2 ? "warning" : "normal")
        }
        lines.append(memory)
        return lines.joined(separator: "\n")
    }
}
