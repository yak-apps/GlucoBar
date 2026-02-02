import SwiftUI

@main
struct GlucoBarApp: App {
    @StateObject private var glucoseMonitor = GlucoseMonitor()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(glucoseMonitor: glucoseMonitor)
        } label: {
            MenuBarLabel(glucoseMonitor: glucoseMonitor)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    @ObservedObject var glucoseMonitor: GlucoseMonitor

    var body: some View {
        HStack(spacing: 2) {
            if let reading = glucoseMonitor.latestReading {
                Text(reading.displayValue)
                    .monospacedDigit()
                Text(reading.trendArrow.symbol)
            } else if glucoseMonitor.isLoading {
                Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
            } else {
                Text("---")
            }
        }
        .foregroundColor(menuBarColor)
    }

    private var menuBarColor: Color {
        guard let reading = glucoseMonitor.latestReading else {
            return .primary
        }
        return reading.rangeStatus.color
    }
}
