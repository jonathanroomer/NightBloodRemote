import CryptoKit
import Foundation
import Security
@preconcurrency import UIKit

/// Experimental Codex Remote OAuth values. The public source deliberately has
/// no first-party client identifier. A developer-supplied identifier is read
/// from the generated Info.plist at runtime.
public enum CodexPlanOAuthConstants {
    public static let authorizationEndpoint = URL(
        string: "https://auth.openai.com/oauth/authorize"
    )!
    public static let tokenEndpoint = URL(
        string: "https://auth.openai.com/oauth/token"
    )!
    public static var clientID: String {
        guard let raw = Bundle.main.object(
            forInfoDictionaryKey: "CodexOAuthClientID"
        ) as? String else {
            return ""
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.hasPrefix("$(") else { return "" }
        return value
    }
    public static let scope =
        "openid profile email offline_access api.connectors.read api.connectors.invoke"
    public static let originator = "NightBlood Remote"
    public static let callbackPath = "/auth/callback"
    public static let callbackPorts: [UInt16] = [1455, 1457]
}

public enum CodexPlanOAuthError: Error, LocalizedError, Sendable {
    case alreadyInProgress
    case missingOAuthClientID
    case applicationNotActive
    case invalidTimeout
    case callbackPortsUnavailable
    case callbackListenerFailed
    case invalidCallback
    case authorizationServerError(code: String, description: String?)
    case invalidAuthorizationURL
    case browserPresenterUnavailable
    case timedOut
    case cancelled
    case tokenTransportFailed
    case tokenEndpointRejected(statusCode: Int)
    case invalidTokenResponse
    case noStoredTokens
    case invalidStoredTokens
    case invalidKeychainConfiguration
    case keychainProtectionMismatch
    case keychain(status: OSStatus)
    case randomGenerationFailed(status: OSStatus)

    public var errorDescription: String? {
        switch self {
        case .alreadyInProgress:
            "A Codex authentication operation is already in progress."
        case .missingOAuthClientID:
            "This build has no Codex Remote OAuth client ID. Demo mode remains available; see docs/CONNECTIONS.md."
        case .applicationNotActive:
            "Codex sign-in can start only while NightBlood is in the foreground."
        case .invalidTimeout:
            "The Codex sign-in timeout must be greater than zero."
        case .callbackPortsUnavailable:
            "Neither registered Codex callback port (1455 or 1457) is available."
        case .callbackListenerFailed:
            "The local Codex sign-in callback stopped unexpectedly."
        case .invalidCallback:
            "The Codex sign-in callback was invalid."
        case .authorizationServerError(let code, let description):
            if let description, !description.isEmpty {
                "Codex sign-in failed (\(code)): \(description)"
            } else {
                "Codex sign-in failed (\(code))."
            }
        case .invalidAuthorizationURL:
            "The Codex authorization URL could not be constructed."
        case .browserPresenterUnavailable:
            "A view controller is not available to present Codex sign-in."
        case .timedOut:
            "Codex sign-in timed out."
        case .cancelled:
            "Codex sign-in was cancelled."
        case .tokenTransportFailed:
            "The Codex token service could not be reached."
        case .tokenEndpointRejected(let statusCode):
            "The Codex token service rejected the request (HTTP \(statusCode))."
        case .invalidTokenResponse:
            "The Codex token service returned an invalid response."
        case .noStoredTokens:
            "No Codex plan tokens are stored on this iPhone."
        case .invalidStoredTokens:
            "The stored Codex plan tokens are invalid."
        case .invalidKeychainConfiguration:
            "The Codex token Keychain configuration is invalid."
        case .keychainProtectionMismatch:
            "The Codex token item does not have the required device-only protection."
        case .keychain(let status):
            "The iOS Keychain operation failed (status \(status))."
        case .randomGenerationFailed(let status):
            "Secure random generation failed (status \(status))."
        }
    }

    var isCancellation: Bool {
        if case .cancelled = self { return true }
        return false
    }
}

/// Reusable, UI-independent owner of ordinary Codex plan OAuth. It does not
/// perform Remote enrolment, create a device key or expose App Server methods.
public actor CodexPlanOAuth {
    private struct PKCE: Sendable {
        let verifier: String
        let challenge: String
    }

    private struct TokenExchangeResponse: Decodable {
        let accessToken: String
        let refreshToken: String
        let idToken: String

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case idToken = "id_token"
        }
    }

