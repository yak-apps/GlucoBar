import Foundation
import os.log

private let logger = Logger(subsystem: "com.glucobar", category: "LibreLinkUp")

// MARK: - Errors

enum LibreError: LocalizedError {
    case invalidCredentials
    case termsNotAccepted
    case unauthorized
    case networkError(Error)
    case invalidResponse(String)
    case noConnections
    case noReadings

    var errorDescription: String? {
        switch self {
        case .invalidCredentials:  return "LibreLinkUp: Invalid email or password"
        case .termsNotAccepted:    return "LibreLinkUp: Please accept Terms of Use in the LibreLinkUp app first"
        case .unauthorized:        return "LibreLinkUp: Session expired, please reconnect"
        case .networkError(let e): return "LibreLinkUp: Network error — \(e.localizedDescription)"
        case .invalidResponse(let m): return "LibreLinkUp: Invalid response — \(m)"
        case .noConnections:       return "LibreLinkUp: No CGM connections found. Add yourself or a follower in the LibreLinkUp app"
        case .noReadings:          return "LibreLinkUp: No glucose readings available"
        }
    }
}

// MARK: - LibreLinkUpService

actor LibreLinkUpService: GlucoseDataSource {

    private let email: String
    private let password: String

    private var host: String
    private var token: String?
    private var patientId: String?
    private var tokenExpiry: Date?

    // Required headers for all requests
    private let apiVersion = "4.7.0"
    private let apiProduct = "llu.ios"

    init(email: String, password: String) {
        self.email    = email
        self.password = password
        // Restore saved host, token, patientId
        self.host      = KeychainHelper.getValue(for: .libreHost) ?? "api.libreview.io"
        self.token     = KeychainHelper.getValue(for: .libreToken)
        self.patientId = KeychainHelper.getValue(for: .librePatientId)
        self.tokenExpiry = UserDefaults.standard.object(forKey: "libreTokenExpiry") as? Date
    }

    // MARK: - GlucoseDataSource

    func authenticate() async throws {
        try await login()
    }

    func fetchLatestReadings(minutes: Int, maxCount: Int) async throws -> [GlucoseReading] {
        if token == nil || isTokenExpired {
            try await login()
        }

        do {
            return try await fetchGraph(minutes: minutes, maxCount: maxCount)
        } catch LibreError.unauthorized {
            logger.info("LibreLinkUp: token expired, re-logging in")
            try await login()
            return try await fetchGraph(minutes: minutes, maxCount: maxCount)
        }
    }

    nonisolated func logout() {
        Task { await self.clearState() }
    }

    // MARK: - Login

    private func login() async throws {
        logger.info("LibreLinkUp: logging in as \(self.email) at \(self.host)")

        let url = URL(string: "https://\(host)/llu/auth/login")!
        let body: [String: Any] = ["email": email, "password": password]

        let (data, response) = try await makeRequest(url: url, body: body, token: nil)

        guard let http = response as? HTTPURLResponse else {
            throw LibreError.invalidResponse("No HTTP response")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LibreError.invalidResponse("JSON parse failed")
        }

        let status = json["status"] as? Int ?? -1

        // Handle redirect to regional endpoint
        if let dataObj = json["data"] as? [String: Any],
           let redirect = dataObj["redirect"] as? Bool, redirect,
           let region = dataObj["region"] as? String {
            let newHost = "api-\(region).libreview.io"
            logger.info("LibreLinkUp: redirecting to \(newHost)")
            host = newHost
            KeychainHelper.save(newHost, for: .libreHost)
            // Retry login with correct regional endpoint
            try await login()
            return
        }

        // Status codes: 0=OK, 2=wrong creds, 4=terms needed
        switch status {
        case 0:
            break
        case 2:
            throw LibreError.invalidCredentials
        case 4:
            throw LibreError.termsNotAccepted
        default:
            if http.statusCode == 401 { throw LibreError.invalidCredentials }
            throw LibreError.invalidResponse("Status \(status), HTTP \(http.statusCode)")
        }

        guard let dataObj = json["data"] as? [String: Any],
              let authTicket = dataObj["authTicket"] as? [String: Any],
              let tok = authTicket["token"] as? String else {
            throw LibreError.invalidResponse("Missing auth token in response")
        }

        token = tok
        KeychainHelper.save(tok, for: .libreToken)

        // Save token expiry
        if let expires = authTicket["expires"] as? TimeInterval {
            let expiry = Date(timeIntervalSince1970: expires)
            tokenExpiry = expiry
            UserDefaults.standard.set(expiry, forKey: "libreTokenExpiry")
        }

        logger.info("LibreLinkUp: login success, token saved")

        // Fetch connections to get patientId
        try await fetchConnections()
    }

    // MARK: - Connections

    private func fetchConnections() async throws {
        guard let tok = token else { throw LibreError.unauthorized }

        let url = URL(string: "https://\(host)/llu/connections")!
        let (data, response) = try await makeRequest(url: url, body: nil, token: tok)

        guard let http = response as? HTTPURLResponse else {
            throw LibreError.invalidResponse("No response")
        }
        if http.statusCode == 401 { throw LibreError.unauthorized }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [[String: Any]],
              let first = dataObj.first,
              let pid = first["patientId"] as? String else {
            // Try single object (patient viewing own data)
            if let json2 = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let dataObj2 = json2["data"] as? [String: Any],
               let pid = dataObj2["patientId"] as? String {
                patientId = pid
                KeychainHelper.save(pid, for: .librePatientId)
                logger.info("LibreLinkUp: got patientId (single)")
                return
            }
            throw LibreError.noConnections
        }

        patientId = pid
        KeychainHelper.save(pid, for: .librePatientId)
        logger.info("LibreLinkUp: got patientId \(pid.prefix(8))...")
    }

    // MARK: - Graph Data

    private func fetchGraph(minutes: Int, maxCount: Int) async throws -> [GlucoseReading] {
        guard let tok = token else { throw LibreError.unauthorized }

        // Ensure we have a patientId
        if patientId == nil {
            try await fetchConnections()
        }
        guard let pid = patientId else { throw LibreError.noConnections }

        let url = URL(string: "https://\(host)/llu/connections/\(pid)/graph")!
        let (data, response) = try await makeRequest(url: url, body: nil, token: tok)

        guard let http = response as? HTTPURLResponse else {
            throw LibreError.invalidResponse("No response")
        }
        if http.statusCode == 401 { throw LibreError.unauthorized }
        guard http.statusCode == 200 else {
            throw LibreError.invalidResponse("HTTP \(http.statusCode)")
        }

        return try parseGraph(data: data, maxCount: maxCount)
    }

    private func parseGraph(data: Data, maxCount: Int) throws -> [GlucoseReading] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataObj = json["data"] as? [String: Any] else {
            throw LibreError.invalidResponse("Invalid graph JSON")
        }

        var readings: [GlucoseReading] = []

        // Historical readings from graphData[]
        if let graphData = dataObj["graphData"] as? [[String: Any]] {
            readings = graphData.compactMap { GlucoseReading(fromLibre: $0) }
        }

        // Current reading from connection.glucoseMeasurement (most recent)
        if let connection = dataObj["connection"] as? [String: Any],
           let gm = connection["glucoseMeasurement"] as? [String: Any],
           let current = GlucoseReading(fromLibre: gm) {
            // Add if not already in the array (deduplicate by timestamp proximity)
            if !readings.contains(where: { abs($0.timestamp.timeIntervalSince(current.timestamp)) < 60 }) {
                readings.append(current)
            }
        }

        let sorted = readings.sorted { $0.timestamp < $1.timestamp }
        let limited = maxCount > 0 ? Array(sorted.suffix(maxCount)) : sorted

        logger.info("LibreLinkUp: parsed \(limited.count) readings")
        return limited
    }

    // MARK: - Helpers

    private var isTokenExpired: Bool {
        guard let expiry = tokenExpiry else { return false }
        return Date() >= expiry.addingTimeInterval(-300) // refresh 5 min early
    }

    private func clearState() {
        token      = nil
        patientId  = nil
        tokenExpiry = nil
        host       = "api.libreview.io"
        KeychainHelper.deleteLibreCredentials()
    }

    private func makeRequest(
        url: URL,
        body: [String: Any]?,
        token: String?
    ) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = body != nil ? "POST" : "GET"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(apiVersion, forHTTPHeaderField: "version")
        request.setValue(apiProduct, forHTTPHeaderField: "product")

        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        do {
            return try await URLSession.shared.data(for: request)
        } catch {
            throw LibreError.networkError(error)
        }
    }
}
