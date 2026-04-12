import SwiftUI

/// 軽量なミニグラフ（Canvas ベース — SwiftUI Charts の Metal オーバーヘッドを回避）
struct MiniGraphView: View {
    let data: [Double]
    let color: Color
    var maxValue: Double? = nil

    var body: some View {
        Canvas { context, size in
            let count = data.count
            guard count > 1 else { return }

            let yMax = maxValue ?? max(data.max() ?? 0, 0.001)
            let stepX = size.width / CGFloat(count - 1)

            // データ → 座標変換
            func point(_ i: Int) -> CGPoint {
                let x = stepX * CGFloat(i)
                let y = size.height - (size.height * CGFloat(data[i] / yMax))
                return CGPoint(x: x, y: min(max(y, 0), size.height))
            }

            // ライン Path
            var linePath = Path()
            linePath.move(to: point(0))
            for i in 1..<count {
                linePath.addLine(to: point(i))
            }

            // エリア Path（ラインの下を塗りつぶし）
            var areaPath = linePath
            areaPath.addLine(to: CGPoint(x: stepX * CGFloat(count - 1), y: size.height))
            areaPath.addLine(to: CGPoint(x: 0, y: size.height))
            areaPath.closeSubpath()

            // グラデーション塗りつぶし
            let gradient = Gradient(colors: [color.opacity(0.25), color.opacity(0.03)])
            context.fill(areaPath, with: .linearGradient(gradient,
                startPoint: CGPoint(x: 0, y: 0),
                endPoint: CGPoint(x: 0, y: size.height)))

            // ライン描画
            context.stroke(linePath, with: .color(color), lineWidth: 1.5)
        }
    }
}
