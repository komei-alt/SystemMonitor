import Foundation
import IOKit
import Observation

// MARK: - Process Usage Model

struct ProcessUsage: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let cpu: Double
    let memory: UInt64

    init(name: String, cpu: Double, memory: UInt64) {
        self.id = name
        self.name = name
        self.cpu = cpu
        self.memory = memory
    }
}

// MARK: - Snapshot

private struct MonitoringOptions: Sendable {
    let includeGPU: Bool
    let includeProcessDetails: Bool
}

private struct MonitoringSnapshot: Sendable {
    var cpuUsage: Double
    var cpuHistory: [Double]
    var memoryUsed: UInt64
    var memoryTotal: UInt64
    var memoryPercent: Double
    var memoryHistory: [Double]
    var networkUpSpeed: UInt64
    var networkDownSpeed: UInt64
    var uploadHistory: [Double]
    var downloadHistory: [Double]
    var gpuUsage: Double
    var gpuHistory: [Double]
    var topCPUProcesses: [ProcessUsage]
    var topMemoryProcesses: [ProcessUsage]
    var topGPUProcesses: [ProcessUsage]

    init(memoryTotal: UInt64) {
        cpuUsage = 0
        cpuHistory = Array(repeating: 0, count: 60)
        memoryUsed = 0
        self.memoryTotal = memoryTotal
        memoryPercent = 0
        memoryHistory = Array(repeating: 0, count: 60)
        networkUpSpeed = 0
        networkDownSpeed = 0
        uploadHistory = Array(repeating: 0, count: 60)
        downloadHistory = Array(repeating: 0, count: 60)
        gpuUsage = 0
        gpuHistory = Array(repeating: 0, count: 60)
        topCPUProcesses = []
        topMemoryProcesses = []
        topGPUProcesses = []
    }
}

// MARK: - Background Sampler

