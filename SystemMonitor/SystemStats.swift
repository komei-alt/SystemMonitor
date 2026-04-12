import Foundation
import Observation

// MARK: - プロセス使用量モデル

struct ProcessUsage: Identifiable {
    let id = UUID()
    let name: String
    let cpu: Double      // CPU使用率 (%)
    let memory: UInt64   // メモリ使用量 (bytes)
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

    // MARK: - Top Processes

    var topCPUProcesses: [ProcessUsage] = []
    var topMemoryProcesses: [ProcessUsage] = []

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

    private func updateTopProcesses() {
        // ps で全プロセスの CPU% / RSS(KB) / コマンド名を取得
        guard let output = runPS() else { return }

        struct RawProc {
            let name: String
            let cpu: Double
            let memKB: UInt64
        }

        var procs: [RawProc] = []

        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            // "  3.2  123456 /path/to/Executable" 形式をパース
            let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count >= 3,
                  let cpu = Double(parts[0]),
                  let rss = UInt64(parts[1]) else { continue }

            // パスから実行ファイル名だけ抽出
            let rawName = String(parts[2])
            let displayName = URL(fileURLWithPath: rawName).lastPathComponent

            procs.append(RawProc(name: displayName, cpu: cpu, memKB: rss))
        }

        // CPU使用率 Top 3（0%は除外）
        topCPUProcesses = procs
            .filter { $0.cpu > 0 }
            .sorted { $0.cpu > $1.cpu }
            .prefix(3)
            .map { ProcessUsage(name: $0.name, cpu: $0.cpu, memory: $0.memKB * 1024) }

        // メモリ使用量 Top 3
        topMemoryProcesses = procs
            .sorted { $0.memKB > $1.memKB }
            .prefix(3)
            .map { ProcessUsage(name: $0.name, cpu: $0.cpu, memory: $0.memKB * 1024) }
    }

    /// ps コマンドを実行して stdout を返す
    private func runPS() -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-Ao", "pcpu=,rss=,comm="]

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            // パイプバッファ満杯によるデッドロック防止のため、先にデータを読む
            let fh = pipe.fileHandleForReading
            let data = fh.readDataToEndOfFile()
            try? fh.close()
            proc.waitUntilExit()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }

    // MARK: - Helpers

    private func appendHistory(_ history: inout [Double], value: Double) {
        history.append(value)
        if history.count > 60 {
            history.removeFirst()
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
