import Darwin
import Foundation
import IOKit

struct SystemSnapshot: Sendable {
    var cpuUser: Double = 0
    var cpuSystem: Double = 0
    var cpuTotal: Double { cpuUser + cpuSystem }
    var perCore: [Double] = []

    var memTotal: UInt64 = 0
    var memApp: UInt64 = 0
    var memWired: UInt64 = 0
    var memCompressed: UInt64 = 0
    var memCached: UInt64 = 0
    var memFree: UInt64 = 0
    var memUsed: UInt64 { memApp + memWired + memCompressed }
    /// 1 — норма, 2 — предупреждение, 4 — критично.
    var memPressure: Int = 1
    var swapUsed: UInt64 = 0
    var swapTotal: UInt64 = 0

    var netIn: Double = 0
    var netOut: Double = 0
    var netInTotal: UInt64 = 0
    var netOutTotal: UInt64 = 0

    var diskRead: Double = 0
    var diskWrite: Double = 0
    var diskReadTotal: UInt64 = 0
    var diskWriteTotal: UInt64 = 0

    var loadAverage: [Double] = [0, 0, 0]
    var bootTime: Date?
}

struct MachineInfo: Sendable {
    let model: String
    let cpuBrand: String
    let physicalCores: Int
    let logicalCores: Int
    let performanceCores: Int?
    let efficiencyCores: Int?
    let memory: UInt64
    let osVersion: String
    let hostName: String

    static let current = MachineInfo(
        model: Sysctl.string("hw.model") ?? "Mac",
        cpuBrand: Sysctl.string("machdep.cpu.brand_string") ?? String(localized: "Процессор"),
        physicalCores: Sysctl.int("hw.physicalcpu") ?? 0,
        logicalCores: Sysctl.int("hw.logicalcpu") ?? 0,
        performanceCores: Sysctl.int("hw.perflevel0.physicalcpu"),
        efficiencyCores: Sysctl.int("hw.perflevel1.physicalcpu"),
        memory: UInt64(Sysctl.int("hw.memsize") ?? 0),
        osVersion: {
            let v = ProcessInfo.processInfo.operatingSystemVersion
            let build = Sysctl.string("kern.osversion").map { " (\($0))" } ?? ""
            return "macOS \(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "") + build
        }(),
        hostName: Sysctl.string("kern.hostname") ?? ""
    )
}

final class SystemSampler: @unchecked Sendable {
    private let host = mach_host_self()
    private var prevTicks: [[UInt32]] = []
    private var prevNet: (UInt64, UInt64)?
    private var prevDisk: (UInt64, UInt64)?
    private var lastTime: Double = 0
    private let pageSize: UInt64

    init() {
        var size: vm_size_t = 0
        host_page_size(host, &size)
        pageSize = UInt64(size == 0 ? 16384 : size)
    }

