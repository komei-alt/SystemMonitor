import SwiftUI
import AppKit

@main
struct SystemMonitorApp: App {
    @State private var stats = SystemStats()

    var body: some Scene {
        MenuBarExtra {
            MonitorPopoverView(stats: stats)
        } label: {
            MenuBarLabel(stats: stats)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}

// MARK: - カラー付きメニューバーラベル（NSAttributedString → NSImage）

struct MenuBarLabel: View {
    var stats: SystemStats

    @AppStorage("cpuColor")         private var cpuColorName     = ThemeColor.blue.rawValue
    @AppStorage("memoryColor")      private var memoryColorName  = ThemeColor.green.rawValue
    @AppStorage("networkUpColor")   private var netUpColorName   = ThemeColor.orange.rawValue
    @AppStorage("networkDownColor") private var netDownColorName = ThemeColor.purple.rawValue
    @AppStorage("menuBarSize")      private var menuBarSizeRaw   = MenuBarSize.compact.rawValue

    var body: some View {
        Image(nsImage: renderImage())
    }

    private func renderImage() -> NSImage {
        let cpuNS  = ThemeColor(rawValue: cpuColorName)?.nsColor     ?? .systemBlue
        let memNS  = ThemeColor(rawValue: memoryColorName)?.nsColor  ?? .systemGreen
        let upNS   = ThemeColor(rawValue: netUpColorName)?.nsColor   ?? .systemOrange
        let downNS = ThemeColor(rawValue: netDownColorName)?.nsColor ?? .systemPurple

        let fontSize = (MenuBarSize(rawValue: menuBarSizeRaw) ?? .compact).fontSize
        let labelFont = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium)
        let labelColor = NSColor.secondaryLabelColor

        let str = NSMutableAttributedString()

        func label(_ text: String) {
            str.append(NSAttributedString(string: text, attributes: [
                .font: labelFont,
                .foregroundColor: labelColor
            ]))
        }

        func value(_ text: String, color: NSColor) {
            str.append(NSAttributedString(string: text, attributes: [
                .font: valueFont,
                .foregroundColor: color
            ]))
        }

        label("CPU ")
        value(String(format: "%2.0f%%", stats.cpuUsage), color: cpuNS)
        label("  MEM ")
        value(String(format: "%2.0f%%", stats.memoryPercent), color: memNS)
        label("  ↑")
        value(SystemStats.formatSpeed(stats.networkUpSpeed, unit: stats.speedUnit), color: upNS)
        label(" ↓")
        value(SystemStats.formatSpeed(stats.networkDownSpeed, unit: stats.speedUnit), color: downNS)

        // NSAttributedString → NSImage にレンダリング
        let size = str.size()
        let imageSize = NSSize(width: ceil(size.width), height: ceil(size.height))
        let image = NSImage(size: imageSize)
        image.lockFocus()
        str.draw(at: .zero)
        image.unlockFocus()
        image.isTemplate = false  // テンプレートモード無効化（色を保持）
        return image
    }
}