private actor SystemSampler {
    private let hostPort = mach_host_self()
    private let logicalCPUCount = ProcessInfo.processInfo.processorCount

    private var snapshot: MonitoringSnapshot
    private var previousCPUTicks: [(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)] = []
    private var previousProcCPUTimes: [pid_t: UInt64] = [:]
    private var previousGPUTimes: [pid_t: UInt64] = [:]
    private var previousNetworkBytes: (sent: UInt64, received: UInt64)?
    private var lastUpdateTime: Date?
    private var lastGPUUpdateTime: Date?
    private let minimumGPUUpdateInterval: TimeInterval = 5.0

    init(memoryTotal: UInt64) {
        snapshot = MonitoringSnapshot(memoryTotal: memoryTotal)
    }

    func captureSample(intervalHint: Double, options: MonitoringOptions) -> MonitoringSnapshot {
        autoreleasepool {
            let now = Date()
            let elapsed = max(lastUpdateTime.map { now.timeIntervalSince($0) } ?? intervalHint, 0.1)

            snapshot.cpuUsage = updateCPU()
            appendHistory(&snapshot.cpuHistory, value: snapshot.cpuUsage)

            let memory = updateMemory()
            snapshot.memoryUsed = memory.used
            snapshot.memoryPercent = memory.percent
            appendHistory(&snapshot.memoryHistory, value: snapshot.memoryPercent)

            let network = updateNetwork(elapsed: elapsed)
            snapshot.networkUpSpeed = network.up
            snapshot.networkDownSpeed = network.down
            appendHistory(&snapshot.uploadHistory, value: Double(snapshot.networkUpSpeed))
            appendHistory(&snapshot.downloadHistory, value: Double(snapshot.networkDownSpeed))

            let shouldUpdateGPU = options.includeGPU && shouldRefreshGPU(now: now)
            let gpuElapsed = max(lastGPUUpdateTime.map { now.timeIntervalSince($0) } ?? intervalHint, 0.1)

            if shouldUpdateGPU {
                snapshot.gpuUsage = updateGPUUsage()
                appendHistory(&snapshot.gpuHistory, value: snapshot.gpuUsage)
            }

            if options.includeProcessDetails {
                let processes = updateTopProcesses(
                    elapsed: elapsed,
                    totalCPUUsage: snapshot.cpuUsage,
                    memoryUsed: snapshot.memoryUsed
                )
                snapshot.topCPUProcesses = processes.cpu
                snapshot.topMemoryProcesses = processes.memory
                snapshot.topGPUProcesses = shouldUpdateGPU
                    ? updateTopGPUProcesses(elapsed: gpuElapsed)
                    : (options.includeGPU ? snapshot.topGPUProcesses : [])
            } else {
                snapshot.topCPUProcesses = []
                snapshot.topMemoryProcesses = []
                snapshot.topGPUProcesses = []
                previousProcCPUTimes.removeAll(keepingCapacity: true)
                previousGPUTimes.removeAll(keepingCapacity: true)
            }

            if !options.includeGPU {
                previousGPUTimes.removeAll(keepingCapacity: true)
                lastGPUUpdateTime = nil
            } else if shouldUpdateGPU {
                lastGPUUpdateTime = now
            }

            lastUpdateTime = now
            return snapshot
        }
    }

    private func shouldRefreshGPU(now: Date) -> Bool {
        guard let lastGPUUpdateTime else { return true }
        return now.timeIntervalSince(lastGPUUpdateTime) >= minimumGPUUpdateInterval
    }

    // MARK: - CPU Monitoring

    private func updateCPU() -> Double {
        var numCPUs: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var numCPUInfo: mach_msg_type_number_t = 0

        let result = host_processor_info(
            hostPort,
            PROCESSOR_CPU_LOAD_INFO,
            &numCPUs,
            &cpuInfo,
            &numCPUInfo
        )

        guard result == KERN_SUCCESS, let info = cpuInfo else { return snapshot.cpuUsage }
        defer {
            let size = vm_size_t(numCPUInfo) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), size)
        }

        var currentTicks: [(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)] = []
        currentTicks.reserveCapacity(Int(numCPUs))

        for i in 0..<Int(numCPUs) {
            let offset = i * Int(CPU_STATE_MAX)
            let user = UInt64(info[offset + Int(CPU_STATE_USER)])
            let system = UInt64(info[offset + Int(CPU_STATE_SYSTEM)])
            let idle = UInt64(info[offset + Int(CPU_STATE_IDLE)])
            let nice = UInt64(info[offset + Int(CPU_STATE_NICE)])
            currentTicks.append((user, system, idle, nice))
        }

        defer { previousCPUTicks = currentTicks }

        guard !previousCPUTicks.isEmpty, previousCPUTicks.count == currentTicks.count else {
            return snapshot.cpuUsage
        }

        var totalUsed: UInt64 = 0
        var totalAll: UInt64 = 0

        for i in 0..<currentTicks.count {
            let prev = previousCPUTicks[i]
            let curr = currentTicks[i]

            let userDelta = curr.user &- prev.user
            let systemDelta = curr.system &- prev.system
            let idleDelta = curr.idle &- prev.idle
            let niceDelta = curr.nice &- prev.nice

            let used = userDelta + systemDelta + niceDelta
            let total = used + idleDelta

            totalUsed += used
            totalAll += total
        }

        guard totalAll > 0 else { return snapshot.cpuUsage }
        return Double(totalUsed) / Double(totalAll) * 100.0
    }

    // MARK: - Memory Monitoring

    private func updateMemory() -> (used: UInt64, percent: Double) {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size
        )

        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(hostPort, HOST_VM_INFO64, intPtr, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            return (snapshot.memoryUsed, snapshot.memoryPercent)
        }

        let pageSize = UInt64(vm_kernel_page_size)
        let active = UInt64(stats.active_count) * pageSize
        let wired = UInt64(stats.wire_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize

        let used = active + wired + compressed
        let percent = snapshot.memoryTotal > 0
            ? Double(used) / Double(snapshot.memoryTotal) * 100.0
            : 0

        return (used, percent)
    }

    // MARK: - Network Monitoring

    private func updateNetwork(elapsed: TimeInterval) -> (up: UInt64, down: UInt64) {
        let current = Self.getNetworkBytes()
        defer { previousNetworkBytes = current }

        guard let previous = previousNetworkBytes, elapsed > 0.1 else {
            return (snapshot.networkUpSpeed, snapshot.networkDownSpeed)
        }

        let sentDelta = current.sent >= previous.sent ? current.sent - previous.sent : 0
        let receivedDelta = current.received >= previous.received ? current.received - previous.received : 0

        let upSpeed = UInt64(Double(sentDelta) / elapsed)
        let downSpeed = UInt64(Double(receivedDelta) / elapsed)
        let maxSpeed: UInt64 = 1_250_000_000

        return (min(upSpeed, maxSpeed), min(downSpeed, maxSpeed))
    }

    private static func getNetworkBytes() -> (sent: UInt64, received: UInt64) {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return (0, 0) }
        defer { freeifaddrs(ifaddr) }

        var totalSent: UInt64 = 0
        var totalReceived: UInt64 = 0

        var ptr = ifaddr
        while let interface = ptr {
            let entry = interface.pointee

            if let addrPtr = entry.ifa_addr,
               addrPtr.pointee.sa_family == UInt8(AF_LINK) {
                let name = String(cString: entry.ifa_name)
                if !name.hasPrefix("lo"), let data = entry.ifa_data {
                    let networkData = data.assumingMemoryBound(to: if_data.self).pointee
                    totalSent += UInt64(networkData.ifi_obytes)
                    totalReceived += UInt64(networkData.ifi_ibytes)
                }
            }

            ptr = entry.ifa_next
        }

        return (totalSent, totalReceived)
    }

    // MARK: - Top Processes Monitoring

    private func updateTopProcesses(
        elapsed: TimeInterval,
        totalCPUUsage: Double,
        memoryUsed: UInt64
    ) -> (cpu: [ProcessUsage], memory: [ProcessUsage]) {
        autoreleasepool {
            let maxPids = 2048
            let pids = UnsafeMutablePointer<pid_t>.allocate(capacity: maxPids)
            defer { pids.deallocate() }

            let byteCount = proc_listpids(
                UInt32(PROC_ALL_PIDS),
                0,
                pids,
                Int32(maxPids * MemoryLayout<pid_t>.size)
            )
            guard byteCount > 0 else {
                return (snapshot.topCPUProcesses, snapshot.topMemoryProcesses)
            }

            let pidCount = Int(byteCount) / MemoryLayout<pid_t>.size
            let taskInfoSize = Int32(MemoryLayout<proc_taskinfo>.size)
            let nameBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: 256)
            defer { nameBuffer.deallocate() }

            var cpuTop3: [(pid: pid_t, name: String, pct: Double, rss: UInt64)] = []
            var memTop3: [(name: String, rss: UInt64)] = []
            var newCPUTimes: [pid_t: UInt64] = Dictionary(minimumCapacity: pidCount)

            let elapsedNs = max(UInt64(elapsed * 1_000_000_000), 1)

            for i in 0..<pidCount {
                let pid = pids[i]
                guard pid > 0 else { continue }

                var info = proc_taskinfo()
                guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, taskInfoSize) == taskInfoSize else {
                    continue
                }

                let cpuTime = info.pti_total_user + info.pti_total_system
                newCPUTimes[pid] = cpuTime

                let rss = info.pti_resident_size
                var cpuPct = 0.0

                if let prev = previousProcCPUTimes[pid], cpuTime > prev {
                    cpuPct = Double(cpuTime - prev) / Double(elapsedNs) * 100.0
                }

                let isTopCPU = cpuPct > 0.1 && (cpuTop3.count < 3 || cpuPct > (cpuTop3.last?.pct ?? 0))
                let isTopMem = memTop3.count < 3 || rss > (memTop3.last?.rss ?? 0)

                guard isTopCPU || isTopMem else { continue }

                proc_name(pid, nameBuffer, 256)
                let name = String(cString: nameBuffer)
                guard !name.isEmpty else { continue }

                if isTopCPU {
                    cpuTop3.append((pid, name, cpuPct, rss))
                    cpuTop3.sort { $0.pct > $1.pct }
                    if cpuTop3.count > 3 {
                        cpuTop3.removeLast()
                    }
                }

                if isTopMem {
                    memTop3.append((name, rss))
                    memTop3.sort { $0.rss > $1.rss }
                    if memTop3.count > 3 {
                        memTop3.removeLast()
                    }
                }
            }

            previousProcCPUTimes = newCPUTimes

            let cores = max(Double(logicalCPUCount), 1)
            let top3CPUSum = cpuTop3.reduce(0.0) { $0 + $1.pct }
            let normalizedTop3CPU = top3CPUSum / cores
            let otherCPU = max(totalCPUUsage - normalizedTop3CPU, 0)

            var cpuProcesses = cpuTop3.map {
                ProcessUsage(name: $0.name, cpu: $0.pct / cores, memory: $0.rss)
            }
            if otherCPU > 0.1 {
                cpuProcesses.append(ProcessUsage(name: "その他", cpu: otherCPU, memory: 0))
            }

            let top3MemSum = memTop3.reduce(UInt64(0)) { $0 + $1.rss }
            let otherMem = memoryUsed > top3MemSum ? memoryUsed - top3MemSum : 0

            var memoryProcesses = memTop3.map {
                ProcessUsage(name: $0.name, cpu: 0, memory: $0.rss)
            }
            if otherMem > 0 {
                memoryProcesses.append(ProcessUsage(name: "その他", cpu: 0, memory: otherMem))
            }

            return (cpuProcesses, memoryProcesses)
        }
    }

    // MARK: - GPU Monitoring

    private func updateGPUUsage() -> Double {
        guard let matching = IOServiceMatching("IOAccelerator") else { return snapshot.gpuUsage }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return snapshot.gpuUsage
        }
        defer { IOObjectRelease(iterator) }

        var result = snapshot.gpuUsage
        var service = IOIteratorNext(iterator)

        while service != 0 {
            if let perfRef = IORegistryEntryCreateCFProperty(
                service,
                "PerformanceStatistics" as CFString,
                kCFAllocatorDefault,
                0
            ) {
                let cfDict = perfRef.takeRetainedValue() as! CFDictionary

                func readInt(_ key: String) -> Int? {
                    let cfKey = key as CFString
                    guard let raw = CFDictionaryGetValue(
                        cfDict,
                        Unmanaged.passUnretained(cfKey).toOpaque()
                    ) else {
                        return nil
                    }
                    return Unmanaged<NSNumber>.fromOpaque(raw).takeUnretainedValue().intValue
                }

                if let util = readInt("Device Utilization %") {
                    result = Double(util)
                } else if let util = readInt("GPU Activity(%)") {
                    result = Double(util)
                } else if let util = readInt("gpuCoreUtilizationComponent") {
                    result = min(Double(util) / 10_000_000.0 * 100.0, 100.0)
                }
            }

            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }

        return result
    }

    private func updateTopGPUProcesses(elapsed: TimeInterval) -> [ProcessUsage] {
        var pidInfo: [pid_t: (name: String, gpuTime: UInt64)] = [:]
        let elapsedNs = max(UInt64(elapsed * 1_000_000_000), 1)

        let classNames = ["IOAccelerator", "IOGPUDevice"]
        for className in classNames {
            guard let matching = IOServiceMatching(className) else { continue }

            var iterator: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
                continue
            }
            defer { IOObjectRelease(iterator) }

            var device = IOIteratorNext(iterator)
            while device != 0 {
                var childIter: io_iterator_t = 0
                if IORegistryEntryGetChildIterator(device, kIOServicePlane, &childIter) == KERN_SUCCESS {
                    var child = IOIteratorNext(childIter)
                    while child != 0 {
                        if let creatorRef = IORegistryEntryCreateCFProperty(
                            child,
                            "IOUserClientCreator" as CFString,
                            kCFAllocatorDefault,
                            0
                        ) {
                            let creator = creatorRef.takeRetainedValue() as! String
                            let comps = creator.split(separator: ",", maxSplits: 1)
                            if comps.count >= 2,
                               let pidStr = comps[0].split(separator: " ").last,
                               let pid = pid_t(pidStr) {
                                let name = String(comps[1]).trimmingCharacters(in: .whitespaces)

                                var clientGPUTime: UInt64 = 0
                                if let usageRef = IORegistryEntryCreateCFProperty(
                                    child,
                                    "AppUsage" as CFString,
                                    kCFAllocatorDefault,
                                    0
                                ) {
                                    if let usageArray = usageRef.takeRetainedValue() as? [[String: Any]] {
                                        for entry in usageArray {
                                            if let t = entry["accumulatedGPUTime"] as? UInt64 {
                                                clientGPUTime += t
                                            } else if let t = entry["accumulatedGPUTime"] as? Int64, t > 0 {
                                                clientGPUTime += UInt64(t)
                                            }
                                        }
                                    }
                                }

                                var existing = pidInfo[pid] ?? (name: name, gpuTime: 0)
                                existing.gpuTime += clientGPUTime
                                pidInfo[pid] = existing
                            }
                        }

                        IOObjectRelease(child)
                        child = IOIteratorNext(childIter)
                    }
                    IOObjectRelease(childIter)
                }

                IOObjectRelease(device)
                device = IOIteratorNext(iterator)
            }

            if !pidInfo.isEmpty {
                break
            }
        }

        let selfPID = ProcessInfo.processInfo.processIdentifier
        var gpuProcesses: [(name: String, gpuPct: Double)] = []
        var newGPUTimes: [pid_t: UInt64] = [:]

        for (pid, info) in pidInfo where pid > 0 && pid != selfPID {
            newGPUTimes[pid] = info.gpuTime
            var gpuPct = 0.0
            if let prev = previousGPUTimes[pid], info.gpuTime > prev {
                gpuPct = Double(info.gpuTime - prev) / Double(elapsedNs) * 100.0
            }
            gpuProcesses.append((name: info.name, gpuPct: gpuPct))
        }

        previousGPUTimes = newGPUTimes

        return gpuProcesses
            .sorted { $0.gpuPct > $1.gpuPct }
            .prefix(3)
            .map { ProcessUsage(name: $0.name, cpu: $0.gpuPct, memory: 0) }
    }

    // MARK: - Helpers

    private func appendHistory(_ history: inout [Double], value: Double) {
        if history.count >= 60 {
            history.removeFirst()
        }
        history.append(value)
    }
}

