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

    private var service: DexcomShareService?
    private var timer: Timer?
    private let pollInterval: TimeInterval = 300 // 5 minutes

    init() {
        // Check if we have stored credentials and try to use them
        if KeychainHelper.hasCredentials,
           let username = KeychainHelper.getValue(for:.username),
           let password = KeychainHelper.getValue(for:.password),
           let regionString = KeychainHelper.getValue(for:.region),
           let region = DexcomRegion(rawValue: regionString) {
            setupService(username: username, password: password, region: region)

            // Start fetching immediately
            Task {
                await fetchReadings()
            }
        }
    }

    func setupService(username: String, password: String, region: DexcomRegion) {
        service = DexcomShareService(username: username, password: password, region: region)

        // Save credentials
        KeychainHelper.save(username, for: .username)
        KeychainHelper.save(password, for: .password)
        KeychainHelper.save(region.rawValue, for: .region)
    }

    func startMonitoring() {
        // Stop any existing timer
        stopMonitoring()

        // Fetch immediately
        Task {
            await fetchReadings()
        }

        // Start periodic updates
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.fetchReadings()
            }
        }
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
            let newReadings = try await service.fetchLatestReadings()
            readings = newReadings
            latestReading = newReadings.last
            isAuthenticated = true
            error = nil
        } catch let dexcomError as DexcomError {
            error = dexcomError.errorDescription
            if case .invalidCredentials = dexcomError {
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

            // Start monitoring after successful auth
            startMonitoring()
            return true
        } catch let dexcomError as DexcomError {
            error = dexcomError.errorDescription
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
        KeychainHelper.deleteAll()
        service = nil
        latestReading = nil
        readings = []
        isAuthenticated = false
        error = nil
    }

    var lastUpdatedText: String {
        guard let reading = latestReading else {
            return "No data"
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: reading.timestamp, relativeTo: Date())
    }

    var threeHourReadings: [GlucoseReading] {
        let threeHoursAgo = Date().addingTimeInterval(-3 * 60 * 60)
        return readings.filter { $0.timestamp >= threeHoursAgo }
    }
}
