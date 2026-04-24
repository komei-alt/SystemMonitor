import SwiftUI

struct MonitorPopoverView: View {
    var stats: SystemStats

    // MARK: - Color Settings

    @AppStorage("cpuColor")         private var cpuColorName     = ThemeColor.blue.rawValue
    @AppStorage("memoryColor")      private var memoryColorName  = ThemeColor.green.rawValue
    @AppStorage("gpuColor")         private var gpuColorName     = ThemeColor.yellow.rawValue
    @AppStorage("networkUpColor")   private var netUpColorName   = ThemeColor.orange.rawValue
    @AppStorage("networkDownColor") private var netDownColorName = ThemeColor.purple.rawValue

    // MARK: - General Settings

    @AppStorage("updateInterval")     private var updateInterval: Double = 2.0
    @AppStorage("speedUnit")          private var speedUnit       = SpeedUnit.megabytes.rawValue
    @AppStorage("menuBarSize")        private var menuBarSize     = MenuBarSize.compact.rawValue
    @AppStorage("showCPU")     private var showCPU     = true
    @AppStorage("showRAM")     private var showRAM     = true
    @AppStorage("showNetwork") private var showNetwork = true
    @AppStorage("showGPU")     private var showGPU     = false
    @AppStorage("popoverWidth")       private var popoverWidth: Double = 360

    // MARK: - State

    @State private var hoveredProcessID: String?
    @State private var showSettings = false
    @State private var showNetworkColorPicker = false

    // MARK: - Computed Colors

    private var cpuColor:     Color { ThemeColor(rawValue: cpuColorName)?.color     ?? .blue }
    private var memColor:     Color { ThemeColor(rawValue: memoryColorName)?.color  ?? .green }
    private var gpuColor:     Color { ThemeColor(rawValue: gpuColorName)?.color     ?? .yellow }
    private var netUpColor:   Color { ThemeColor(rawValue: netUpColorName)?.color   ?? .orange }
    private var netDownColor: Color { ThemeColor(rawValue: netDownColorName)?.color ?? .purple }

    private let intervals: [(String, Double)] = [
        ("1秒", 1), ("2秒", 2), ("3秒", 3), ("5秒", 5), ("10秒", 10)
    ]

