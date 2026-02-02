import SwiftUI
import Charts

struct GlucoseGraphView: View {
    let readings: [GlucoseReading]
    let range: GlucoseRange

    private var timeRange: ClosedRange<Date> {
        let now = Date()
        let threeHoursAgo = now.addingTimeInterval(-3 * 60 * 60)
        return threeHoursAgo...now
    }

    private var glucoseRange: ClosedRange<Double> {
        let minValue = min(readings.map { $0.mmolValue }.min() ?? 2.0, range.lowUrgent - 0.5)
        let maxValue = max(readings.map { $0.mmolValue }.max() ?? 20.0, range.highUrgent + 0.5)
        return minValue...maxValue
    }

    var body: some View {
        if readings.isEmpty {
            emptyState
        } else {
            chart
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.line.downtrend.xyaxis")
                .font(.system(size: 32))
                .foregroundColor(.secondary)
            Text("No data for the last 3 hours")
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var chart: some View {
        Chart {
            // Target range band
            RectangleMark(
                xStart: .value("Start", timeRange.lowerBound),
                xEnd: .value("End", timeRange.upperBound),
                yStart: .value("Low", range.lowWarning),
                yEnd: .value("High", range.highWarning)
            )
            .foregroundStyle(.green.opacity(0.1))

            // Low warning band
            RectangleMark(
                xStart: .value("Start", timeRange.lowerBound),
                xEnd: .value("End", timeRange.upperBound),
                yStart: .value("Low", range.lowUrgent),
                yEnd: .value("High", range.lowWarning)
            )
            .foregroundStyle(.yellow.opacity(0.1))

            // High warning band
            RectangleMark(
                xStart: .value("Start", timeRange.lowerBound),
                xEnd: .value("End", timeRange.upperBound),
                yStart: .value("Low", range.highWarning),
                yEnd: .value("High", range.highUrgent)
            )
            .foregroundStyle(.yellow.opacity(0.1))

            // Glucose line
            ForEach(readings) { reading in
                LineMark(
                    x: .value("Time", reading.timestamp),
                    y: .value("Glucose", reading.mmolValue)
                )
                .foregroundStyle(colorForReading(reading))
                .lineStyle(StrokeStyle(lineWidth: 2))

                PointMark(
                    x: .value("Time", reading.timestamp),
                    y: .value("Glucose", reading.mmolValue)
                )
                .foregroundStyle(colorForReading(reading))
                .symbolSize(20)
            }

            // Target range lines
            RuleMark(y: .value("Low Target", range.lowWarning))
                .foregroundStyle(.green.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 5]))

            RuleMark(y: .value("High Target", range.highWarning))
                .foregroundStyle(.green.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 5]))
        }
        .chartXScale(domain: timeRange)
        .chartYScale(domain: glucoseRange)
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour)) { value in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour())
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let doubleValue = value.as(Double.self) {
                        Text(String(format: "%.0f", doubleValue))
                    }
                }
            }
        }
    }

    private func colorForReading(_ reading: GlucoseReading) -> Color {
        range.status(for: reading.mmolValue).color
    }
}

#Preview {
    let sampleReadings = (0..<36).map { i in
        GlucoseReading(
            value: Double.random(in: 70...180),
            trend: Int.random(in: 1...7),
            timestamp: Date().addingTimeInterval(Double(-i * 5 * 60))
        )
    }

    return GlucoseGraphView(readings: sampleReadings, range: .default)
        .frame(width: 300, height: 180)
        .padding()
}
