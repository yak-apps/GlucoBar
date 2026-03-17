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

// MARK: - Medtronic Pump Status

struct MedtronicPumpStatus {
    let activeInsulin: Double?
    let reservoirPercent: Int?
    let reservoirUnits: Double?
    let pumpBatteryPercent: Int?
    let sensorDurationHours: Int?
    let sensorDurationMinutes: Int?
    let therapyAlgorithmState: String?
}

// MARK: - Protocol

protocol GlucoseDataSource: AnyObject {
    func authenticate() async throws
    func fetchLatestReadings(minutes: Int, maxCount: Int) async throws -> [GlucoseReading]
    func logout()
}
