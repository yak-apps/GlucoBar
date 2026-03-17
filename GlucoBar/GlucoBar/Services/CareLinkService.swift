import Foundation
import Security
import CryptoKit
import AuthenticationServices
import os.log

private let logger = Logger(subsystem: "com.glucobar", category: "CareLinkAPI")

// MARK: - Region

enum CareLinkRegion: String, CaseIterable, Codable {
    case us = "US"
    case eu = "EU"
    case au = "AU"
    case ca = "CA"

    /// Host for the CareLink data API (clcloud)
    var host: String {
        switch self {
        case .us: return "clcloud.minimed.com"
        case .eu: return "clcloud.minimed.eu"
        case .au: return "clcloud.minimed.eu"
        case .ca: return "clcloud.minimed.com"
        }
    }

    var displayName: String {
        switch self {
        case .us: return "United States"
        case .eu: return "Europe"
        case .au: return "Australia"
        case .ca: return "Canada"
        }
    }

    var discoveryURL: URL {
        URL(string: "https://\(host)/connect/carepartner/v13/discover/android/3.6")!
    }

    /// CP array region code in the discovery response
    var cpRegionCode: String {
        switch self {
        case .us: return "US"
        case .eu: return "EU"
        case .au: return "EU"  // AU uses EU servers
        case .ca: return "US"  // CA uses US servers
        }
    }
}

// MARK: - Errors

enum CareLinkError: LocalizedError {
    case discoveryFailed(String)
    case authCancelled
    case authFailed(String)
    case tokenExchangeFailed(String)
    case tokenRefreshFailed
    case fetchFailed(String)
    case notAuthenticated

    var errorDescription: String? {
        switch self {
        case .discoveryFailed(let m):     return "CareLink: Discovery failed — \(m)"
        case .authCancelled:              return "CareLink: Login cancelled"
        case .authFailed(let m):          return "CareLink: Auth failed — \(m)"
        case .tokenExchangeFailed(let m): return "CareLink: Token exchange failed — \(m)"
        case .tokenRefreshFailed:         return "CareLink: Failed to refresh token"
        case .fetchFailed(let m):         return "CareLink: Data fetch failed — \(m)"
        case .notAuthenticated:           return "CareLink: Not authenticated"
        }
    }
}

// MARK: - Auth0 Config Model

private struct CareLinkAuth0Config {
    let hostname: String
    let clientId: String
    let redirectURI: String
    let callbackScheme: String
    let scope: String
    let audience: String
    let authorizationPath: String
    let tokenPath: String
    let baseUrlCumulus: String   // e.g. https://clcloud.minimed.eu/connect/carepartner/v13
    let baseUrlCareLink: String  // e.g. https://carelink.minimed.eu/api/carepartner/v2

    var authorizationURL: String  { "https://\(hostname)\(authorizationPath)" }
    var tokenURL: String          { "https://\(hostname)\(tokenPath)" }
    var displayMessageURL: String { "\(baseUrlCumulus)/display/message" }
    var usersURL: String          { "\(baseUrlCareLink)/users/me" }
    var patientsURL: String       { "\(baseUrlCareLink)/links/patients" }

    static func parse(from auth0Json: [String: Any], cpEntry: [String: Any]) throws -> CareLinkAuth0Config {
        guard let server = auth0Json["server"] as? [String: Any],
              let hostname = server["hostname"] as? String else {
            throw CareLinkError.discoveryFailed("Missing server.hostname in Auth0 config")
        }
        guard let client = auth0Json["client"] as? [String: Any],
              let clientId = client["client_id"] as? String,
              let redirectURI = client["redirect_uri"] as? String else {
            throw CareLinkError.discoveryFailed("Missing client credentials in Auth0 config")
        }
        guard let endpoints = auth0Json["system_endpoints"] as? [String: Any],
              let authPath = endpoints["authorization_endpoint_path"] as? String,
              let tokenPath = endpoints["token_endpoint_path"] as? String else {
            throw CareLinkError.discoveryFailed("Missing endpoints in Auth0 config")
        }

        let scope          = (client["scope"]    as? String) ?? "profile openid offline_access"
        let audience       = (client["audience"] as? String) ?? ""
        let scheme         = URL(string: redirectURI)?.scheme ?? "com.medtronic.carepartner"
        let baseUrlCumulus  = (cpEntry["baseUrlCumulus"]  as? String) ?? ""
        let baseUrlCareLink = (cpEntry["baseUrlCareLink"] as? String) ?? ""

        return CareLinkAuth0Config(
            hostname: hostname,
            clientId: clientId,
            redirectURI: redirectURI,
            callbackScheme: scheme,
            scope: scope,
            audience: audience,
            authorizationPath: authPath,
            tokenPath: tokenPath,
            baseUrlCumulus: baseUrlCumulus,
            baseUrlCareLink: baseUrlCareLink
        )
    }
}

