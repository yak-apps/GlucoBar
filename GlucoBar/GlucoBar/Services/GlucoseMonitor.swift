import Foundation
import Combine

@MainActor
class GlucoseMonitor: ObservableObject {
    @Published var latestReading: GlucoseReading?
    @Published var readings: [GlucoseReading] = []
    @Published var error: String?
    @Published var isLoading = false
    @Published var isAuthenticated = false
    @Published var glucoseRange: GlucoseRange = .default
    @Published var selectedSource: CGMSource = KeychainHelper.cgmSource
    @Published var pumpStatus: MedtronicPumpStatus?

    private var service: (any GlucoseDataSource)?
    private var timer: Timer?
    private let pollInterval: TimeInterval = 300 // 5 minutes

    init() {
        let source = KeychainHelper.cgmSource
        selectedSource = source

        switch source {
        case .dexcom:
            if KeychainHelper.hasCredentials,
               let username = KeychainHelper.getValue(for: .username),
               let password = KeychainHelper.getValue(for: .password),
               let regionString = KeychainHelper.getValue(for: .region),
               let region = DexcomRegion(rawValue: regionString) {
                setupService(username: username, password: password, region: region)
                startMonitoring()
            }

        case .carelink:
            if KeychainHelper.hasCareLinkCredentials,
               let username = KeychainHelper.getValue(for: .clUsername),
               let countryRaw = KeychainHelper.getValue(for: .clCountry),
               let region = CareLinkRegion(rawValue: countryRaw) {
                setupCareLinkService(username: username, region: region)
                startMonitoring()
            }

        case .libre:
            if KeychainHelper.hasLibreCredentials,
               let email = KeychainHelper.getValue(for: .libreEmail),
               let password = KeychainHelper.getValue(for: .librePassword) {
                setupLibreService(email: email, password: password)
                startMonitoring()
            }
        }
    }

    // MARK: - Source Selection

    func selectSource(_ source: CGMSource) {
        selectedSource = source
        KeychainHelper.cgmSource = source
    }

    // MARK: - Service Setup

    func setupService(username: String, password: String, region: DexcomRegion) {
        service = DexcomShareService(username: username, password: password, region: region)

        KeychainHelper.save(username, for: .username)
        KeychainHelper.save(password, for: .password)
        KeychainHelper.save(region.rawValue, for: .region)
    }

    func setupCareLinkService(username: String, region: CareLinkRegion) {
        service = CareLinkService(username: username, region: region)

        KeychainHelper.save(username, for: .clUsername)
        KeychainHelper.save(region.rawValue, for: .clCountry)
    }

    func setupLibreService(email: String, password: String) {
        service = LibreLinkUpService(email: email, password: password)

        KeychainHelper.save(email, for: .libreEmail)
        KeychainHelper.save(password, for: .librePassword)
    }

    // MARK: - Monitoring

    func startMonitoring() {
        stopMonitoring()

        Task { await fetchReadings() }

        let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.fetchReadings()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
    }

    func fetchReadings() async {
        guard let service = service else {
            error = "Not configured"
            return
        }

        isLoading = true
        error = nil

        do {
            let newReadings = try await service.fetchLatestReadings(minutes: 1440, maxCount: 288)
            readings = newReadings
            latestReading = newReadings.last
            isAuthenticated = true
            error = nil

            if let clService = service as? CareLinkService {
                pumpStatus = clService.latestPumpStatus
            } else {
                pumpStatus = nil
            }
        } catch let localizedError as LocalizedError {
            error = localizedError.errorDescription ?? localizedError.localizedDescription
            if let dexcomError = localizedError as? DexcomError,
               case .invalidCredentials = dexcomError {
                isAuthenticated = false
            } else if let clError = localizedError as? CareLinkError,
                      case .notAuthenticated = clError {
                isAuthenticated = false
            }
        } catch {
            self.error = error.localizedDescription
        }

        isLoading = false
    }

    func authenticate() async -> Bool {
        guard let service = service else {
            error = "Not configured"
            return false
        }

        isLoading = true
        error = nil

        do {
            try await service.authenticate()
            isAuthenticated = true
            isLoading = false
            startMonitoring()
            return true
        } catch let localizedError as LocalizedError {
            error = localizedError.errorDescription ?? localizedError.localizedDescription
            isAuthenticated = false
            isLoading = false
            return false
        } catch {
            self.error = error.localizedDescription
            isAuthenticated = false
            isLoading = false
            return false
        }
    }

    func logout() {
        stopMonitoring()
        service?.logout()
        service = nil
        latestReading = nil
        readings = []
        pumpStatus = nil
        isAuthenticated = false
        error = nil

        switch selectedSource {
        case .dexcom:
            KeychainHelper.deleteAll()
        case .carelink:
            KeychainHelper.deleteCareLinkCredentials()
        case .libre:
            KeychainHelper.deleteLibreCredentials()
        }
    }

    // MARK: - Computed Properties

    var lastUpdatedText: String {
        guard let reading = latestReading else { return "No data" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: reading.timestamp, relativeTo: Date())
    }

    // MARK: - Filtered Readings by Time Range

    func readings(forHours hours: Int) -> [GlucoseReading] {
        let cutoff = Date().addingTimeInterval(-Double(hours) * 3600)
        return readings.filter { $0.timestamp >= cutoff }
    }

    var threeHourReadings: [GlucoseReading] { readings(forHours: 3) }

    // MARK: - Time In Range

    var timeInRange24h: Double? {
        let last24h = readings(forHours: 24)
        guard !last24h.isEmpty else { return nil }
        let inRange = last24h.filter { $0.mmolValue >= glucoseRange.lowWarning && $0.mmolValue <= glucoseRange.highWarning }.count
        return Double(inRange) / Double(last24h.count) * 100
    }

    var timeBelowRange24h: Double? {
        let last24h = readings(forHours: 24)
        guard !last24h.isEmpty else { return nil }
        let below = last24h.filter { $0.mmolValue < glucoseRange.lowWarning }.count
        return Double(below) / Double(last24h.count) * 100
    }

    var timeAboveRange24h: Double? {
        let last24h = readings(forHours: 24)
        guard !last24h.isEmpty else { return nil }
        let above = last24h.filter { $0.mmolValue > glucoseRange.highWarning }.count
        return Double(above) / Double(last24h.count) * 100
    }
}
