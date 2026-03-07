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

    /// Parse from CareLink patient data API
    /// Each sg item: {"sg": 120, "timestamp": "2024-01-01T12:00:00.000Z", "kind": "SG"}
    /// Trend is passed in separately (from top-level lastSGTrend) or per-item if present
    init?(fromCareLink dict: [String: Any], trendString: String? = nil) {
        // glucose value (mg/dL)
        let sgValue: Double
        if let sg = dict["sg"] as? Int {
            sgValue = Double(sg)
        } else if let sg = dict["sg"] as? Double {
            sgValue = sg
        } else {
            return nil
        }

        guard sgValue > 0 else { return nil }

        // timestamp: ISO8601, with or without timezone (CareLink omits it)
        guard let tsString = dict["timestamp"] as? String else { return nil }
        let timestamp: Date
        let isoFull = ISO8601DateFormatter()
        if let d = isoFull.date(from: tsString) {
            timestamp = d
        } else {
            // No timezone suffix — treat as UTC (device timezone handled by server)
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            df.timeZone = TimeZone(abbreviation: "UTC")
            guard let d = df.date(from: tsString) else { return nil }
            timestamp = d
        }

        // trend: use per-item if available, otherwise fall back to passed-in string
        let trend: TrendArrow
        if let perItemTrend = dict["trend"] as? String {
            trend = TrendArrow.fromCareLinkString(perItemTrend)
        } else if let trendString = trendString {
            trend = TrendArrow.fromCareLinkString(trendString)
        } else {
            trend = .flat
        }

        self.id = UUID()
        self.value = sgValue
        self.trend = trend.rawValue
        self.timestamp = timestamp
    }

    /// Parse from LibreLinkUp graph API
    /// Format: {"FactoryTimestamp":"1/4/2024 8:27:48 AM","ValueInMgPerDl":120,"TrendArrow":3}
    init?(fromLibre dict: [String: Any]) {
        // Value in mg/dL
        let mgdl: Double
        if let v = dict["ValueInMgPerDl"] as? Int    { mgdl = Double(v) }
        else if let v = dict["ValueInMgPerDl"] as? Double { mgdl = v }
        else { return nil }
        guard mgdl > 0 else { return nil }

        // TrendArrow: 1–5 int
        let arrow: TrendArrow
        if let t = dict["TrendArrow"] as? Int {
            arrow = TrendArrow.fromLibreInt(t)
        } else {
            arrow = .flat
        }

        // Timestamp: prefer FactoryTimestamp (UTC) then Timestamp
        let tsKey = dict["FactoryTimestamp"] != nil ? "FactoryTimestamp" : "Timestamp"
        guard let tsString = dict[tsKey] as? String,
              let timestamp = GlucoseReading.parseLibreDate(tsString) else {
            return nil
        }

        self.id        = UUID()
        self.value     = mgdl
        self.trend     = arrow.rawValue
        self.timestamp = timestamp
    }

    private static func parseLibreDate(_ string: String) -> Date? {
        // Formats seen in the wild:
        // "1/4/2024 8:27:48 AM"  (M/d/yyyy h:mm:ss a, en_US)
        // "1/4/2024 8:27:48"     (no AM/PM, 24-hour)
        let fmtWithAMPM = DateFormatter()
        fmtWithAMPM.locale = Locale(identifier: "en_US_POSIX")
        fmtWithAMPM.dateFormat = "M/d/yyyy h:mm:ss a"
        if let d = fmtWithAMPM.date(from: string) { return d }

        let fmt24 = DateFormatter()
        fmt24.locale = Locale(identifier: "en_US_POSIX")
        fmt24.dateFormat = "M/d/yyyy H:mm:ss"
        return fmt24.date(from: string)
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