// MARK: - CareLinkService

@MainActor
final class CareLinkService: NSObject, @preconcurrency GlucoseDataSource {

    private let username: String
    private let region: CareLinkRegion

    private(set) var latestPumpStatus: MedtronicPumpStatus?

    private var auth0Config: CareLinkAuth0Config?
    private var accessToken: String?
    private var refreshToken: String?
    private var currentAuthSession: ASWebAuthenticationSession?
    private var authAnchorWindow: NSWindow?

    init(username: String, region: CareLinkRegion) {
        self.username = username
        self.region   = region
        super.init()

        accessToken  = KeychainHelper.getValue(for: .clAccessToken)
        refreshToken = KeychainHelper.getValue(for: .clRefreshToken)
    }

    // MARK: - GlucoseDataSource

    func authenticate() async throws {
        let config = try await fetchAuth0Config()
        self.auth0Config = config

        let (codeVerifier, authURL) = try buildAuthURL(config: config)
        let code = try await performBrowserAuth(authURL: authURL, callbackScheme: config.callbackScheme)
        try await exchangeToken(config: config, authCode: code, codeVerifier: codeVerifier)
    }

    func fetchLatestReadings(minutes: Int, maxCount: Int) async throws -> [GlucoseReading] {
        guard accessToken != nil else {
            throw CareLinkError.notAuthenticated
        }
        do {
            return try await fetchPatientData()
        } catch CareLinkError.notAuthenticated {
            logger.info("CareLink: token expired, refreshing")
            try await refreshAccessToken()
            return try await fetchPatientData()
        }
    }

    func logout() {
        accessToken  = nil
        refreshToken = nil
        auth0Config  = nil
        latestPumpStatus = nil
        currentAuthSession?.cancel()
        currentAuthSession = nil
        KeychainHelper.deleteCareLinkCredentials()
    }

    // MARK: - Discovery → Auth0 Config

