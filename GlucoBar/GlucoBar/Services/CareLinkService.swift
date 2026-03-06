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

    var host: String {
        switch self {
        case .us: return "carelink.minimed.com"
        case .eu: return "clcloud.minimed.eu"
        case .au: return "carelink.minimed.eu"
        case .ca: return "carelink.minimed.com"
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
}

// MARK: - Errors

enum CareLinkError: LocalizedError {
    case discoveryFailed(String)
    case clientInitFailed(String)
    case authCancelled
    case authFailed(String)
    case csrGenerationFailed
    case deviceRegistrationFailed(String)
    case tokenExchangeFailed(String)
    case tokenRefreshFailed
    case fetchFailed(String)
    case notAuthenticated

    var errorDescription: String? {
        switch self {
        case .discoveryFailed(let m):        return "CareLink: Discovery failed — \(m)"
        case .clientInitFailed(let m):      return "CareLink: Client init failed — \(m)"
        case .authCancelled:                return "CareLink: Login cancelled"
        case .authFailed(let m):            return "CareLink: Auth failed — \(m)"
        case .csrGenerationFailed:          return "CareLink: Failed to generate device certificate"
        case .deviceRegistrationFailed(let m): return "CareLink: Device registration failed — \(m)"
        case .tokenExchangeFailed(let m):   return "CareLink: Token exchange failed — \(m)"
        case .tokenRefreshFailed:           return "CareLink: Failed to refresh token"
        case .fetchFailed(let m):           return "CareLink: Data fetch failed — \(m)"
        case .notAuthenticated:             return "CareLink: Not authenticated"
        }
    }
}

// MARK: - Discovery Models

private struct CareLinkDiscovery: Decodable {
    struct MAGConfig: Decodable {
        let clientCredentialInitEndpointPath: String
        let deviceRegistrationEndpointPath: String
        let tokenEndpointPath: String

        enum CodingKeys: String, CodingKey {
            case clientCredentialInitEndpointPath = "client_credential_init_endpoint_path"
            case deviceRegistrationEndpointPath   = "device_registration_endpoint_path"
            case tokenEndpointPath                = "token_endpoint_path"
        }
    }

    struct OAuthClient: Decodable {
        let organization: String
        let redirectURI: String
        let scope: String

        enum CodingKeys: String, CodingKey {
            case organization
            case redirectURI = "redirect_uri"
            case scope
        }
    }

    struct OAuthSystem: Decodable {
        let authorizationEndpointPath: String

        enum CodingKeys: String, CodingKey {
            case authorizationEndpointPath = "authorization_endpoint_path"
        }
    }

    struct OAuthConfig: Decodable {
        let client: OAuthClient
        let system: OAuthSystem
    }

    let mag: MAGConfig
    let oauth: OAuthConfig
}

// MARK: - CareLinkService

@MainActor
final class CareLinkService: NSObject, @preconcurrency GlucoseDataSource {

    private let username: String
    private let region: CareLinkRegion

    private var discovery: CareLinkDiscovery?
    private var accessToken: String?
    private var refreshToken: String?
    private var currentAuthSession: ASWebAuthenticationSession?

    init(username: String, region: CareLinkRegion) {
        self.username = username
        self.region = region
        super.init()

        // Restore tokens from Keychain
        accessToken  = KeychainHelper.getValue(for: .clAccessToken)
        refreshToken = KeychainHelper.getValue(for: .clRefreshToken)
    }

    // MARK: - GlucoseDataSource

    func authenticate() async throws {
        logger.info("CareLink: starting full auth flow for \(self.username) region=\(self.region.rawValue)")

        let disc = try await fetchDiscovery()
        self.discovery = disc

        let (clientId, clientSecret) = try await initMAGClient(discovery: disc)

        let (codeVerifier, authURL) = try buildAuthURL(discovery: disc, clientId: clientId)

        let code = try await performBrowserAuth(authURL: authURL, callbackScheme: "carelink")
        logger.info("CareLink: got auth code")

        let csr = try generateCSR(organization: disc.oauth.client.organization)

        let (idToken, _) = try await registerDevice(
            discovery: disc,
            authCode: code,
            codeVerifier: codeVerifier,
            csr: csr,
            clientId: clientId,
            clientSecret: clientSecret
        )

        try await exchangeToken(
            discovery: disc,
            idToken: idToken,
            clientId: clientId,
            clientSecret: clientSecret
        )

        logger.info("CareLink: authentication complete")
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
        discovery    = nil
        currentAuthSession?.cancel()
        currentAuthSession = nil
        KeychainHelper.deleteCareLinkCredentials()
    }

    // MARK: - Discovery

    private func fetchDiscovery() async throws -> CareLinkDiscovery {
        logger.info("CareLink: fetching discovery from \(self.region.discoveryURL)")

        let (data, response) = try await URLSession.shared.data(from: region.discoveryURL)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw CareLinkError.discoveryFailed("HTTP \(status)")
        }

        do {
            let decoder = JSONDecoder()
            return try decoder.decode(CareLinkDiscovery.self, from: data)
        } catch {
            throw CareLinkError.discoveryFailed("JSON parse error: \(error.localizedDescription)")
        }
    }

    // MARK: - MAG Client Init

    private func initMAGClient(discovery: CareLinkDiscovery) async throws -> (clientId: String, clientSecret: String) {
        // Re-use cached client creds if present
        if let savedId = KeychainHelper.getValue(for: .clClientId),
           let savedSecret = KeychainHelper.getValue(for: .clClientSecret) {
            logger.info("CareLink: using cached client credentials")
            return (savedId, savedSecret)
        }

        let path = discovery.mag.clientCredentialInitEndpointPath
        guard let url = URL(string: "https://\(region.host)\(path)") else {
            throw CareLinkError.clientInitFailed("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["nonce": UUID().uuidString])

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw CareLinkError.clientInitFailed("HTTP \(status)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let clientId = json["client_id"] as? String,
              let clientSecret = json["client_secret"] as? String else {
            throw CareLinkError.clientInitFailed("Missing client_id/client_secret")
        }

        KeychainHelper.save(clientId, for: .clClientId)
        KeychainHelper.save(clientSecret, for: .clClientSecret)
        logger.info("CareLink: MAG client init done, clientId=\(clientId.prefix(8))...")

        return (clientId, clientSecret)
    }

    // MARK: - PKCE + Auth URL

    private func buildAuthURL(discovery: CareLinkDiscovery, clientId: String) throws -> (codeVerifier: String, url: URL) {
        // code_verifier: URL-safe base64 of 40 random bytes
        var verifierBytes = [UInt8](repeating: 0, count: 40)
        _ = SecRandomCopyBytes(kSecRandomDefault, verifierBytes.count, &verifierBytes)
        let codeVerifier = Data(verifierBytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        // code_challenge: SHA256(verifier), base64url, no padding
        let challengeData = SHA256.hash(data: Data(codeVerifier.utf8))
        let codeChallenge = Data(challengeData).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        // state: 22-char random base64
        var stateBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, stateBytes.count, &stateBytes)
        let state = String(Data(stateBytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
            .prefix(22))

        let authPath = discovery.oauth.system.authorizationEndpointPath
        var components = URLComponents(string: "https://\(region.host)\(authPath)")!
        components.queryItems = [
            URLQueryItem(name: "client_id",             value: clientId),
            URLQueryItem(name: "redirect_uri",          value: discovery.oauth.client.redirectURI),
            URLQueryItem(name: "response_type",         value: "code"),
            URLQueryItem(name: "scope",                 value: discovery.oauth.client.scope),
            URLQueryItem(name: "code_challenge",        value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state",                 value: state),
            URLQueryItem(name: "nonce",                 value: UUID().uuidString),
        ]

        guard let url = components.url else {
            throw CareLinkError.authFailed("Could not build auth URL")
        }

        logger.info("CareLink: built auth URL \(url.absoluteString.prefix(80))...")
        return (codeVerifier, url)
    }

    // MARK: - Browser Auth (ASWebAuthenticationSession)

    private func performBrowserAuth(authURL: URL, callbackScheme: String) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: callbackScheme
            ) { [weak self] callbackURL, error in
                self?.currentAuthSession = nil

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
                    continuation.resume(throwing: CareLinkError.authFailed("No code in callback URL"))
                    return
                }

                continuation.resume(returning: code)
            }

            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            currentAuthSession = session

            if !session.start() {
                currentAuthSession = nil
                continuation.resume(throwing: CareLinkError.authFailed("Failed to start auth session"))
            }
        }
    }

    // MARK: - X.509 CSR Generation

    private func generateCSR(organization: String) throws -> String {
        // Generate RSA-2048 key pair
        let keyAttrs: [String: Any] = [
            kSecAttrKeyType as String:        kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String:  2048,
            kSecAttrIsPermanent as String:    false
        ]

        var cfError: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(keyAttrs as CFDictionary, &cfError) else {
            logger.error("CareLink: RSA keygen failed: \(cfError.debugDescription)")
            throw CareLinkError.csrGenerationFailed
        }
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw CareLinkError.csrGenerationFailed
        }
        guard let pubKeyData = SecKeyCopyExternalRepresentation(publicKey, &cfError) as Data? else {
            throw CareLinkError.csrGenerationFailed
        }

        let deviceId = UUID().uuidString.lowercased()

        let subject = Self.buildSubjectName(cn: "socialLogin", ou: deviceId, dc: "SM-G973F", o: organization)
        let spki    = Self.buildSubjectPublicKeyInfo(rsaPublicKeyDER: Array(pubKeyData))
        let cri     = Self.buildCertificationRequestInfo(subject: subject, spki: spki)

        // Sign the CertificationRequestInfo
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            Data(cri) as CFData,
            &cfError
        ) as Data? else {
            logger.error("CareLink: signing failed: \(cfError.debugDescription)")
            throw CareLinkError.csrGenerationFailed
        }

        let sigAlg = Self.derSequence(Self.derOID(Self.oidSHA256RSA) + Self.derNull())
        let csr    = Self.derSequence(cri + sigAlg + Self.derBitString(Array(signature)))

        // Base64url, no padding
        return Data(csr).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - Device Registration

    private func registerDevice(
        discovery: CareLinkDiscovery,
        authCode: String,
        codeVerifier: String,
        csr: String,
        clientId: String,
        clientSecret: String
    ) async throws -> (idToken: String, magId: String) {
        let path = discovery.mag.deviceRegistrationEndpointPath
        guard let url = URL(string: "https://\(region.host)\(path)") else {
            throw CareLinkError.deviceRegistrationFailed("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(authCode)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "client_id":     clientId,
            "code_verifier": codeVerifier,
            "csr":           csr
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw CareLinkError.deviceRegistrationFailed("No response")
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw CareLinkError.deviceRegistrationFailed("HTTP \(http.statusCode): \(body.prefix(100))")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let idToken = json["id_token"] as? String else {
            throw CareLinkError.deviceRegistrationFailed("Missing id_token in response")
        }

        let magId = http.value(forHTTPHeaderField: "mag-identifier") ?? ""
        if !magId.isEmpty {
            KeychainHelper.save(magId, for: .clMagId)
        }

        logger.info("CareLink: device registered, magId=\(magId.prefix(8))...")
        return (idToken, magId)
    }

    // MARK: - Token Exchange

    private func exchangeToken(
        discovery: CareLinkDiscovery,
        idToken: String,
        clientId: String,
        clientSecret: String
    ) async throws {
        let path = discovery.mag.tokenEndpointPath
        guard let url = URL(string: "https://\(region.host)\(path)") else {
            throw CareLinkError.tokenExchangeFailed("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let params: [String: String] = [
            "grant_type":    "urn:ietf:params:oauth:grant-type:jwt-bearer",
            "assertion":     idToken,
            "client_id":     clientId,
            "client_secret": clientSecret,
            "scope":         discovery.oauth.client.scope
        ]
        request.httpBody = formEncode(params)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw CareLinkError.tokenExchangeFailed("HTTP \(status): \(body.prefix(100))")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let at = json["access_token"] as? String,
              let rt = json["refresh_token"] as? String else {
            throw CareLinkError.tokenExchangeFailed("Missing tokens in response")
        }

        accessToken  = at
        refreshToken = rt
        KeychainHelper.save(at, for: .clAccessToken)
        KeychainHelper.save(rt, for: .clRefreshToken)
        logger.info("CareLink: tokens saved")
    }

    // MARK: - Token Refresh

    private func refreshAccessToken() async throws {
        guard let rt = refreshToken,
              let clientId     = KeychainHelper.getValue(for: .clClientId),
              let clientSecret = KeychainHelper.getValue(for: .clClientSecret) else {
            accessToken  = nil
            refreshToken = nil
            throw CareLinkError.tokenRefreshFailed
        }

        // Ensure we have discovery
        if discovery == nil {
            discovery = try? await fetchDiscovery()
        }
        guard let disc = discovery else {
            throw CareLinkError.tokenRefreshFailed
        }

        let path = disc.mag.tokenEndpointPath
        guard let url = URL(string: "https://\(region.host)\(path)") else {
            throw CareLinkError.tokenRefreshFailed
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let params: [String: String] = [
            "grant_type":    "refresh_token",
            "refresh_token": rt,
            "client_id":     clientId,
            "client_secret": clientSecret
        ]
        request.httpBody = formEncode(params)

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

        logger.info("CareLink: token refreshed")
    }

    // MARK: - Data Fetch

    private func fetchPatientData() async throws -> [GlucoseReading] {
        guard let at = accessToken else {
            throw CareLinkError.notAuthenticated
        }

        guard let url = URL(string: "https://\(region.host)/patient/connect/data") else {
            throw CareLinkError.fetchFailed("Invalid URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(at)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw CareLinkError.fetchFailed("No response")
        }

        if http.statusCode == 401 {
            throw CareLinkError.notAuthenticated
        }

        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw CareLinkError.fetchFailed("HTTP \(http.statusCode): \(body.prefix(100))")
        }

        return try parsePatientData(data)
    }

    private func parsePatientData(_ data: Data) throws -> [GlucoseReading] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CareLinkError.fetchFailed("Invalid JSON response")
        }

        let trendString = json["lastSGTrend"] as? String
        var readings: [GlucoseReading] = []

        // Parse historical readings from sgs[]
        if let sgs = json["sgs"] as? [[String: Any]] {
            for sg in sgs {
                if let reading = GlucoseReading(fromCareLink: sg, trendString: trendString) {
                    readings.append(reading)
                }
            }
        }

        // Fallback: use lastSG if no history
        if readings.isEmpty,
           let lastSG = json["lastSG"] as? [String: Any],
           let reading = GlucoseReading(fromCareLink: lastSG, trendString: trendString) {
            readings.append(reading)
        }

        logger.info("CareLink: parsed \(readings.count) readings")
        return readings.sorted { $0.timestamp < $1.timestamp }
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
        NSApp.windows.first(where: { $0.isVisible }) ?? NSApp.windows.first ?? NSWindow()
    }
}

// MARK: - DER / ASN.1 Helpers for CSR Generation

private extension CareLinkService {

    // OID byte arrays
    static let oidCN:        [UInt8] = [0x55, 0x04, 0x03]
    static let oidO:         [UInt8] = [0x55, 0x04, 0x0A]
    static let oidOU:        [UInt8] = [0x55, 0x04, 0x0B]
    // 0.9.2342.19200300.100.1.25 (domainComponent)
    static let oidDC:        [UInt8] = [0x09, 0x92, 0x26, 0x89, 0x93, 0xF2, 0x2C, 0x64, 0x01, 0x19]
    // 1.2.840.113549.1.1.1  (rsaEncryption)
    static let oidRSA:       [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]
    // 1.2.840.113549.1.1.11 (sha256WithRSAEncryption)
    static let oidSHA256RSA: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B]

    // DER primitive encoders
    static func derLength(_ n: Int) -> [UInt8] {
        if n < 0x80 { return [UInt8(n)] }
        if n <= 0xFF { return [0x81, UInt8(n)] }
        return [0x82, UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)]
    }

    static func derTLV(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        [tag] + derLength(content.count) + content
    }

    static func derSequence(_ c: [UInt8]) -> [UInt8] { derTLV(0x30, c) }
    static func derSet(_ c: [UInt8])      -> [UInt8] { derTLV(0x31, c) }
    static func derNull()                 -> [UInt8] { [0x05, 0x00] }
    static func derOID(_ o: [UInt8])      -> [UInt8] { derTLV(0x06, o) }

    static func derBitString(_ data: [UInt8]) -> [UInt8] {
        derTLV(0x03, [0x00] + data) // 0x00 = no unused bits
    }

    static func derInteger(_ n: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        var v = n
        repeat {
            bytes.insert(UInt8(v & 0xFF), at: 0)
            v >>= 8
        } while v > 0
        if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return derTLV(0x02, bytes)
    }

    static func derUTF8String(_ s: String) -> [UInt8] {
        derTLV(0x0C, Array(s.utf8))
    }

    // Build one RDN: SET { SEQUENCE { OID, UTF8String } }
    static func rdnAttr(oid: [UInt8], value: String) -> [UInt8] {
        derSet(derSequence(derOID(oid) + derUTF8String(value)))
    }

    // Build Subject Name SEQUENCE OF RDN
    // Order in plan: CN, OU, DC, O
    static func buildSubjectName(cn: String, ou: String, dc: String, o: String) -> [UInt8] {
        derSequence(
            rdnAttr(oid: oidCN, value: cn) +
            rdnAttr(oid: oidOU, value: ou) +
            rdnAttr(oid: oidDC, value: dc) +
            rdnAttr(oid: oidO,  value: o)
        )
    }

    // Wrap PKCS#1 RSA public key bytes in SubjectPublicKeyInfo
    static func buildSubjectPublicKeyInfo(rsaPublicKeyDER: [UInt8]) -> [UInt8] {
        let algId = derSequence(derOID(oidRSA) + derNull())
        return derSequence(algId + derBitString(rsaPublicKeyDER))
    }

    // Build CertificationRequestInfo SEQUENCE
    static func buildCertificationRequestInfo(subject: [UInt8], spki: [UInt8]) -> [UInt8] {
        let version    = derInteger(0)
        let attributes = derTLV(0xA0, []) // [0] IMPLICIT empty attributes
        return derSequence(version + subject + spki + attributes)
    }
}