    var body: some View {
        ZStack(alignment: .trailing) {
            VStack(spacing: 16) {
                header
                cpuSection
                memorySection
                gpuSection
                topProcessesSection
                networkSection

                if showSettings {
                    settingsPanel
                }

                Divider()
                footer
            }
            .padding(20)
            .frame(width: popoverWidth)

            PopoverResizeHandle(width: $popoverWidth)
        }
        .onAppear {
            stats.setDetailMonitoringEnabled(true)
        }
        .onDisappear {
            stats.setDetailMonitoringEnabled(false)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .font(.title2)
                .foregroundStyle(.primary)
            VStack(alignment: .leading, spacing: 1) {
                Text("ROSCH SystemMonitor")
                    .font(.headline)
                Text("v1.0")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
    }

    // MARK: - CPU

    private var cpuSection: some View {
        MetricCard(
            icon: "cpu",
            title: "CPU",
            value: String(format: "%.1f%%", stats.cpuUsage),
            progress: stats.cpuUsage / 100.0,
            color: cpuColor,
            history: stats.cpuHistory,
            maxValue: 100,
            colorBinding: $cpuColorName
        )
    }

    // MARK: - Memory

    private var memorySection: some View {
        MetricCard(
            icon: "memorychip",
            title: "メモリ",
            value: "\(SystemStats.formatBytes(stats.memoryUsed)) / \(SystemStats.formatBytes(stats.memoryTotal))",
            progress: stats.memoryPercent / 100.0,
            color: memColor,
            history: stats.memoryHistory,
            maxValue: 100,
            colorBinding: $memoryColorName
        )
    }

    // MARK: - GPU

    private var gpuSection: some View {
        MetricCard(
            icon: "bolt.fill",
            title: "GPU",
            value: String(format: "%.1f%%", stats.gpuUsage),
            progress: stats.gpuUsage / 100.0,
            color: gpuColor,
            history: stats.gpuHistory,
            maxValue: 100,
            colorBinding: $gpuColorName
        )
    }

    // MARK: - Top Processes

    private var topProcessesSection: some View {
        HStack(alignment: .top, spacing: 8) {
            processList(
                title: "CPU トップ",
                icon: "flame.fill",
                processes: stats.topCPUProcesses,
                color: cpuColor,
                valueLabel: { String(format: "%.1f%%", $0.cpu) }
            )
            processList(
                title: "メモリ トップ",
                icon: "memorychip.fill",
                processes: stats.topMemoryProcesses,
                color: memColor,
                valueLabel: { SystemStats.formatBytes($0.memory) }
            )
            processList(
                title: "GPU トップ",
                icon: "bolt.fill",
                processes: stats.topGPUProcesses,
                color: gpuColor,
                valueLabel: { proc in
                    proc.cpu > 0.1 ? String(format: "%.1f%%", proc.cpu) : "Active"
                }
            )
        }
    }

    private func processList(
        title: String,
        icon: String,
        processes: [ProcessUsage],
        color: Color,
        valueLabel: @escaping (ProcessUsage) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundStyle(color)
                Text(title)
                    .font(.caption.weight(.semibold))
            }
            if processes.isEmpty {
                Text("--")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                ForEach(Array(processes.enumerated()), id: \.element.id) { i, proc in
                    if proc.name == "その他" {
                        // 「その他」行: バッジなし、控えめなスタイル
                        HStack(spacing: 4) {
                            Text("…")
                                .font(.system(size: 8, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                                .frame(width: 14, height: 14)
                            Text("その他")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 2)
                            Text(valueLabel(proc))
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(color.opacity(0.5))
                        }
                    } else {
                        HStack(spacing: 4) {
                            Text("\(i + 1)")
                                .font(.system(size: 8, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .frame(width: 14, height: 14)
                                .background(color.opacity(i == 0 ? 1.0 : i == 1 ? 0.6 : 0.35), in: Circle())
                            processNameView(proc: proc, color: color)
                            Spacer(minLength: 2)
                            Text(valueLabel(proc))
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(color)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    /// プロセス名 + ホバーツールチップ（型チェック分割用）
    @ViewBuilder
    private func processNameView(proc: ProcessUsage, color: Color) -> some View {
        let isHovered = hoveredProcessID == proc.id
        Text(proc.name)
            .font(.system(size: 10))
            .lineLimit(1)
            .truncationMode(.middle)
            .onHover { inside in
                hoveredProcessID = inside ? proc.id : nil
            }
            .overlay(alignment: .top) {
                if isHovered {
                    tooltipLabel(proc.name)
                }
            }
    }

    private func tooltipLabel(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
            )
            .fixedSize()
            .offset(y: -24)
            .allowsHitTesting(false)
            .zIndex(100)
    }

    // MARK: - Network

    private var networkSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "network")
                    .foregroundStyle(netUpColor)
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showNetworkColorPicker.toggle()
                        }
                    }
                Text("ネットワーク")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }

            if showNetworkColorPicker {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("↑")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(netUpColor)
                            .frame(width: 12)
                        InlineColorPicker(selection: $netUpColorName)
                    }
                    HStack(spacing: 6) {
                        Text("↓")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(netDownColor)
                            .frame(width: 12)
                        InlineColorPicker(selection: $netDownColorName)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            HStack(spacing: 0) {
                speedLabel(
                    icon: "arrow.up.circle.fill",
                    speed: stats.networkUpSpeed,
                    color: netUpColor
                )
                Spacer()
                speedLabel(
                    icon: "arrow.down.circle.fill",
                    speed: stats.networkDownSpeed,
                    color: netDownColor
                )
            }

            VStack(spacing: 6) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(netUpColor)
                        .frame(width: 6, height: 6)
                    Text("アップロード")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                MiniGraphView(data: stats.uploadHistory, color: netUpColor)
                    .frame(height: 32)
            }

            VStack(spacing: 6) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(netDownColor)
                        .frame(width: 6, height: 6)
                    Text("ダウンロード")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                MiniGraphView(data: stats.downloadHistory, color: netDownColor)
                    .frame(height: 32)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }

    private func speedLabel(icon: String, speed: UInt64, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.body)
            Text(SystemStats.formatSpeed(speed, unit: stats.speedUnit))
                .font(.system(.title3, design: .rounded).weight(.medium))
                .monospacedDigit()
        }
    }

    // MARK: - Settings Panel

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("更新間隔")
                    .font(.caption.weight(.medium))
                Spacer()
                Picker("", selection: $updateInterval) {
                    ForEach(intervals, id: \.1) { label, value in
                        Text(label).tag(value)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 240)
            }

            HStack {
                Text("速度の単位")
                    .font(.caption.weight(.medium))
                Spacer()
                Picker("", selection: $speedUnit) {
                    ForEach(SpeedUnit.allCases) { unit in
                        Text(unit.rawValue).tag(unit.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 120)
            }

            HStack {
                Text("メニューバー")
                    .font(.caption.weight(.medium))
                Spacer()
                Picker("", selection: $menuBarSize) {
                    ForEach(MenuBarSize.allCases) { size in
                        Text(size.displayName).tag(size.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(maxWidth: 180)
            }

            HStack(spacing: 12) {
                Toggle("CPU", isOn: $showCPU)
                Toggle("RAM", isOn: $showRAM)
                Toggle("GPU", isOn: $showGPU)
                Toggle("Net", isOn: $showNetwork)
            }
            .font(.caption)
            .toggleStyle(.checkbox)

            LaunchAtLoginToggle()
                .font(.caption)
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showSettings.toggle()
                }
            } label: {
                Image(systemName: showSettings ? "gearshape.fill" : "gearshape")
            }
            .buttonStyle(.plain)
            .foregroundStyle(showSettings ? .primary : .secondary)

            Text("\(Int(stats.displayRefreshInterval))秒ごとに更新")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()

            Text("v1.0")
                .font(.caption2)
                .foregroundStyle(.quaternary)

            Button("終了") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Inline Color Picker

struct InlineColorPicker: View {
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 5) {
            ForEach(ThemeColor.allCases) { theme in
                Circle()
                    .fill(theme.color)
                    .frame(width: 16, height: 16)
                    .overlay(
                        Circle()
                            .strokeBorder(.white.opacity(0.9), lineWidth: 2)
                            .opacity(selection == theme.rawValue ? 1 : 0)
                    )
                    .scaleEffect(selection == theme.rawValue ? 1.15 : 1.0)
                    .animation(.easeInOut(duration: 0.15), value: selection)
                    .onTapGesture { selection = theme.rawValue }
            }
        }
    }
}

// MARK: - Popover Resize Handle

struct PopoverResizeHandle: View {
    @Binding var width: Double
    @State private var dragStartWidth: Double = 0

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 6)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragStartWidth == 0 { dragStartWidth = width }
                        width = min(max(dragStartWidth + value.translation.width, 320), 600)
                    }
                    .onEnded { _ in dragStartWidth = 0 }
            )
    }
}

// MARK: - MetricCard

struct MetricCard: View {
    let icon: String
    let title: String
    let value: String
    let progress: Double
    let color: Color
    let history: [Double]
    var maxValue: Double? = nil
    var colorBinding: Binding<String>? = nil

    @State private var showingColorPicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .onTapGesture {
                        if colorBinding != nil {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showingColorPicker.toggle()
                            }
                        }
                    }
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(value)
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            if showingColorPicker, let binding = colorBinding {
                InlineColorPicker(selection: binding)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            GaugeBar(value: progress, color: color)

            MiniGraphView(data: history, color: color, maxValue: maxValue)
                .frame(height: 36)
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - GaugeBar

struct GaugeBar: View {
    let value: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)

                RoundedRectangle(cornerRadius: 4)
                    .fill(color)
                    .frame(width: geo.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: 8)
        .transaction { transaction in
            transaction.animation = nil
        }
    }
}
