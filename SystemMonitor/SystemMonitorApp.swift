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
    }
}

// MARK: - SF Symbol キャッシュ

private enum SymbolCache {
    static var cache: [String: NSImage] = [:]

    static func symbol(_ name: String, size: CGFloat, color: NSColor) -> NSImage? {
        let key = "\(name)-\(size)-\(color)"
        if let cached = cache[key] { return cached }
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
            .applying(.init(paletteColors: [color]))
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }
        cache[key] = img
        return img
    }

    static func invalidate() { cache.removeAll() }
}

// MARK: - 即時ラスタライズ（クロージャ保持によるメモリリーク防止）

private func rasterize(size: NSSize, draw: () -> Void) -> NSImage {
    autoreleasepool {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let pw = Int(ceil(size.width * scale))
        let ph = Int(ceil(size.height * scale))
        guard pw > 0, ph > 0,
              let rep = NSBitmapImageRep(
                  bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph,
                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                  isPlanar: false, colorSpaceName: .deviceRGB,
                  bytesPerRow: 0, bitsPerPixel: 0
              ),
              let ctx = NSGraphicsContext(bitmapImageRep: rep)
        else { return NSImage() }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.cgContext.scaleBy(x: scale, y: scale)
        draw()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        image.isTemplate = false
        return image
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
    @AppStorage("compactShowCPU")     private var compactShowCPU     = true
    @AppStorage("compactShowRAM")     private var compactShowRAM     = true
    @AppStorage("compactShowNetwork") private var compactShowNetwork = true

    var body: some View {
        Image(nsImage: renderImage())
            .onChange(of: cpuColorName)     { _, _ in SymbolCache.invalidate() }
            .onChange(of: memoryColorName)  { _, _ in SymbolCache.invalidate() }
            .onChange(of: netUpColorName)   { _, _ in SymbolCache.invalidate() }
            .onChange(of: netDownColorName) { _, _ in SymbolCache.invalidate() }
            .onChange(of: menuBarSizeRaw)   { _, _ in SymbolCache.invalidate() }
    }

    private func renderImage() -> NSImage {
        let cpuNS  = ThemeColor(rawValue: cpuColorName)?.nsColor     ?? .systemBlue
        let memNS  = ThemeColor(rawValue: memoryColorName)?.nsColor  ?? .systemGreen
        let upNS   = ThemeColor(rawValue: netUpColorName)?.nsColor   ?? .systemOrange
        let downNS = ThemeColor(rawValue: netDownColorName)?.nsColor ?? .systemPurple

        let menuBarSize = MenuBarSize(rawValue: menuBarSizeRaw) ?? .compact
        let fontSize = menuBarSize.fontSize
        let isCompact = menuBarSize == .compact
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .medium)

        let fig = "\u{2007}"
        let cpuVal  = String(format: "%2.0f%%", stats.cpuUsage).replacingOccurrences(of: " ", with: fig)
        let memVal  = String(format: "%2.0f%%", stats.memoryPercent).replacingOccurrences(of: " ", with: fig)
        let upVal   = SystemStats.formatSpeed(stats.networkUpSpeed, unit: stats.speedUnit)
        let downVal = SystemStats.formatSpeed(stats.networkDownSpeed, unit: stats.speedUnit)

        if !isCompact {
            let labelFont = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .regular)
            let labelColor = NSColor.secondaryLabelColor
            let str = NSMutableAttributedString()
            func lbl(_ t: String) {
                str.append(NSAttributedString(string: t, attributes: [.font: labelFont, .foregroundColor: labelColor]))
            }
            func val(_ t: String, _ c: NSColor) {
                str.append(NSAttributedString(string: t, attributes: [.font: valueFont, .foregroundColor: c]))
            }
            lbl("CPU "); val(cpuVal, cpuNS)
            lbl(" MEM "); val(memVal, memNS)
            lbl(" ↑"); val(upVal, upNS)
            lbl(" ↓"); val(downVal, downNS)

            let size = str.size()
            let imgSize = NSSize(width: ceil(size.width), height: ceil(size.height))
            return rasterize(size: imgSize) { str.draw(at: .zero) }
        }

        // コンパクト: 2段レイアウト（CPU+↑ / RAM+↓）
        let showCPU = compactShowCPU
        let showRAM = compactShowRAM
        let showNet = compactShowNetwork

        if !showCPU && !showRAM && !showNet {
            return NSImage(size: NSSize(width: 1, height: 1))
        }

        let smallSize: CGFloat = 9
        let lblFont = NSFont.systemFont(ofSize: smallSize, weight: .semibold)
        let spdFont = NSFont.monospacedDigitSystemFont(ofSize: smallSize, weight: .medium)
        let labelColor = NSColor.secondaryLabelColor

        let barW: CGFloat = 36
        let barH: CGFloat = 5
        let pad: CGFloat = 4

        let cpuLbl = NSAttributedString(string: "CPU ", attributes: [.font: lblFont, .foregroundColor: labelColor])
        let ramLbl = NSAttributedString(string: "RAM ", attributes: [.font: lblFont, .foregroundColor: labelColor])

        let upStr = "↑" + SystemStats.formatSpeedAuto(stats.networkUpSpeed)
        let downStr = "↓" + SystemStats.formatSpeedAuto(stats.networkDownSpeed)
        let upAttr = NSAttributedString(string: upStr, attributes: [.font: spdFont, .foregroundColor: upNS])
        let downAttr = NSAttributedString(string: downStr, attributes: [.font: spdFont, .foregroundColor: downNS])

        // 行データ
        struct RowInfo {
            var label: NSAttributedString?
            var barFill: Double?
            var barColor: NSColor?
            var speed: NSAttributedString?
        }

        var rows: [RowInfo] = []

        if showCPU && showRAM {
            rows.append(RowInfo(label: cpuLbl, barFill: stats.cpuUsage / 100, barColor: cpuNS,
                                speed: showNet ? upAttr : nil))
            rows.append(RowInfo(label: ramLbl, barFill: stats.memoryPercent / 100, barColor: memNS,
                                speed: showNet ? downAttr : nil))
        } else if showCPU {
            rows.append(RowInfo(label: cpuLbl, barFill: stats.cpuUsage / 100, barColor: cpuNS,
                                speed: showNet ? upAttr : nil))
            if showNet {
                rows.append(RowInfo(speed: downAttr))
            }
        } else if showRAM {
            rows.append(RowInfo(label: ramLbl, barFill: stats.memoryPercent / 100, barColor: memNS,
                                speed: showNet ? upAttr : nil))
            if showNet {
                rows.append(RowInfo(speed: downAttr))
            }
        } else {
            rows.append(RowInfo(speed: upAttr))
            rows.append(RowInfo(speed: downAttr))
        }

        // サイズ計算
        let rowH = max(cpuLbl.size().height, upAttr.size().height)
        let rowGap: CGFloat = rows.count > 1 ? 1 : 0
        let totalH = rowH * CGFloat(rows.count) + rowGap * CGFloat(max(rows.count - 1, 0))

        let hasLabel = rows.contains(where: { $0.label != nil })
        let hasBar = rows.contains(where: { $0.barFill != nil })
        let hasSpeed = rows.contains(where: { $0.speed != nil })

        let lblW: CGFloat = hasLabel ? max(cpuLbl.size().width, ramLbl.size().width) : 0
        let spdW: CGFloat = hasSpeed ? max(upAttr.size().width, downAttr.size().width) : 0

        var totalW: CGFloat = lblW
        if hasBar { totalW += barW }
        if spdW > 0 {
            if totalW > 0 { totalW += pad }
            totalW += spdW
        }

        let imgSize = NSSize(width: ceil(totalW), height: ceil(totalH))

        return rasterize(size: imgSize) {
            for (i, row) in rows.enumerated() {
                let y = totalH - rowH * CGFloat(i + 1) - rowGap * CGFloat(i)
                var x: CGFloat = 0

                if let label = row.label {
                    label.draw(at: NSPoint(x: x, y: y))
                }
                x = lblW

                if let fill = row.barFill, let color = row.barColor {
                    let barY = y + (rowH - barH) / 2
                    let bgRect = NSRect(x: x, y: barY, width: barW, height: barH)
                    NSColor.quaternaryLabelColor.setFill()
                    NSBezierPath(roundedRect: bgRect, xRadius: 2, yRadius: 2).fill()
                    let fw = barW * CGFloat(min(max(fill, 0), 1))
                    if fw > 0 {
                        let fRect = NSRect(x: x, y: barY, width: fw, height: barH)
                        color.setFill()
                        NSBezierPath(roundedRect: fRect, xRadius: 2, yRadius: 2).fill()
                    }
                }
                if hasBar { x += barW }

                if let speed = row.speed {
                    if x > 0 { x += pad }
                    speed.draw(at: NSPoint(x: x, y: y))
                }
            }
        }
    }
}
