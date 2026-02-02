import SwiftUI
import Charts

struct GlucoseGraphView: View {
    let readings: [GlucoseReading]
    let range: GlucoseRange
    let hours: Int

    init(readings: [GlucoseReading], range: GlucoseRange, hours: Int = 3) {
        self.readings = readings
        self.range = range
        self.hours = hours
    }

    private var timeRange: ClosedRange<Date> {
        let now = Date()
        let start = now.addingTimeInterval(-Double(hours) * 60 * 60)
        return start...now
    }

    private var glucoseRange: ClosedRange<Double> {
        let minValue = min(readings.map { $0.mmolValue }.min() ?? 2.0, range.lowUrgent - 0.5)
        let maxValue = max(readings.map { $0.mmolValue }.max() ?? 20.0, range.highUrgent + 0.5)
        return minValue...maxValue
    }

    private var xAxisStride: Calendar.Component {
        switch hours {
        case 3: return .hour
        case 6: return .hour
        case 12: return .hour
        case 24: return .hour
        default: return .hour
        }
    }

    private var xAxisStrideCount: Int {
        switch hours {
        case 3: return 1
        case 6: return 2
        case 12: return 3
        case 24: return 6
        default: return 1
        }
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
            Text("No data for the last \(hours) hours")
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
                .symbolSize(hours <= 6 ? 20 : 10) // Smaller dots for longer time ranges
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
            AxisMarks(values: .stride(by: xAxisStride, count: xAxisStrideCount)) { value in
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
    let sampleReadings = (0..<288).map { i in
        GlucoseReading(
            value: Double.random(in: 70...180),
            trend: Int.random(in: 1...7),
            timestamp: Date().addingTimeInterval(Double(-i * 5 * 60))
        )
    }

    return GlucoseGraphView(readings: sampleReadings, range: .default, hours: 24)
        .frame(width: 300, height: 180)
        .padding()
}
