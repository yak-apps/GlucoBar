import Foundation
import os.log

private let logger = Logger(subsystem: "com.glucobar", category: "DexcomAPI")

enum DexcomRegion: String, CaseIterable, Codable {
    case us = "US"
    case nonUS = "Non-US"

    var baseURL: String {
        switch self {
        case .us:
            return "https://share2.dexcom.com"
        case .nonUS:
            return "https://shareous1.dexcom.com"
        }
    }
}

enum DexcomError: LocalizedError {
    case invalidCredentials
    case sessionExpired
    case networkError(Error)
    case invalidResponse(String)
    case noReadings
    case shareNotEnabled
    case accountNotFound
    case unknownError(String)

    var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return "Invalid email or password. Use your Dexcom Share credentials."
        case .sessionExpired:
            return "Session expired, please re-authenticate"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .invalidResponse(let details):
            return "Invalid response: \(details)"
        case .noReadings:
            return "No glucose readings available"
        case .shareNotEnabled:
            return "Dexcom Share not enabled. Enable sharing in Dexcom app and add a follower."
        case .accountNotFound:
            return "Account not found. Check your email address."
        case .unknownError(let message):
            return message
        }
    }
}

actor DexcomShareService {
    private let applicationId = "d89443d2-327c-4a6f-89e5-496bbb0317db"
    private var sessionId: String?
    private var accountId: String?
    private let region: DexcomRegion
    private let username: String
    private let password: String

    init(username: String, password: String, region: DexcomRegion) {
        self.username = username
        self.password = password
        self.region = region

        // Try to restore session from storage
        if let savedSession = KeychainHelper.getValue(for: .sessionId),
           let savedAccount = KeychainHelper.getValue(for: .accountId) {
            self.sessionId = savedSession
            self.accountId = savedAccount
            logger.info("Restored session from storage")
        }
    }

    // MARK: - Public API

    func authenticate() async throws {
        logger.info("Starting authentication for \(self.username) on \(self.region.rawValue)")

        // Step 1: Get account ID
        accountId = try await loginPublisherAccount()
        KeychainHelper.save(accountId!, for: .accountId)
        logger.info("Got account ID: \(self.accountId ?? "nil")")

        // Step 2: Get session ID
        sessionId = try await loginById()
        KeychainHelper.save(sessionId!, for: .sessionId)
        logger.info("Got session ID: \(self.sessionId?.prefix(8) ?? "nil")...")
    }

    func fetchLatestReadings(minutes: Int = 180, maxCount: Int = 36) async throws -> [GlucoseReading] {
        logger.info("Fetching readings (minutes: \(minutes), max: \(maxCount))")

        // Ensure we have a session
        if sessionId == nil {
            logger.info("No session, authenticating first")
            try await authenticate()
        }

        do {
            return try await fetchReadings(minutes: minutes, maxCount: maxCount)
        } catch DexcomError.sessionExpired {
            logger.info("Session expired, re-authenticating")
            try await authenticate()
            return try await fetchReadings(minutes: minutes, maxCount: maxCount)
        }
    }

    // MARK: - Private API Methods

    private func loginPublisherAccount() async throws -> String {
        let url = URL(string: "\(region.baseURL)/ShareWebServices/Services/General/AuthenticatePublisherAccount")!
        logger.info("Login URL: \(url.absoluteString)")

        let body: [String: Any] = [
            "accountName": username,
            "password": password,
            "applicationId": applicationId
        ]

        let (data, response) = try await makeRequest(url: url, body: body)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DexcomError.invalidResponse("No HTTP response")
        }

        let responseString = String(data: data, encoding: .utf8) ?? "Unable to decode response"
        logger.info("Login response (\(httpResponse.statusCode)): \(responseString.prefix(100))")

        // Check for error responses
        if httpResponse.statusCode == 500 || httpResponse.statusCode == 400 {
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let code = errorJson["Code"] as? String {
                logger.error("Error code: \(code)")
                switch code {
                case "AccountPasswordInvalid":
                    throw DexcomError.invalidCredentials
                case "SSO_AuthenticateAccountNotFound":
                    throw DexcomError.accountNotFound
                case "SSO_InternalError":
                    throw DexcomError.unknownError("Dexcom server error. Try again later.")
                default:
                    let message = errorJson["Message"] as? String ?? code
                    throw DexcomError.unknownError(message)
                }
            }

            if responseString.contains("AccountPasswordInvalid") {
                throw DexcomError.invalidCredentials
            }
            if responseString.contains("AccountNotFound") {
                throw DexcomError.accountNotFound
            }

            throw DexcomError.invalidResponse("Server error (\(httpResponse.statusCode)): \(responseString.prefix(100))")
        }

        guard httpResponse.statusCode == 200 else {
            throw DexcomError.invalidResponse("HTTP \(httpResponse.statusCode): \(responseString.prefix(100))")
        }

        let accountId = responseString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))

        if accountId.isEmpty || accountId.contains("<") || accountId.contains("{\"") {
            throw DexcomError.invalidResponse("Unexpected format: \(responseString.prefix(100))")
        }

        return accountId
    }

    private func loginById() async throws -> String {
        guard let accountId = accountId else {
            throw DexcomError.sessionExpired
        }

        let url = URL(string: "\(region.baseURL)/ShareWebServices/Services/General/LoginPublisherAccountById")!
        logger.info("LoginById URL: \(url.absoluteString)")

        let body: [String: Any] = [
            "accountId": accountId,
            "password": password,
            "applicationId": applicationId
        ]

        let (data, response) = try await makeRequest(url: url, body: body)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DexcomError.invalidResponse("No HTTP response")
        }

        let responseString = String(data: data, encoding: .utf8) ?? "Unable to decode response"
        logger.info("LoginById response (\(httpResponse.statusCode)): \(responseString.prefix(100))")

        if httpResponse.statusCode != 200 {
            if let errorJson = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let code = errorJson["Code"] as? String {
                let message = errorJson["Message"] as? String ?? code
                throw DexcomError.unknownError(message)
            }
            throw DexcomError.invalidResponse("HTTP \(httpResponse.statusCode): \(responseString.prefix(100))")
        }

        let sessionId = responseString
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))

        if sessionId.isEmpty || sessionId.contains("<") {
            throw DexcomError.invalidResponse("Invalid session: \(responseString.prefix(100))")
        }

        return sessionId
    }

    private func fetchReadings(minutes: Int, maxCount: Int) async throws -> [GlucoseReading] {
        guard let sessionId = sessionId else {
            throw DexcomError.sessionExpired
        }

        var components = URLComponents(string: "\(region.baseURL)/ShareWebServices/Services/Publisher/ReadPublisherLatestGlucoseValues")!
        components.queryItems = [
            URLQueryItem(name: "sessionId", value: sessionId),
            URLQueryItem(name: "minutes", value: String(minutes)),
            URLQueryItem(name: "maxCount", value: String(maxCount))
        ]

        guard let url = components.url else {
            throw DexcomError.invalidResponse("Invalid URL")
        }

        logger.info("Fetch readings URL: \(url.absoluteString.prefix(100))...")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DexcomError.invalidResponse("No HTTP response")
        }

        let responseString = String(data: data, encoding: .utf8) ?? ""
        logger.info("Readings response (\(httpResponse.statusCode)): \(responseString.prefix(200))")

        if httpResponse.statusCode == 500 {
            if responseString.contains("SessionIdNotFound") || responseString.contains("SessionNotValid") {
                self.sessionId = nil
                throw DexcomError.sessionExpired
            }
            if responseString.contains("ArgumentException") {
                throw DexcomError.shareNotEnabled
            }
            throw DexcomError.invalidResponse("Server error (500)")
        }

        guard httpResponse.statusCode == 200 else {
            throw DexcomError.invalidResponse("HTTP \(httpResponse.statusCode)")
        }

        let trimmedResponse = responseString.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmedResponse.isEmpty {
            logger.info("Empty response - no readings")
            return []
        }

        if trimmedResponse == "[]" {
            logger.info("Empty array - no readings")
            return []
        }

        do {
            guard let jsonArray = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                if let errorJson = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let message = errorJson["Message"] as? String ?? "Unknown error"
                    throw DexcomError.unknownError(message)
                }
                throw DexcomError.invalidResponse("Expected array, got: \(trimmedResponse.prefix(100))")
            }

            logger.info("Parsed \(jsonArray.count) readings from JSON")

            let readings = jsonArray.compactMap { GlucoseReading(from: $0) }
            logger.info("Converted to \(readings.count) GlucoseReading objects")

            return readings.sorted { $0.timestamp < $1.timestamp }

        } catch let error as DexcomError {
            throw error
        } catch {
            throw DexcomError.invalidResponse("Parse error: \(error.localizedDescription). Data: \(trimmedResponse.prefix(150))")
        }
    }

    private func makeRequest(url: URL, body: [String: Any]) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Dexcom Share/3.0.2.11", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        do {
            return try await URLSession.shared.data(for: request)
        } catch {
            logger.error("Network error: \(error.localizedDescription)")
            throw DexcomError.networkError(error)
        }
    }
}