// MARK: - Observable UI Model

@MainActor
@Observable
final class SystemStats {
    private var snapshot: MonitoringSnapshot
    var speedUnit: SpeedUnit = .megabytes

    @ObservationIgnored private let sampler: SystemSampler
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var defaultsObserver: NSObjectProtocol?
    @ObservationIgnored private var currentInterval: Double = 2.0
    @ObservationIgnored private var detailMonitoringEnabled = false
    @ObservationIgnored private var showGPUInMenuBar = false
    @ObservationIgnored private let minimumDetailRefreshInterval = 2.0
    @ObservationIgnored private let detailWarmupDelay: UInt64 = 1_200_000_000

    // MARK: - CPU

    var cpuUsage: Double { snapshot.cpuUsage }
    var cpuHistory: [Double] { snapshot.cpuHistory }

    // MARK: - Memory

    var memoryUsed: UInt64 { snapshot.memoryUsed }
    var memoryTotal: UInt64 { snapshot.memoryTotal }
    var memoryPercent: Double { snapshot.memoryPercent }
    var memoryHistory: [Double] { snapshot.memoryHistory }

    // MARK: - Network

    var networkUpSpeed: UInt64 { snapshot.networkUpSpeed }
    var networkDownSpeed: UInt64 { snapshot.networkDownSpeed }
    var uploadHistory: [Double] { snapshot.uploadHistory }
    var downloadHistory: [Double] { snapshot.downloadHistory }