    private func fetchAuth0Config() async throws -> CareLinkAuth0Config {
        var req = URLRequest(url: region.discoveryURL, timeoutInterval: 20)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (discoveryData, discoveryResponse) = try await URLSession.shared.data(for: req)

        guard let http = discoveryResponse as? HTTPURLResponse, http.statusCode == 200 else {
            throw CareLinkError.discoveryFailed("HTTP \((discoveryResponse as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        guard let discoveryJson = try? JSONSerialization.jsonObject(with: discoveryData) as? [String: Any],
              let cpArray = discoveryJson["CP"] as? [[String: Any]] else {
            throw CareLinkError.discoveryFailed("Missing CP array in discovery response")
        }

        let regionCode = region.cpRegionCode
        guard let cpEntry = cpArray.first(where: { ($0["region"] as? String) == regionCode }) else {
            throw CareLinkError.discoveryFailed("No CP entry for region \(regionCode)")
        }
        guard let auth0URLString = cpEntry["Auth0SSOConfiguration"] as? String,
              let auth0URL = URL(string: auth0URLString) else {
            throw CareLinkError.discoveryFailed("Missing Auth0SSOConfiguration URL for region \(regionCode)")
        }

        var auth0Req = URLRequest(url: auth0URL, timeoutInterval: 20)
        auth0Req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (auth0Data, auth0Response) = try await URLSession.shared.data(for: auth0Req)

        guard let auth0Http = auth0Response as? HTTPURLResponse, auth0Http.statusCode == 200 else {
            throw CareLinkError.discoveryFailed("Auth0 config HTTP \((auth0Response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        guard let auth0Json = try? JSONSerialization.jsonObject(with: auth0Data) as? [String: Any] else {
            throw CareLinkError.discoveryFailed("Auth0 config is not valid JSON")
        }

        return try CareLinkAuth0Config.parse(from: auth0Json, cpEntry: cpEntry)
    }

    // MARK: - PKCE + Auth URL

    private func buildAuthURL(config: CareLinkAuth0Config) throws -> (codeVerifier: String, url: URL) {
        var verifierBytes = [UInt8](repeating: 0, count: 40)
        _ = SecRandomCopyBytes(kSecRandomDefault, verifierBytes.count, &verifierBytes)
        let codeVerifier = Data(verifierBytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        let challengeData = SHA256.hash(data: Data(codeVerifier.utf8))
        let codeChallenge = Data(challengeData).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        var stateBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, stateBytes.count, &stateBytes)
        let state = String(Data(stateBytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
            .prefix(22))

        var components = URLComponents(string: config.authorizationURL)!
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "client_id",             value: config.clientId),
            URLQueryItem(name: "redirect_uri",          value: config.redirectURI),
            URLQueryItem(name: "response_type",         value: "code"),
            URLQueryItem(name: "scope",                 value: config.scope),
            URLQueryItem(name: "code_challenge",        value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state",                 value: state),
        ]
        if !config.audience.isEmpty {
            queryItems.append(URLQueryItem(name: "audience", value: config.audience))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            throw CareLinkError.authFailed("Could not build auth URL")
        }
        return (codeVerifier, url)
    }

    // MARK: - Browser Auth (ASWebAuthenticationSession)

    private func performBrowserAuth(authURL: URL, callbackScheme: String) async throws -> String {
        // Pre-create anchor window before session.start(). NSPanel with .nonactivatingPanel
        // prevents activation policy changes that crash LSUIElement menu bar apps.
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let anchorWindow = NSPanel(
            contentRect: NSRect(x: screen.frame.midX - 150, y: screen.frame.midY - 50, width: 300, height: 100),
            styleMask: [.titled, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        anchorWindow.title = "CareLink Login"
        anchorWindow.level = .floating
        anchorWindow.isReleasedWhenClosed = false
        anchorWindow.orderFrontRegardless()
        authAnchorWindow = anchorWindow

        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: callbackScheme
            ) { [weak self] callbackURL, error in
                Task { @MainActor [weak self] in
                    self?.currentAuthSession = nil
                    self?.authAnchorWindow?.close()
                    self?.authAnchorWindow = nil

                    if let error = error {
                        if let authError = error as? ASWebAuthenticationSessionError,
                           authError.code == .canceledLogin {
                            continuation.resume(throwing: CareLinkError.authCancelled)
                        } else {
                            continuation.resume(throwing: CareLinkError.authFailed(error.localizedDescription))
                        }
                        return
                    }

                    guard let callbackURL = callbackURL,
                          let comps = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                          let code = comps.queryItems?.first(where: { $0.name == "code" })?.value else {
                        continuation.resume(throwing: CareLinkError.authFailed(
                            "No code in callback URL: \(callbackURL?.absoluteString ?? "nil")"
                        ))
                        return
                    }

                    continuation.resume(returning: code)
                }
            }

            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            currentAuthSession = session

            if !session.start() {
                Task { @MainActor [weak self] in
                    self?.currentAuthSession = nil
                    self?.authAnchorWindow?.close()
                    self?.authAnchorWindow = nil
                }
                continuation.resume(throwing: CareLinkError.authFailed("Failed to start auth session"))
            }
        }
    }

    // MARK: - Token Exchange (PKCE authorization_code)

    private func exchangeToken(config: CareLinkAuth0Config, authCode: String, codeVerifier: String) async throws {
        guard let url = URL(string: config.tokenURL) else {
            throw CareLinkError.tokenExchangeFailed("Invalid token URL: \(config.tokenURL)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = formEncode([
            "grant_type":    "authorization_code",
            "code":          authCode,
            "redirect_uri":  config.redirectURI,
            "client_id":     config.clientId,
            "code_verifier": codeVerifier,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? ""
            throw CareLinkError.tokenExchangeFailed("HTTP \(status): \(body.prefix(200))")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let at = json["access_token"] as? String else {
            throw CareLinkError.tokenExchangeFailed("Missing access_token in response")
        }

        accessToken  = at
        refreshToken = json["refresh_token"] as? String
        KeychainHelper.save(at, for: .clAccessToken)
        if let rt = refreshToken { KeychainHelper.save(rt, for: .clRefreshToken) }
    }

    // MARK: - Token Refresh

    private func refreshAccessToken() async throws {
        guard let rt = refreshToken else {
            accessToken  = nil
            refreshToken = nil
            throw CareLinkError.tokenRefreshFailed
        }

        if auth0Config == nil { auth0Config = try? await fetchAuth0Config() }
        guard let config = auth0Config, let url = URL(string: config.tokenURL) else {
            throw CareLinkError.tokenRefreshFailed
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = formEncode([
            "grant_type":    "refresh_token",
            "refresh_token": rt,
            "client_id":     config.clientId,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newAt = json["access_token"] as? String else {
            accessToken  = nil
            refreshToken = nil
            KeychainHelper.delete(.clAccessToken)
            KeychainHelper.delete(.clRefreshToken)
            throw CareLinkError.tokenRefreshFailed
        }

        accessToken = newAt
        KeychainHelper.save(newAt, for: .clAccessToken)
        if let newRt = json["refresh_token"] as? String {
            refreshToken = newRt
            KeychainHelper.save(newRt, for: .clRefreshToken)
        }
    }

    // MARK: - Data Fetch

    private func fetchPatientData() async throws -> [GlucoseReading] {
        guard let at = accessToken else { throw CareLinkError.notAuthenticated }

        if auth0Config == nil {
            auth0Config = try? await fetchAuth0Config()
        }
        guard let config = auth0Config else {
            throw CareLinkError.fetchFailed("Could not fetch API config")
        }

        // Mimic the CareLink Android app user agent — API validates this.
        let commonHeaders: [String: String] = [
            "Authorization": "Bearer \(at)",
            "Accept":        "application/json",
            "Content-Type":  "application/json",
            "User-Agent":    "Dalvik/2.1.0 (Linux; U; Android 10; Nexus 5X Build/QQ3A.200805.001)",
        ]

        // Step 1: get user role and short username
        guard let usersURL = URL(string: config.usersURL) else {
            throw CareLinkError.fetchFailed("Invalid users URL")
        }
        var req1 = URLRequest(url: usersURL)
        commonHeaders.forEach { req1.setValue($1, forHTTPHeaderField: $0) }
        let (userData, userResp) = try await URLSession.shared.data(for: req1)
        guard let userHttp = userResp as? HTTPURLResponse else { throw CareLinkError.fetchFailed("No response") }
        if userHttp.statusCode == 401 { throw CareLinkError.notAuthenticated }
        guard userHttp.statusCode == 200 else {
            let body = String(data: userData, encoding: .utf8) ?? ""
            throw CareLinkError.fetchFailed("users/me HTTP \(userHttp.statusCode): \(body.prefix(200))")
        }
        let userJson = (try? JSONSerialization.jsonObject(with: userData) as? [String: Any]) ?? [:]
        let rawRole = (userJson["role"] as? String) ?? "PATIENT"
        let shortUsername = (userJson["username"] as? String) ?? username
        let isCarePartner = rawRole.uppercased().contains("CARE_PARTNER")

        // Step 2: if care partner, get patient ID
        var patientId: String? = nil
        if isCarePartner {
            guard let patientsURL = URL(string: config.patientsURL) else {
                throw CareLinkError.fetchFailed("Invalid patients URL")
            }
            var req2 = URLRequest(url: patientsURL)
            commonHeaders.forEach { req2.setValue($1, forHTTPHeaderField: $0) }
            let (patData, patResp) = try await URLSession.shared.data(for: req2)
            guard let patHttp = patResp as? HTTPURLResponse else { throw CareLinkError.fetchFailed("No patients response") }
            if patHttp.statusCode == 401 { throw CareLinkError.notAuthenticated }
            if patHttp.statusCode == 200 {
                if let arr = try? JSONSerialization.jsonObject(with: patData) as? [[String: Any]],
                   let first = arr.first,
                   let pid = first["username"] as? String {
                    patientId = pid
                }
            }
        }

        // Step 3: POST display/message
        guard let msgURL = URL(string: config.displayMessageURL) else {
            throw CareLinkError.fetchFailed("Invalid displayMessage URL")
        }
        var msgBody: [String: Any] = [
            "username": shortUsername,
            "role":     isCarePartner ? "carepartner" : "patient",
        ]
        if let pid = patientId { msgBody["patientId"] = pid }
        let msgBodyData = try JSONSerialization.data(withJSONObject: msgBody)

        var req3 = URLRequest(url: msgURL)
        req3.httpMethod = "POST"
        commonHeaders.forEach { req3.setValue($1, forHTTPHeaderField: $0) }
        req3.httpBody = msgBodyData

        let (data, response) = try await URLSession.shared.data(for: req3)
        guard let http = response as? HTTPURLResponse else { throw CareLinkError.fetchFailed("No response") }
        if http.statusCode == 401 { throw CareLinkError.notAuthenticated }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw CareLinkError.fetchFailed("HTTP \(http.statusCode): \(body.prefix(200))")
        }

        return try parsePatientData(data)
    }

    private func parsePatientData(_ data: Data) throws -> [GlucoseReading] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CareLinkError.fetchFailed("Invalid JSON response")
        }

        // BLE response wraps everything under "patientData"
        let json = (root["patientData"] as? [String: Any]) ?? root

        let trendString = json["lastSGTrend"] as? String
        var readings: [GlucoseReading] = []

        if let sgs = json["sgs"] as? [[String: Any]] {
            for sg in sgs {
                if let reading = GlucoseReading(fromCareLink: sg, trendString: trendString) {
                    readings.append(reading)
                }
            }
        }

        if readings.isEmpty,
           let lastSG = json["lastSG"] as? [String: Any],
           let reading = GlucoseReading(fromCareLink: lastSG, trendString: trendString) {
            readings.append(reading)
        }

        // Extract pump status fields
        extractPumpStatus(from: json)

        return readings.sorted { $0.timestamp < $1.timestamp }
    }

    private func extractPumpStatus(from json: [String: Any]) {
        // activeInsulin can be an object with "amount" or a direct number
        var iob: Double?
        if let aiObj = json["activeInsulin"] as? [String: Any] {
            iob = aiObj["amount"] as? Double
        } else if let aiVal = json["activeInsulin"] as? Double {
            iob = aiVal
        }

        let reservoirPercent = json["reservoirLevelPercent"] as? Int
        let reservoirUnits = json["reservoirRemainingUnits"] as? Double
        let batteryPercent = json["medicalDeviceBatteryLevelPercent"] as? Int
        let sensorHours = json["sensorDurationHours"] as? Int
        let sensorMinutes = json["sensorDurationMinutes"] as? Int

        var therapyState: String?
        if let stateDict = json["therapyAlgorithmState"] as? [String: Any] {
            therapyState = stateDict["autoModeShieldState"] as? String
        }

        // Only create status if we have at least one useful field
        if iob != nil || reservoirPercent != nil || batteryPercent != nil || sensorHours != nil {
            latestPumpStatus = MedtronicPumpStatus(
                activeInsulin: iob,
                reservoirPercent: reservoirPercent,
                reservoirUnits: reservoirUnits,
                pumpBatteryPercent: batteryPercent,
                sensorDurationHours: sensorHours,
                sensorDurationMinutes: sensorMinutes,
                therapyAlgorithmState: therapyState
            )
        } else {
            latestPumpStatus = nil
        }
    }

    // MARK: - Helpers

    private func formEncode(_ params: [String: String]) -> Data? {
        params.map { k, v in
            let ek = k.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? k
            let ev = v.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? v
            return "\(ek)=\(ev)"
        }
        .joined(separator: "&")
        .data(using: .utf8)
    }
}

// MARK: - ASWebAuthenticationPresentationContextProviding

extension CareLinkService: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        if let existing = authAnchorWindow, existing.isVisible { return existing }

        // Fallback — should not be reached in normal flow.
        logger.warning("CareLink: presentationAnchor called without pre-created window")
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let window = NSWindow(
            contentRect: NSRect(x: screen.frame.midX - 150, y: screen.frame.midY - 50, width: 300, height: 100),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.title = "CareLink Login"
        window.level = .floating
        window.orderFrontRegardless()
        authAnchorWindow = window
        return window
    }
}
