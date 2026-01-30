import SwiftUI
import Charts

struct MonitorPopoverView: View {
    var stats: SystemStats

    @AppStorage("cpuColor")         private var cpuColorName     = "blue"
    @AppStorage("memoryColor")      private var memoryColorName  = "green"
    @AppStorage("networkUpColor")   private var netUpColorName   = "orange"
    @AppStorage("networkDownColor") private var netDownColorName = "purple"
    @AppStorage("updateInterval")   private var updateInterval: Double = 2.0

    private var cpuColor:     Color { ThemeColor(rawValue: cpuColorName)?.color     ?? .blue }
    private var memColor:     Color { ThemeColor(rawValue: memoryColorName)?.color  ?? .green }
    private var netUpColor:   Color { ThemeColor(rawValue: netUpColorName)?.color   ?? .orange }
    private var netDownColor: Color { ThemeColor(rawValue: netDownColorName)?.color ?? .purple }

    var body: some View {
        VStack(spacing: 16) {
            header
            cpuSection
            memorySection
            networkSection

            Divider()

            footer
        }
        .padding(20)
        .frame(width: 360)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .font(.title2)
                .foregroundStyle(.primary)
            Text("System Monitor")
                .font(.headline)
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
            maxValue: 100
        )
    }

    // MARK: - Memory

    private var memorySection: some View {
        MetricCard(
            icon: "memorychip",
            title: "Memory",
            value: "\(SystemStats.formatBytes(stats.memoryUsed)) / \(SystemStats.formatBytes(stats.memoryTotal))",
            progress: stats.memoryPercent / 100.0,
            color: memColor,
            history: stats.memoryHistory,
            maxValue: 100
        )
    }

    // MARK: - Network

    private var networkSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "network")
                    .foregroundStyle(netUpColor)
                Text("Network")
                    .font(.subheadline.weight(.semibold))
                Spacer()
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
                    Text("Upload")
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
                    Text("Download")
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

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text("Updates every \(Int(updateInterval))s")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.subheadline)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Text("Quit")
                    .font(.subheadline)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(color)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(value)
                    .font(.system(.body, design: .rounded).weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
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
                    .fill(color.gradient)
                    .frame(width: geo.size.width * min(max(value, 0), 1))
                    .animation(.easeInOut(duration: 0.6), value: value)
            }
        }
        .frame(height: 8)
    }
}
