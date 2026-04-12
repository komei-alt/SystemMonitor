import Foundation
import IOKit
import Observation

// MARK: - プロセス使用量モデル

struct ProcessUsage: Identifiable {
    let id: String       // プロセス名ベースの安定ID（SwiftUI差分更新の効率化）
    let name: String
    let cpu: Double      // CPU使用率 (%)
    let memory: UInt64   // メモリ使用量 (bytes)

    init(name: String, cpu: Double, memory: UInt64) {
        self.id = name
        self.name = name
        self.cpu = cpu
        self.memory = memory
    }
}

@Observable
final class SystemStats {

    // MARK: - CPU

    var cpuUsage: Double = 0
    var cpuHistory: [Double] = Array(repeating: 0, count: 60)

    // MARK: - Memory

    var memoryUsed: UInt64 = 0
    var memoryTotal: UInt64 = 0
    var memoryPercent: Double = 0
    var memoryHistory: [Double] = Array(repeating: 0, count: 60)

    // MARK: - Network

    var networkUpSpeed: UInt64 = 0
    var networkDownSpeed: UInt64 = 0
    var uploadHistory: [Double] = Array(repeating: 0, count: 60)
    var downloadHistory: [Double] = Array(repeating: 0, count: 60)

    // MARK: - GPU

    var gpuUsage: Double = 0
    var gpuHistory: [Double] = Array(repeating: 0, count: 60)

    // MARK: - Top Processes

    var topCPUProcesses: [ProcessUsage] = []
    var topMemoryProcesses: [ProcessUsage] = []
    var topGPUProcesses: [ProcessUsage] = []

    // MARK: - Settings (observable)

    var speedUnit: SpeedUnit = .megabytes

    // MARK: - Menu Bar

    var menuBarText: String {
        let cpu = String(format: "CPU %2.0f%%", cpuUsage)
        let mem = String(format: "MEM %2.0f%%", memoryPercent)
        let up  = "↑\(Self.formatSpeed(networkUpSpeed, unit: speedUnit))"
        let dn  = "↓\(Self.formatSpeed(networkDownSpeed, unit: speedUnit))"
        return "\(cpu)  \(mem)  \(up) \(dn)"
    }

    // MARK: - Private State

    private let hostPort = mach_host_self()
    private var timer: Timer?
    private var previousCPUTicks: [(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)] = []
    private var previousProcCPUTimes: [pid_t: UInt64] = [:]
    private var previousNetworkBytes: (sent: UInt64, received: UInt64)?
    private var lastUpdateTime: Date?
    private var currentInterval: Double = 2.0
    private var defaultsObserver: Any?

    // MARK: - Lifecycle

