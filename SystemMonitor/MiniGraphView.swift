import SwiftUI
import Charts

struct MiniGraphView: View {
    let data: [Double]
    let color: Color
    var maxValue: Double? = nil

    private var yMax: Double {
        if let maxValue { return maxValue }
        let dataMax = data.max() ?? 0
        return max(dataMax, 0.001)
    }

    var body: some View {
        Chart {
            ForEach(Array(data.enumerated()), id: \.offset) { index, value in
                AreaMark(
                    x: .value("Time", index),
                    y: .value("Value", value)
                )
                .foregroundStyle(
                    .linearGradient(
                        colors: [color.opacity(0.25), color.opacity(0.03)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.catmullRom)

                LineMark(
                    x: .value("Time", index),
                    y: .value("Value", value)
                )
                .foregroundStyle(color)
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartXScale(domain: 0...max(data.count - 1, 1))
        .chartYScale(domain: 0...yMax)
    }
}
