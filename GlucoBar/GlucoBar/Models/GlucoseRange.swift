import SwiftUI

struct GlucoseRange: Codable {
    var lowUrgent: Double    // Below this is urgent low (red)
    var lowWarning: Double   // Below this is low warning (yellow)
    var highWarning: Double  // Above this is high warning (yellow)
    var highUrgent: Double   // Above this is urgent high (red)

    static let `default` = GlucoseRange(
        lowUrgent: 3.3,
        lowWarning: 4.0,
        highWarning: 10.0,
        highUrgent: 13.9
    )

    func status(for value: Double) -> GlucoseRangeStatus {
        if value < lowUrgent || value > highUrgent {
            return .urgent
        } else if value < lowWarning || value > highWarning {
            return .warning
        } else {
            return .inRange
        }
    }
}

enum GlucoseRangeStatus {
    case inRange
    case warning
    case urgent

    var color: Color {
        switch self {
        case .inRange: return .green
        case .warning: return .yellow
        case .urgent: return .red
        }
    }

    var description: String {
        switch self {
        case .inRange: return "In Range"
        case .warning: return "Warning"
        case .urgent: return "Urgent"
        }
    }
}
