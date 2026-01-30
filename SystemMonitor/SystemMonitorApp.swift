import SwiftUI

@main
struct SystemMonitorApp: App {
    @State private var stats = SystemStats()

    var body: some Scene {
        MenuBarExtra {
            MonitorPopoverView(stats: stats)
        } label: {
            Text(stats.menuBarText)
                .monospacedDigit()
        }
        .menuBarExtraStyle(.window)
    }
}
