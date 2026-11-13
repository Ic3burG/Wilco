import Darwin
import Foundation

/// CPU and memory use over a run.
///
/// System-wide CPU is measured as well as this process's, because Apple's
/// speech engines may do part of their work in a system service.
struct ResourceMeter {
    private let processStart: Double
    private let systemStart: (busy: UInt64, total: UInt64)
    private let wallStart = ContinuousClock.now
    private(set) var peakFootprint: UInt64 = 0

    init() {
        processStart = Self.processCPUSeconds()
        systemStart = Self.systemTicks()
        sample()
    }

    /// Records memory now; call regularly to catch the peak.
    mutating func sample() {
        peakFootprint = max(peakFootprint, Self.footprint())
    }

    struct Usage {
        /// Average cores used by this process (1.5 = 150% in Activity Monitor).
        var processCPU: Double
        /// Average share of all cores busy, 0 to 1.
        var systemCPU: Double
        var peakMemoryMB: Double
    }

    func finish() -> Usage {
        let wall = Double((ContinuousClock.now - wallStart) / .milliseconds(1)) / 1_000
        let system = Self.systemTicks()
        let busy = Double(system.busy &- systemStart.busy)
        let total = Double(system.total &- systemStart.total)
        return Usage(
            processCPU: wall > 0 ? (Self.processCPUSeconds() - processStart) / wall : 0,
            systemCPU: total > 0 ? busy / total : 0,
            peakMemoryMB: Double(peakFootprint) / 1_048_576
        )
    }

    private static func processCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    private static func systemTicks() -> (busy: UInt64, total: UInt64) {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return (0, 0) }
        let user = UInt64(info.cpu_ticks.0), system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2), nice = UInt64(info.cpu_ticks.3)
        return (user + system + nice, user + system + nice + idle)
    }

    /// Memory charged to this process, as Activity Monitor's "Memory" column shows.
    private static func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
