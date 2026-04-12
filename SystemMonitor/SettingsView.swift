import SwiftUI
import AppKit
import ServiceManagement

// MARK: - Speed Unit

enum SpeedUnit: String, CaseIterable, Identifiable {
    case megabytes = "MB/s"
    case megabits  = "Mb/s"
    var id: String { rawValue }
}

// MARK: - Menu Bar Size

enum MenuBarSize: String, CaseIterable, Identifiable {
    case compact = "compact"
    case medium  = "medium"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .compact: "コンパクト"
        case .medium:  "ミディアム"
        }
    }

    /// ラベル用フォントサイズ
    var fontSize: CGFloat {
        switch self {
        case .compact: 11
        case .medium:  13
        }
    }
}

// MARK: - Theme Color

enum ThemeColor: String, CaseIterable, Identifiable {
    case blue, cyan, indigo, purple, pink, red, orange, yellow, green, mint, teal

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .blue:   .blue
        case .cyan:   .cyan
        case .indigo: .indigo
        case .purple: .purple
        case .pink:   .pink
        case .red:    .red
        case .orange: .orange
        case .yellow: .yellow
        case .green:  .green
        case .mint:   .mint
        case .teal:   .teal
        }
    }

    var displayName: String { rawValue.capitalized }

    var nsColor: NSColor {
        switch self {
        case .blue:   .systemBlue
        case .cyan:   .systemCyan
        case .indigo: .systemIndigo
        case .purple: .systemPurple
        case .pink:   .systemPink
        case .red:    .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green:  .systemGreen
        case .mint:   .systemMint
        case .teal:   .systemTeal
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {

    @AppStorage("updateInterval")   private var updateInterval: Double = 2.0
    @AppStorage("speedUnit")        private var speedUnit       = SpeedUnit.megabytes.rawValue
    @AppStorage("menuBarSize")      private var menuBarSize     = MenuBarSize.compact.rawValue
    @AppStorage("cpuColor")         private var cpuColor        = ThemeColor.blue.rawValue
    @AppStorage("memoryColor")      private var memoryColor     = ThemeColor.green.rawValue
    @AppStorage("networkUpColor")   private var networkUpColor  = ThemeColor.orange.rawValue
    @AppStorage("networkDownColor") private var networkDownColor = ThemeColor.purple.rawValue
    @AppStorage("compactShowCPU")     private var compactShowCPU     = true
    @AppStorage("compactShowRAM")     private var compactShowRAM     = true
    @AppStorage("compactShowNetwork") private var compactShowNetwork = true

    private let intervals: [(String, Double)] = [
        ("1秒", 1), ("2秒", 2), ("3秒", 3), ("5秒", 5), ("10秒", 10)
    ]

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("一般") {
                    Picker("更新間隔", selection: $updateInterval) {
                        ForEach(intervals, id: \.1) { label, value in
                            Text(label).tag(value)
                        }
                    }

                    Picker("速度の単位", selection: $speedUnit) {
                        ForEach(SpeedUnit.allCases) { unit in
                            Text(unit.rawValue).tag(unit.rawValue)
                        }
                    }

                    Picker("メニューバーサイズ", selection: $menuBarSize) {
                        ForEach(MenuBarSize.allCases) { size in
                            Text(size.displayName).tag(size.rawValue)
                        }
                    }

                    LaunchAtLoginToggle()
                }

                if menuBarSize == MenuBarSize.compact.rawValue {
                    Section("コンパクト表示項目") {
                        Toggle("CPU", isOn: $compactShowCPU)
                        Toggle("RAM", isOn: $compactShowRAM)
                        Toggle("ネットワーク", isOn: $compactShowNetwork)
                    }
                }

                Section("カラー") {
                    colorPicker("CPU", selection: $cpuColor)
                    colorPicker("メモリ", selection: $memoryColor)
                    colorPicker("アップロード", selection: $networkUpColor)
                    colorPicker("ダウンロード", selection: $networkDownColor)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            Text("ROSCH SystemMonitor v1.0 \u{00A9} ROSCH, LLC")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 16)
        }
        .frame(width: 380)
        .fixedSize()
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func colorPicker(_ title: String, selection: Binding<String>) -> some View {
        HStack {
            Text(title)
            Spacer()
            HStack(spacing: 6) {
                ForEach(ThemeColor.allCases) { theme in
                    Circle()
                        .fill(theme.color.gradient)
                        .frame(width: 18, height: 18)
                        .overlay(
                            Circle()
                                .strokeBorder(.white.opacity(0.9), lineWidth: 2)
                                .opacity(selection.wrappedValue == theme.rawValue ? 1 : 0)
                        )
                        .shadow(color: selection.wrappedValue == theme.rawValue ? theme.color.opacity(0.5) : .clear, radius: 3)
                        .scaleEffect(selection.wrappedValue == theme.rawValue ? 1.15 : 1.0)
                        .animation(.easeInOut(duration: 0.15), value: selection.wrappedValue)
                        .onTapGesture {
                            selection.wrappedValue = theme.rawValue
                        }
                }
            }
        }
    }
}

// MARK: - Launch at Login

struct LaunchAtLoginToggle: View {
    @State private var isEnabled = SMAppService.mainApp.status == .enabled

    var body: some View {
        Toggle("ログイン時に起動", isOn: $isEnabled)
            .toggleStyle(.switch)
            .tint(.green)
            .onChange(of: isEnabled) { _, newValue in
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    isEnabled = SMAppService.mainApp.status == .enabled
                }
            }
    }
}
