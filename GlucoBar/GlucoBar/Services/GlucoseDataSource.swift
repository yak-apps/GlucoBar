import Foundation

// MARK: - CGM Source

enum CGMSource: String, CaseIterable, Codable {
    case dexcom   = "dexcom"
    case carelink = "carelink"
    case libre    = "libre"

    var displayName: String {
        switch self {
        case .dexcom:   return "Dexcom"
        case .carelink: return "Medtronic CareLink"
        case .libre:    return "FreeStyle Libre"
        }
    }
}

// MARK: - Protocol

protocol GlucoseDataSource: AnyObject {
    func authenticate() async throws
    func fetchLatestReadings(minutes: Int, maxCount: Int) async throws -> [GlucoseReading]
    func logout()
}
