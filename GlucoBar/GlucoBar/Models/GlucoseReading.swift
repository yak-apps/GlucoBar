import Foundation

struct GlucoseReading: Identifiable, Codable {
    let id: UUID
    let value: Double // mg/dL from API
    let trend: Int
    let timestamp: Date

    /// Value in mmol/L
    var mmolValue: Double {
        value / 18.0
    }

    /// Formatted display value in mmol/L
    var displayValue: String {
        String(format: "%.1f", mmolValue)
    }

    var trendArrow: TrendArrow {
        TrendArrow(rawValue: trend) ?? .flat
    }

    var rangeStatus: GlucoseRangeStatus {
        GlucoseRange.default.status(for: mmolValue)
    }

    init(id: UUID = UUID(), value: Double, trend: Int, timestamp: Date) {
        self.id = id
        self.value = value
        self.trend = trend
        self.timestamp = timestamp
    }
}

// MARK: - Dexcom API Response Parsing
extension GlucoseReading {
    /// Parse from Dexcom Share API response
    /// Format: {"WT":"Date(1234567890000)","ST":"Date(1234567890000)","DT":"Date(1234567890000+0000)","Value":120,"Trend":"Flat"}
    init?(from dictionary: [String: Any]) {
        guard let valueInt = dictionary["Value"] as? Int,
              let wtString = dictionary["WT"] as? String else {
            return nil
        }

        // Parse trend - can be string or int
        let trendValue: Int
        if let trendString = dictionary["Trend"] as? String {
            trendValue = TrendArrow.fromString(trendString)?.rawValue ?? 4
        } else if let trendInt = dictionary["Trend"] as? Int {
            trendValue = trendInt
        } else {
            trendValue = 4 // Default to flat
        }

        // Parse timestamp from "Date(1234567890000)" format
        guard let timestamp = GlucoseReading.parseDate(from: wtString) else {
            return nil
        }

        self.id = UUID()
        self.value = Double(valueInt)
        self.trend = trendValue
        self.timestamp = timestamp
    }

    private static func parseDate(from dateString: String) -> Date? {
        // Format: "Date(1234567890000)" or "Date(1234567890000+0000)"
        let pattern = #"Date\((\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: dateString, range: NSRange(dateString.startIndex..., in: dateString)),
              let range = Range(match.range(at: 1), in: dateString),
              let milliseconds = Double(dateString[range]) else {
            return nil
        }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }
}