    init() {
        memoryTotal = ProcessInfo.processInfo.physicalMemory
        syncSettings()
        startMonitoring()

        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.syncSettings()
        }
    }

    deinit {
        timer?.invalidate()
        if let observer = defaultsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Settings Sync

    private func syncSettings() {
        // Speed unit
        let unitRaw = UserDefaults.standard.string(forKey: "speedUnit") ?? SpeedUnit.megabytes.rawValue
        speedUnit = SpeedUnit(rawValue: unitRaw) ?? .megabytes

        // Update interval
        let stored = UserDefaults.standard.double(forKey: "updateInterval")
        let newInterval = stored > 0 ? stored : 2.0
        if newInterval != currentInterval {
            currentInterval = newInterval
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: currentInterval, repeats: true) { [weak self] _ in
                self?.update()
            }
            RunLoop.main.add(timer!, forMode: .common)
        }
    }

    // MARK: - Monitoring

    func startMonitoring() {
        timer?.invalidate()
        let stored = UserDefaults.standard.double(forKey: "updateInterval")
        currentInterval = stored > 0 ? stored : 2.0
        timer = Timer.scheduledTimer(withTimeInterval: currentInterval, repeats: true) { [weak self] _ in
            self?.update()
        }
        RunLoop.main.add(timer!, forMode: .common)
        // 初回更新をメインスレッドの次のサイクルに遅延（UI構築をブロックしない）
        DispatchQueue.main.async { [weak self] in
            self?.update()
        }
    }

    private func update() {
        autoreleasepool {
            updateCPU()
            updateMemory()
            updateNetwork()
            updateTopProcesses()
            updateGPUUsage()
            updateTopGPUProcesses()
            lastUpdateTime = Date()
        }
    }

    // MARK: - CPU Monitoring

    private func updateCPU() {
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

        guard result == KERN_SUCCESS, let info = cpuInfo else { return }
        defer {
            let size = vm_size_t(numCPUInfo) * vm_size_t(MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), size)
        }

        var currentTicks: [(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)] = []

        for i in 0..<Int(numCPUs) {
            let offset = i * Int(CPU_STATE_MAX)
            let user   = UInt64(info[offset + Int(CPU_STATE_USER)])
            let system = UInt64(info[offset + Int(CPU_STATE_SYSTEM)])
            let idle   = UInt64(info[offset + Int(CPU_STATE_IDLE)])
            let nice   = UInt64(info[offset + Int(CPU_STATE_NICE)])
            currentTicks.append((user, system, idle, nice))
        }

        if !previousCPUTicks.isEmpty && previousCPUTicks.count == currentTicks.count {
            var totalUsed: UInt64 = 0
            var totalAll: UInt64 = 0

            for i in 0..<currentTicks.count {
                let prev = previousCPUTicks[i]
                let curr = currentTicks[i]

                let userDelta   = curr.user   &- prev.user
                let systemDelta = curr.system &- prev.system
                let idleDelta   = curr.idle   &- prev.idle
                let niceDelta   = curr.nice   &- prev.nice

                let used  = userDelta + systemDelta + niceDelta
                let total = used + idleDelta

                totalUsed += used
                totalAll  += total
            }

            if totalAll > 0 {
                cpuUsage = Double(totalUsed) / Double(totalAll) * 100.0
            }
        }

        previousCPUTicks = currentTicks
        appendHistory(&cpuHistory, value: cpuUsage)
    }

    // MARK: - Memory Monitoring

    private func updateMemory() {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size
        )

        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(hostPort, HOST_VM_INFO64, intPtr, &count)
            }
        }

        guard result == KERN_SUCCESS else { return }

        let pageSize   = UInt64(vm_kernel_page_size)
        let active     = UInt64(stats.active_count) * pageSize
        let wired      = UInt64(stats.wire_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize

        memoryUsed = active + wired + compressed
        if memoryTotal > 0 {
            memoryPercent = Double(memoryUsed) / Double(memoryTotal) * 100.0
        }

        appendHistory(&memoryHistory, value: memoryPercent)
    }

    // MARK: - Network Monitoring

    private func updateNetwork() {
        let current = Self.getNetworkBytes()

        if let previous = previousNetworkBytes, let lastTime = lastUpdateTime {
            let elapsed = Date().timeIntervalSince(lastTime)
            if elapsed > 0.1 {
                // カウンター減少時はラップアラウンドとみなしスキップ
                let sentDelta = current.sent >= previous.sent
                    ? current.sent - previous.sent : 0
                let receivedDelta = current.received >= previous.received
                    ? current.received - previous.received : 0

                let upSpeed   = UInt64(Double(sentDelta) / elapsed)
                let downSpeed = UInt64(Double(receivedDelta) / elapsed)

                // 10Gbps (1.25GB/s) を上限とし、異常値を除外
                let maxSpeed: UInt64 = 1_250_000_000
                networkUpSpeed   = min(upSpeed, maxSpeed)
                networkDownSpeed = min(downSpeed, maxSpeed)
            }
        }

        previousNetworkBytes = current

        appendHistory(&uploadHistory,   value: Double(networkUpSpeed))
        appendHistory(&downloadHistory, value: Double(networkDownSpeed))
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
                if !name.hasPrefix("lo") {
                    if let data = entry.ifa_data {
                        let networkData = data.assumingMemoryBound(to: if_data.self).pointee
                        totalSent     += UInt64(networkData.ifi_obytes)
                        totalReceived += UInt64(networkData.ifi_ibytes)
                    }
                }
            }

            ptr = entry.ifa_next
        }

        return (totalSent, totalReceived)
    }

    // MARK: - Top Processes Monitoring

    /// libproc API でプロセス情報を取得（メモリ効率最適化: Top N のみ保持）
    private func updateTopProcesses() {
        autoreleasepool {
            // 全PIDを取得（スタック上の固定バッファ）
            let maxPids = 2048
            let pids = UnsafeMutablePointer<pid_t>.allocate(capacity: maxPids)
            defer { pids.deallocate() }

            let byteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, pids,
                                           Int32(maxPids * MemoryLayout<pid_t>.size))
            guard byteCount > 0 else { return }
            let pidCount = Int(byteCount) / MemoryLayout<pid_t>.size

            let taskInfoSize = Int32(MemoryLayout<proc_taskinfo>.size)
            let nameBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: 256)
            defer { nameBuffer.deallocate() }

            // Top 3 のみ保持するヒープ（全スナップショット配列を回避）
            var cpuTop3: [(pid: pid_t, name: String, pct: Double, rss: UInt64)] = []
            var memTop3: [(name: String, rss: UInt64)] = []
            var newCPUTimes: [pid_t: UInt64] = Dictionary(minimumCapacity: pidCount)

            let elapsed = lastUpdateTime.map { Date().timeIntervalSince($0) } ?? currentInterval
            let elapsedNs = max(UInt64(elapsed * 1_000_000_000), 1)

            for i in 0..<pidCount {
                let pid = pids[i]
                guard pid > 0 else { continue }

                var info = proc_taskinfo()
                guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, taskInfoSize) == taskInfoSize else { continue }

                let cpuTime = info.pti_total_user + info.pti_total_system
                newCPUTimes[pid] = cpuTime

                // プロセス名は Top 候補の場合のみ取得（システムコール削減）
                let rss = info.pti_resident_size
                var cpuPct = 0.0

                if let prev = previousProcCPUTimes[pid], cpuTime > prev {
                    cpuPct = Double(cpuTime - prev) / Double(elapsedNs) * 100.0
                }

                let isTopCPU = cpuPct > 0.1 && (cpuTop3.count < 3 || cpuPct > (cpuTop3.last?.pct ?? 0))
                let isTopMem = memTop3.count < 3 || rss > (memTop3.last?.rss ?? 0)

                if isTopCPU || isTopMem {
                    proc_name(pid, nameBuffer, 256)
                    let name = String(cString: nameBuffer)
                    guard !name.isEmpty else { continue }

                    if isTopCPU {
                        cpuTop3.append((pid, name, cpuPct, rss))
                        cpuTop3.sort { $0.pct > $1.pct }
                        if cpuTop3.count > 3 { cpuTop3.removeLast() }
                    }
                    if isTopMem {
                        memTop3.append((name, rss))
                        memTop3.sort { $0.rss > $1.rss }
                        if memTop3.count > 3 { memTop3.removeLast() }
                    }
                }
            }

            previousProcCPUTimes = newCPUTimes

            topCPUProcesses = cpuTop3.map {
                ProcessUsage(name: $0.name, cpu: $0.pct, memory: $0.rss)
            }
            topMemoryProcesses = memTop3.map {
                ProcessUsage(name: $0.name, cpu: 0, memory: $0.rss)
            }
        }
    }

    // MARK: - GPU Monitoring

    /// GPU使用率を IOAccelerator の PerformanceStatistics から取得
    /// CFDictionary を Swift Dictionary にコピーせず、キー単位で直接参照
    private func updateGPUUsage() {
        guard let matching = IOServiceMatching("IOAccelerator") else { return }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            if let perfRef = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0) {
                let cfDict = perfRef.takeRetainedValue() as! CFDictionary
                // CFDictionary から個別キーを直接取得（Swift Dict 変換を回避）
                func readInt(_ key: String) -> Int? {
                    var value: UnsafeRawPointer?
                    let cfKey = key as CFString
                    guard CFDictionaryGetValueIfPresent(cfDict, Unmanaged.passUnretained(cfKey).toOpaque(), &value),
                          let raw = value else { return nil }
                    return (raw.load(as: Unmanaged<NSNumber>.self).takeUnretainedValue()).intValue
                }
                if let util = readInt("Device Utilization %") {
                    gpuUsage = Double(util)
                } else if let util = readInt("GPU Activity(%)") {
                    gpuUsage = Double(util)
                } else if let util = readInt("gpuCoreUtilizationComponent") {
                    gpuUsage = min(Double(util) / 10_000_000.0 * 100.0, 100.0)
                }
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        appendHistory(&gpuHistory, value: gpuUsage)
    }

    /// GPUクライアント（プロセス）を IOGPUDevice の直接子から取得（depth 1のみ）
    private func updateTopGPUProcesses() {
        var pidInfo: [pid_t: (name: String, clientCount: Int)] = [:]

        guard let matching = IOServiceMatching("IOGPUDevice") else {
            topGPUProcesses = []
            return
        }

        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            topGPUProcesses = []
            return
        }
        defer { IOObjectRelease(iterator) }

        var device = IOIteratorNext(iterator)
        while device != 0 {
            // 直接子のみ（再帰なし）
            var childIter: io_iterator_t = 0
            if IORegistryEntryGetChildIterator(device, kIOServicePlane, &childIter) == KERN_SUCCESS {
                var child = IOIteratorNext(childIter)
                while child != 0 {
                    if let ref = IORegistryEntryCreateCFProperty(child, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0) {
                        let creator = ref.takeRetainedValue() as! String
                        let comps = creator.split(separator: ",", maxSplits: 1)
                        if comps.count >= 2,
                           let pidStr = comps[0].split(separator: " ").last,
                           let pid = pid_t(pidStr) {
                            let name = String(comps[1]).trimmingCharacters(in: .whitespaces)
                            var info = pidInfo[pid] ?? (name: name, clientCount: 0)
                            info.clientCount += 1
                            pidInfo[pid] = info
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

        let selfPID = ProcessInfo.processInfo.processIdentifier

        topGPUProcesses = pidInfo
            .filter { $0.key > 0 && $0.key != selfPID }
            .sorted { $0.value.clientCount > $1.value.clientCount }
            .prefix(3)
            .map { ProcessUsage(name: $0.value.name, cpu: 0, memory: 0) }
    }

    // MARK: - Helpers

    /// 固定長60の履歴に追加（末尾上書き + 先頭シフトで O(1) 書き込み）
    private func appendHistory(_ history: inout [Double], value: Double) {
        if history.count >= 60 {
            history.replaceSubrange(0..<59, with: history[1..<60])
            history[59] = value
        } else {
            history.append(value)
        }
    }

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
        let fig = "\u{2007}" // figure space（monospacedDigit で数字と同幅）
        switch unit {
        case .megabytes:
            let mb = Double(bytesPerSec) / 1_000_000
            return String(format: "%5.1f", mb)
                .replacingOccurrences(of: " ", with: fig) + "MB"
        case .megabits:
            let mbps = Double(bytesPerSec) * 8 / 1_000_000
            return String(format: "%6.1f", mbps)
                .replacingOccurrences(of: " ", with: fig) + "Mb"
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
