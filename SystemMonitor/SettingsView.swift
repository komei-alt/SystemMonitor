import SwiftUI

// MARK: - Speed Unit

enum SpeedUnit: String, CaseIterable, Identifiable {
    case megabytes = "MB/s"
    case megabits  = "Mb/s"
    var id: String { rawValue }
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
}

// MARK: - Settings View

struct SettingsView: View {

    @AppStorage("updateInterval")   private var updateInterval: Double = 2.0
    @AppStorage("speedUnit")        private var speedUnit       = SpeedUnit.megabytes.rawValue
    @AppStorage("cpuColor")         private var cpuColor        = ThemeColor.blue.rawValue
    @AppStorage("memoryColor")      private var memoryColor     = ThemeColor.green.rawValue
    @AppStorage("networkUpColor")   private var networkUpColor  = ThemeColor.orange.rawValue
    @AppStorage("networkDownColor") private var networkDownColor = ThemeColor.purple.rawValue

    private let intervals: [(String, Double)] = [
        ("1 sec", 1), ("2 sec", 2), ("3 sec", 3), ("5 sec", 5), ("10 sec", 10)
    ]

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("General") {
                    Picker("Update Interval", selection: $updateInterval) {
                        ForEach(intervals, id: \.1) { label, value in
                            Text(label).tag(value)
                        }
                    }

                    Picker("Speed Unit", selection: $speedUnit) {
                        ForEach(SpeedUnit.allCases) { unit in
                            Text(unit.rawValue).tag(unit.rawValue)
                        }
                    }
                }

                Section("Colors") {
                    colorPicker("CPU", selection: $cpuColor)
                    colorPicker("Memory", selection: $memoryColor)
                    colorPicker("Upload", selection: $networkUpColor)
                    colorPicker("Download", selection: $networkDownColor)
                }
            }
            .formStyle(.grouped)

            Text("\u{00A9}\u{FE0F} ROSCH, LLC")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 16)
        }
        .frame(width: 380, height: 400)
    }

    private func colorPicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            ForEach(ThemeColor.allCases) { theme in
                HStack(spacing: 6) {
                    Image(systemName: "circle.fill")
                        .foregroundStyle(theme.color)
                        .font(.caption)
                    Text(theme.displayName)
                }
                .tag(theme.rawValue)
            }
        }
    }
}