    private struct RefreshRequest: Encodable {
        let clientID: String
        let grantType = "refresh_token"
        let refreshToken: String

        enum CodingKeys: String, CodingKey {
            case clientID = "client_id"
            case grantType = "grant_type"
            case refreshToken = "refresh_token"
        }
    }

    private struct RefreshResponse: Decodable {
        let accessToken: String?
        let refreshToken: String?
        let idToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case idToken = "id_token"
        }
    }

    private let tokenStore: CodexPlanTokenStore
    private let urlSession: URLSession
    private var activeOperationID: UUID?
    private var cancellationRequested = false
    private var callbackServer: CodexOAuthCallbackServer?
    private var safariSession: CodexOAuthSafariSession?
    private var networkTask: Task<(Data, URLResponse), Error>?
    private var foregroundWatchTask: Task<Void, Never>?

    public init(
        tokenStore: CodexPlanTokenStore = CodexPlanTokenStore(),
        urlSession: URLSession? = nil
    ) {
        self.tokenStore = tokenStore
        self.urlSession = urlSession ?? Self.makeEphemeralSession()
    }

    /// Runs an ordinary Codex plan login. The closure is always called on the
    /// main actor and must present the supplied URL in SFSafariViewController.
    @discardableResult
    public func signIn(
        timeout: Duration = .seconds(180),
        presentSafari: CodexOAuthSafariPresentation
    ) async throws -> CodexPlanTokens {
        guard !CodexPlanOAuthConstants.clientID.isEmpty else {
            throw CodexPlanOAuthError.missingOAuthClientID
        }
        guard timeout > .zero else {
            throw CodexPlanOAuthError.invalidTimeout
        }
        let operationID = try await beginForegroundOperation()

        return try await withTaskCancellationHandler {
            do {
                let pkce = try Self.makePKCE()
                let state = try Self.randomBase64URL(byteCount: 32)
                let server = CodexOAuthCallbackServer()
                callbackServer = server
                let redirectURI = try await server.start(
                    expectedState: state,
                    timeout: timeout
                )
                try ensureActive(operationID)

                let authorizationURL = try Self.authorizationURL(
                    redirectURI: redirectURI,
                    pkce: pkce,
                    state: state
                )
                let userCancelled: @Sendable () -> Void = { [weak self] in
                    Task { await self?.cancel(operationID: operationID) }
                }
                let browser = try await presentSafari(
                    authorizationURL,
                    userCancelled
                )
                safariSession = browser
                try ensureActive(operationID)

                let code = try await server.waitForAuthorizationCode()
                try ensureActive(operationID)
                await dismissSafari()

                let tokens = try await exchangeCode(
                    code,
                    redirectURI: redirectURI,
                    verifier: pkce.verifier,
                    operationID: operationID
                )
                try ensureActive(operationID)
                try await tokenStore.save(tokens)
                await finish(operationID: operationID)
                return tokens
            } catch {
                let wasCancelled = cancellationRequested
                    || Task.isCancelled
                    || error is CancellationError
                    || (error as? CodexPlanOAuthError)?.isCancellation == true
                await finish(operationID: operationID)
                if wasCancelled {
                    throw CodexPlanOAuthError.cancelled
                }
                throw error
            }
        } onCancel: {
            Task { await self.cancel(operationID: operationID) }
        }
    }

    /// Refreshes the stored plan tokens using the JSON request shape used by
    /// Codex. Missing fields retain their previous values; present empty fields
    /// are rejected.
    @discardableResult
    public func refreshStoredTokens() async throws -> CodexPlanTokens {
        guard !CodexPlanOAuthConstants.clientID.isEmpty else {
            throw CodexPlanOAuthError.missingOAuthClientID
        }
        let operationID = try beginOperation()
        return try await withTaskCancellationHandler {
            do {
                guard let existing = try await tokenStore.load() else {
                    throw CodexPlanOAuthError.noStoredTokens
                }
                let body: Data
                do {
                    body = try JSONEncoder().encode(
                        RefreshRequest(
                            clientID: CodexPlanOAuthConstants.clientID,
                            refreshToken: existing.refreshToken
                        )
                    )
                } catch {
                    throw CodexPlanOAuthError.invalidTokenResponse
                }

                var request = URLRequest(url: CodexPlanOAuthConstants.tokenEndpoint)
                request.httpMethod = "POST"
                request.timeoutInterval = 30
                request.httpBody = body
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue(
                    CodexPlanOAuthConstants.originator,
                    forHTTPHeaderField: "originator"
                )

                let (data, response) = try await send(
                    request,
                    operationID: operationID
                )
                try validateHTTPResponse(response)
                let refreshed: RefreshResponse
                do {
                    refreshed = try JSONDecoder().decode(RefreshResponse.self, from: data)
                } catch {
                    throw CodexPlanOAuthError.invalidTokenResponse
                }

                let tokens = CodexPlanTokens(
                    accessToken: try replacement(
                        refreshed.accessToken,
                        retaining: existing.accessToken
                    ),
                    refreshToken: try replacement(
                        refreshed.refreshToken,
                        retaining: existing.refreshToken
                    ),
                    idToken: try replacement(
                        refreshed.idToken,
                        retaining: existing.idToken
                    )
                )
                try ensureActive(operationID)
                try await tokenStore.save(tokens)
                await finish(operationID: operationID)
                return tokens
            } catch {
                let wasCancelled = cancellationRequested
                    || Task.isCancelled
                    || error is CancellationError
                    || (error as? CodexPlanOAuthError)?.isCancellation == true
                await finish(operationID: operationID)
                if wasCancelled {
                    throw CodexPlanOAuthError.cancelled
                }
                throw error
            }
        } onCancel: {
            Task { await self.cancel(operationID: operationID) }
        }
    }

    public func storedTokens() async throws -> CodexPlanTokens? {
        try await tokenStore.load()
    }

    /// Cancels the current browser callback wait or token request. It never
    /// revokes credentials or removes the stored token set.
    public func cancel() async {
        guard let activeOperationID else { return }
        await cancel(operationID: activeOperationID)
    }

    private func beginForegroundOperation() async throws -> UUID {
        guard activeOperationID == nil else {
            throw CodexPlanOAuthError.alreadyInProgress
        }
        let isActive = await MainActor.run {
            UIApplication.shared.applicationState == .active
        }
        guard isActive else {
            throw CodexPlanOAuthError.applicationNotActive
        }
        // MainActor.run is a suspension point, so recheck actor state.
        guard activeOperationID == nil else {
            throw CodexPlanOAuthError.alreadyInProgress
        }

        let operationID = beginOperationUnchecked()
        foregroundWatchTask = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: UIApplication.didEnterBackgroundNotification
            ) {
                guard !Task.isCancelled else { return }
                await self?.cancel(operationID: operationID)
                return
            }
        }
        return operationID
    }

    private func beginOperation() throws -> UUID {
        guard activeOperationID == nil else {
            throw CodexPlanOAuthError.alreadyInProgress
        }
        return beginOperationUnchecked()
    }

    private func beginOperationUnchecked() -> UUID {
        let operationID = UUID()
        activeOperationID = operationID
        cancellationRequested = false
        return operationID
    }

    private func ensureActive(_ operationID: UUID) throws {
        guard activeOperationID == operationID, !cancellationRequested else {
            throw CodexPlanOAuthError.cancelled
        }
    }

    private func cancel(operationID: UUID) async {
        guard activeOperationID == operationID else { return }
        cancellationRequested = true
        networkTask?.cancel()
        await callbackServer?.cancel()
        await dismissSafari()
    }

    private func finish(operationID: UUID) async {
        guard activeOperationID == operationID else { return }
        foregroundWatchTask?.cancel()
        foregroundWatchTask = nil
        networkTask?.cancel()
        networkTask = nil
        await callbackServer?.cancel()
        callbackServer = nil
        await dismissSafari()
        cancellationRequested = false
        activeOperationID = nil
    }

    private func dismissSafari() async {
        let session = safariSession
        safariSession = nil
        await session?.dismiss()
    }

    private func exchangeCode(
        _ code: String,
        redirectURI: URL,
        verifier: String,
        operationID: UUID
    ) async throws -> CodexPlanTokens {
        let form = Self.formEncoded([
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", redirectURI.absoluteString),
            ("client_id", CodexPlanOAuthConstants.clientID),
            ("code_verifier", verifier),
        ])
        var request = URLRequest(url: CodexPlanOAuthConstants.tokenEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.httpBody = form
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            CodexPlanOAuthConstants.originator,
            forHTTPHeaderField: "originator"
        )

        let (data, response) = try await send(request, operationID: operationID)
        try validateHTTPResponse(response)
        let decoded: TokenExchangeResponse
        do {
            decoded = try JSONDecoder().decode(TokenExchangeResponse.self, from: data)
        } catch {
            throw CodexPlanOAuthError.invalidTokenResponse
        }
        guard !decoded.accessToken.isEmpty,
              !decoded.refreshToken.isEmpty,
              !decoded.idToken.isEmpty
        else {
            throw CodexPlanOAuthError.invalidTokenResponse
        }
        return CodexPlanTokens(
            accessToken: decoded.accessToken,
            refreshToken: decoded.refreshToken,
            idToken: decoded.idToken
        )
    }

    private func send(
        _ request: URLRequest,
        operationID: UUID
    ) async throws -> (Data, URLResponse) {
        try ensureActive(operationID)
        let task = Task { try await urlSession.data(for: request) }
        networkTask = task
        do {
            let result = try await task.value
            if activeOperationID == operationID {
                networkTask = nil
            }
            return result
        } catch is CancellationError {
            if activeOperationID == operationID {
                networkTask = nil
            }
            throw CodexPlanOAuthError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            if activeOperationID == operationID {
                networkTask = nil
            }
            throw CodexPlanOAuthError.cancelled
        } catch {
            if activeOperationID == operationID {
                networkTask = nil
            }
            throw CodexPlanOAuthError.tokenTransportFailed
        }
    }

    private func validateHTTPResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw CodexPlanOAuthError.invalidTokenResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw CodexPlanOAuthError.tokenEndpointRejected(
                statusCode: http.statusCode
            )
        }
    }

    private func replacement(_ value: String?, retaining current: String) throws -> String {
        guard let value else { return current }
        guard !value.isEmpty else {
            throw CodexPlanOAuthError.invalidTokenResponse
        }
        return value
    }

    private static func authorizationURL(
        redirectURI: URL,
        pkce: PKCE,
        state: String
    ) throws -> URL {
        var components = URLComponents(
            url: CodexPlanOAuthConstants.authorizationEndpoint,
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: CodexPlanOAuthConstants.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: CodexPlanOAuthConstants.scope),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "originator", value: CodexPlanOAuthConstants.originator),
        ]
        guard let url = components?.url else {
            throw CodexPlanOAuthError.invalidAuthorizationURL
        }
        return url
    }

    private static func makePKCE() throws -> PKCE {
        let verifier = try randomBase64URL(byteCount: 64)
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return PKCE(
            verifier: verifier,
            challenge: base64URL(Data(digest))
        )
    }

    private static func randomBase64URL(byteCount: Int) throws -> String {
        var data = Data(count: byteCount)
        let status = data.withUnsafeMutableBytes { buffer in
            guard let address = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, byteCount, address)
        }
        guard status == errSecSuccess else {
            throw CodexPlanOAuthError.randomGenerationFailed(status: status)
        }
        return base64URL(data)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEncoded(_ fields: [(String, String)]) -> Data {
        let body = fields.map { key, value in
            "\(formComponent(key))=\(formComponent(value))"
        }.joined(separator: "&")
        return Data(body.utf8)
    }

    private static func formComponent(_ value: String) -> String {
        let hexadecimal = Array("0123456789ABCDEF".utf8)
        var result = [UInt8]()
        result.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            switch byte {
            case 0x30...0x39, 0x41...0x5a, 0x61...0x7a, 0x2d, 0x2e, 0x5f, 0x7e:
                result.append(byte)
            case 0x20:
                result.append(0x2b)
            default:
                result.append(0x25)
                result.append(hexadecimal[Int(byte >> 4)])
                result.append(hexadecimal[Int(byte & 0x0f)])
            }
        }
        return String(decoding: result, as: UTF8.self)
    }

    private static func makeEphemeralSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        return URLSession(
            configuration: configuration,
            delegate: CodexOAuthNoRedirectDelegate(),
            delegateQueue: nil
        )
    }
}

private final class CodexOAuthNoRedirectDelegate: NSObject,
    URLSessionTaskDelegate,
    @unchecked Sendable
{
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