    // MARK: - GPU

    var gpuUsage: Double { snapshot.gpuUsage }
    var gpuHistory: [Double] { snapshot.gpuHistory }

    // MARK: - Top Processes

    var topCPUProcesses: [ProcessUsage] { snapshot.topCPUProcesses }
    var topMemoryProcesses: [ProcessUsage] { snapshot.topMemoryProcesses }
    var topGPUProcesses: [ProcessUsage] { snapshot.topGPUProcesses }

    // MARK: - Menu Bar

    var menuBarText: String {
        let cpu = String(format: "CPU %2.0f%%", cpuUsage)
        let mem = String(format: "MEM %2.0f%%", memoryPercent)
        let up = "↑\(Self.formatSpeed(networkUpSpeed, unit: speedUnit))"
        let dn = "↓\(Self.formatSpeed(networkDownSpeed, unit: speedUnit))"
        return "\(cpu)  \(mem)  \(up) \(dn)"
    }

    var displayRefreshInterval: Double {
        effectiveRefreshInterval
    }

    // MARK: - Lifecycle

    init() {
        let memoryTotal = ProcessInfo.processInfo.physicalMemory
        snapshot = MonitoringSnapshot(memoryTotal: memoryTotal)
        sampler = SystemSampler(memoryTotal: memoryTotal)

        syncSettings()
        startMonitoring()

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncSettings()
            }
        }
    }

    deinit {
        refreshTask?.cancel()
        if let observer = defaultsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Visibility

    func setDetailMonitoringEnabled(_ enabled: Bool) {
        guard detailMonitoringEnabled != enabled else { return }

        detailMonitoringEnabled = enabled
        if enabled {
            scheduleImmediateRefresh(withFollowUp: true)
        }
    }

    // MARK: - Settings Sync

    private func syncSettings() {
        let unitRaw = UserDefaults.standard.string(forKey: "speedUnit") ?? SpeedUnit.megabytes.rawValue
        let newSpeedUnit = SpeedUnit(rawValue: unitRaw) ?? .megabytes
        let newShowGPU = UserDefaults.standard.bool(forKey: "showGPU")

        let storedInterval = UserDefaults.standard.double(forKey: "updateInterval")
        let newInterval = storedInterval > 0 ? storedInterval : 2.0

        let intervalChanged = newInterval != currentInterval
        let gpuVisibilityChanged = newShowGPU != showGPUInMenuBar

        if speedUnit != newSpeedUnit {
            speedUnit = newSpeedUnit
        }
        showGPUInMenuBar = newShowGPU
        currentInterval = newInterval

        if intervalChanged {
            startMonitoring()
        } else if gpuVisibilityChanged {
            scheduleImmediateRefresh(withFollowUp: detailMonitoringEnabled)
        }
    }

    // MARK: - Monitoring

    private var samplingOptions: MonitoringOptions {
        MonitoringOptions(
            includeGPU: detailMonitoringEnabled || showGPUInMenuBar,
            includeProcessDetails: detailMonitoringEnabled
        )
    }

    private var effectiveRefreshInterval: Double {
        detailMonitoringEnabled
            ? max(currentInterval, minimumDetailRefreshInterval)
            : currentInterval
    }

    private func startMonitoring() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.runRefreshLoop()
        }
        scheduleImmediateRefresh(withFollowUp: detailMonitoringEnabled)
    }

    private func runRefreshLoop() async {
        while !Task.isCancelled {
            let sleepNs = max(UInt64(effectiveRefreshInterval * 1_000_000_000), 100_000_000)
            do {
                try await Task.sleep(nanoseconds: sleepNs)
            } catch {
                break
            }

            if Task.isCancelled {
                break
            }

            await refreshNow()
        }
    }

    private func scheduleImmediateRefresh(withFollowUp: Bool = false) {
        Task { [weak self] in
            guard let self else { return }
            await self.refreshNow()

            guard withFollowUp else { return }
            try? await Task.sleep(nanoseconds: self.detailWarmupDelay)
            guard !Task.isCancelled, self.detailMonitoringEnabled else { return }
            await self.refreshNow()
        }
    }

    private func refreshNow() async {
        snapshot = await sampler.captureSample(
            intervalHint: effectiveRefreshInterval,
            options: samplingOptions
        )
    }

    // MARK: - Format Helpers

    static func formatSpeedAuto(_ bytesPerSec: UInt64) -> String {
        let b = Double(bytesPerSec)
        if b < 1_000 {
            return String(format: "%.0f B/s", b)
        } else if b < 1_000_000 {
            let kb = b / 1_000
            return String(format: kb >= 10 ? "%.0f KB/s" : "%.1f KB/s", kb)
        } else {
            let mb = b / 1_000_000
            return String(format: mb >= 10 ? "%.0f MB/s" : "%.1f MB/s", mb)
        }
    }

    static func formatSpeed(_ bytesPerSec: UInt64, unit: SpeedUnit = .megabytes) -> String {
        switch unit {
        case .megabytes:
            let mb = Double(bytesPerSec) / 1_000_000
            if mb >= 100 {
                return String(format: "%.0fMB", mb)
            }
            return String(format: "%.1fMB", mb)
        case .megabits:
            let mbps = Double(bytesPerSec) * 8 / 1_000_000
            if mbps >= 100 {
                return String(format: "%.0fMb", mbps)
            }
            return String(format: "%.1fMb", mbps)
        }
    }

    static func formatBytes(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1.0 {
            return String(format: "%.1f GB", gb)
        }

        let mb = Double(bytes) / 1_048_576
        return String(format: "%.0f MB", mb)
    }
}
