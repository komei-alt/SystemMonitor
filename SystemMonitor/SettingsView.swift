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