    func sample() -> SystemSnapshot {
        var s = SystemSnapshot()
        let now = MachTime.now()
        let dt = lastTime > 0 ? now - lastTime : 0
        lastTime = now

        sampleCPU(into: &s)
        sampleMemory(into: &s)

        let net = Self.networkBytes()
        s.netInTotal = net.0
        s.netOutTotal = net.1
        if let p = prevNet, dt > 0 {
            s.netIn = net.0 >= p.0 ? Double(net.0 - p.0) / dt : 0
            s.netOut = net.1 >= p.1 ? Double(net.1 - p.1) / dt : 0
        }
        prevNet = net

        let disk = Self.diskBytes()
        s.diskReadTotal = disk.0
        s.diskWriteTotal = disk.1
        if let p = prevDisk, dt > 0 {
            s.diskRead = disk.0 >= p.0 ? Double(disk.0 - p.0) / dt : 0
            s.diskWrite = disk.1 >= p.1 ? Double(disk.1 - p.1) / dt : 0
        }
        prevDisk = disk

        var load = [Double](repeating: 0, count: 3)
        if getloadavg(&load, 3) == 3 { s.loadAverage = load }

        var tv = timeval()
        var tvSize = MemoryLayout<timeval>.size
        if sysctlbyname("kern.boottime", &tv, &tvSize, nil, 0) == 0 {
            s.bootTime = Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6)
        }
        return s
    }

    // MARK: CPU

    private func sampleCPU(into s: inout SystemSnapshot) {
        let ticks = cpuTicks()
        defer { prevTicks = ticks }
        guard prevTicks.count == ticks.count, !ticks.isEmpty else {
            s.perCore = Array(repeating: 0, count: ticks.count)
            return
        }
        var user = 0.0, system = 0.0, total = 0.0
        var perCore: [Double] = []
        for (i, t) in ticks.enumerated() {
            let p = prevTicks[i]
            let u = Double(t[Int(CPU_STATE_USER)] &- p[Int(CPU_STATE_USER)])
                + Double(t[Int(CPU_STATE_NICE)] &- p[Int(CPU_STATE_NICE)])
            let sy = Double(t[Int(CPU_STATE_SYSTEM)] &- p[Int(CPU_STATE_SYSTEM)])
            let idle = Double(t[Int(CPU_STATE_IDLE)] &- p[Int(CPU_STATE_IDLE)])
            let all = u + sy + idle
            perCore.append(all > 0 ? (u + sy) / all * 100 : 0)
            user += u; system += sy; total += all
        }
        s.perCore = perCore
        if total > 0 {
            s.cpuUser = user / total * 100
            s.cpuSystem = system / total * 100
        }
    }

    private func cpuTicks() -> [[UInt32]] {
        var numCPU: natural_t = 0
        var info: processor_info_array_t?
        var count: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &numCPU, &info, &count) == KERN_SUCCESS,
              let info else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(count) * MemoryLayout<integer_t>.stride))
        }
        let states = Int(CPU_STATE_MAX)
        return (0..<Int(numCPU)).map { cpu in
            (0..<states).map { UInt32(bitPattern: info[cpu * states + $0]) }
        }
    }

    // MARK: Memory

    private func sampleMemory(into s: inout SystemSnapshot) {
        s.memTotal = MachineInfo.current.memory
        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        if kr == KERN_SUCCESS {
            let page = pageSize
            let internalPages = UInt64(vm.internal_page_count)
            let purgeable = UInt64(vm.purgeable_count)
            s.memApp = (internalPages > purgeable ? internalPages - purgeable : 0) * page
            s.memWired = UInt64(vm.wire_count) * page
            s.memCompressed = UInt64(vm.compressor_page_count) * page
            s.memCached = (UInt64(vm.external_page_count) + purgeable) * page
            s.memFree = (UInt64(vm.free_count) + UInt64(vm.speculative_count)) * page
        }

        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 {
            s.swapUsed = swap.xsu_used
            s.swapTotal = swap.xsu_total
        }
        s.memPressure = Sysctl.int("kern.memorystatus_vm_pressure_level") ?? 1
    }

    // MARK: Network (64-битные счётчики через NET_RT_IFLIST2)

    static func networkBytes() -> (UInt64, UInt64) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return (0, 0) }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return (0, 0) }

        var inBytes: UInt64 = 0, outBytes: UInt64 = 0
        buf.withUnsafeBytes { raw in
            var offset = 0
            let headerSize = MemoryLayout<if_msghdr>.size
            while offset + headerSize <= len {
                let hdr = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let msgLen = Int(hdr.ifm_msglen)
                if msgLen == 0 { break }
                if Int32(hdr.ifm_type) == RTM_IFINFO2,
                   offset + MemoryLayout<if_msghdr2>.size <= len {
                    let h2 = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    if h2.ifm_flags & IFF_LOOPBACK == 0 {
                        inBytes &+= h2.ifm_data.ifi_ibytes
                        outBytes &+= h2.ifm_data.ifi_obytes
                    }
                }
                offset += msgLen
            }
        }
        return (inBytes, outBytes)
    }

    // MARK: Disk (IOKit, суммарно по всем блочным устройствам)

    static func diskBytes() -> (UInt64, UInt64) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else {
            return (0, 0)
        }
        defer { IOObjectRelease(iterator) }
        var read: UInt64 = 0, written: UInt64 = 0
        while true {
            let entry = IOIteratorNext(iterator)
            if entry == 0 { break }
            defer { IOObjectRelease(entry) }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any],
                  let stats = dict["Statistics"] as? [String: Any] else { continue }
            read &+= (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            written &+= (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
        }
        return (read, written)
    }
}
