import SwiftUI

/// Shape ベースの軽量グラフ（Metal テクスチャ不要）
struct MiniGraphView: View {
    let data: [Double]
    let color: Color
    var maxValue: Double? = nil

    var body: some View {
        GraphLineShape(data: data, maxValue: resolvedMax)
            .stroke(color, lineWidth: 1.5)
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private var resolvedMax: Double {
        maxValue ?? max(data.max() ?? 0, 0.001)
    }
}

// MARK: - Line Shape

private struct GraphLineShape: Shape {
    let data: [Double]
    let maxValue: Double

    func path(in rect: CGRect) -> Path {
        Path { p in
            let count = data.count
            guard count > 1 else { return }
            let stepX = rect.width / CGFloat(count - 1)
            p.move(to: pt(0, rect, stepX))
            for i in 1..<count {
                p.addLine(to: pt(i, rect, stepX))
            }
        }
    }

    private func pt(_ i: Int, _ r: CGRect, _ stepX: CGFloat) -> CGPoint {
        let y = r.height - r.height * CGFloat(data[i] / maxValue)
        return CGPoint(x: stepX * CGFloat(i), y: min(max(y, 0), r.height))
    }
}
