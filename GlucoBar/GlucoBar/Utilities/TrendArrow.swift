import Foundation

enum TrendArrow: Int, Codable {
    case none = 0
    case doubleUp = 1
    case singleUp = 2
    case fortyFiveUp = 3
    case flat = 4
    case fortyFiveDown = 5
    case singleDown = 6
    case doubleDown = 7
    case notComputable = 8
    case rateOutOfRange = 9

    var symbol: String {
        switch self {
        case .none: return ""
        case .doubleUp: return "↑↑"
        case .singleUp: return "↑"
        case .fortyFiveUp: return "↗"
        case .flat: return "→"
        case .fortyFiveDown: return "↘"
        case .singleDown: return "↓"
        case .doubleDown: return "↓↓"
        case .notComputable: return "?"
        case .rateOutOfRange: return "⚠"
        }
    }

    var description: String {
        switch self {
        case .none: return "None"
        case .doubleUp: return "Rising quickly"
        case .singleUp: return "Rising"
        case .fortyFiveUp: return "Rising slowly"
        case .flat: return "Stable"
        case .fortyFiveDown: return "Falling slowly"
        case .singleDown: return "Falling"
        case .doubleDown: return "Falling quickly"
        case .notComputable: return "Not computable"
        case .rateOutOfRange: return "Rate out of range"
        }
    }

    static func fromString(_ string: String) -> TrendArrow? {
        switch string.lowercased() {
        case "none": return .none
        case "doubleup": return .doubleUp
        case "singleup": return .singleUp
        case "fortyfiveup": return .fortyFiveUp
        case "flat": return .flat
        case "fortyfivedown": return .fortyFiveDown
        case "singledown": return .singleDown
        case "doubledown": return .doubleDown
        case "notcomputable": return .notComputable
        case "rateoutofrange": return .rateOutOfRange
        default: return nil
        }
    }

    /// LibreLinkUp TrendArrow: 1=RisingQuickly, 2=Rising, 3=Flat, 4=Falling, 5=FallingQuickly
    static func fromLibreInt(_ value: Int) -> TrendArrow {
        switch value {
        case 1: return .doubleUp
        case 2: return .singleUp
        case 3: return .flat
        case 4: return .singleDown
        case 5: return .doubleDown
        default: return .flat
        }
    }

    static func fromCareLinkString(_ string: String) -> TrendArrow {
        switch string.uppercased() {
        case "UP_DOUBLE", "UP_TRIPLE": return .doubleUp
        case "UP":                     return .singleUp
        case "UP_SLIGHT":              return .fortyFiveUp
        case "FLAT", "NONE":           return .flat
        case "DOWN_SLIGHT":            return .fortyFiveDown
        case "DOWN":                   return .singleDown
        case "DOWN_DOUBLE", "DOWN_TRIPLE": return .doubleDown
        default:                       return .flat
        }
    }
}
