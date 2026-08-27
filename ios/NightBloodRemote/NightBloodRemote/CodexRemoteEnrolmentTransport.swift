import CryptoKit
import Foundation
import Security
@preconcurrency import UIKit

struct CodexRemoteHTTPRequest: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    enum Method: String, Sendable {
        case get = "GET"
        case post = "POST"
    }

    let method: Method
    let url: URL
    let headers: [String: String]
    let body: Data?

    var description: String {
        "CodexRemoteHTTPRequest(method: \(method.rawValue), url: <redacted>, headers: <redacted>, body: <redacted>)"
    }
    var debugDescription: String { description }
}

struct CodexRemoteHTTPResponse: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    let statusCode: Int
    let body: Data

    var description: String {
        "CodexRemoteHTTPResponse(statusCode: \(statusCode), body: <redacted>)"
    }
    var debugDescription: String { description }
}

protocol CodexRemoteHTTPTransport: Sendable {
    func send(_ request: CodexRemoteHTTPRequest) async throws
        -> CodexRemoteHTTPResponse
}

actor CodexRemoteURLSessionTransport: CodexRemoteHTTPTransport {
    private static let maximumResponseBytes = 1_048_576
    private let session: URLSession

    init(session: URLSession? = nil) {
        self.session = session ?? Self.makeSession()
    }

    func send(_ request: CodexRemoteHTTPRequest) async throws
        -> CodexRemoteHTTPResponse
    {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.timeoutInterval = 30
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                throw CodexRemoteEnrolmentError.invalidResponse
            }
            guard data.count <= Self.maximumResponseBytes else {
                throw CodexRemoteEnrolmentError.oversizedResponse
            }
            return CodexRemoteHTTPResponse(statusCode: http.statusCode, body: data)
        } catch is CancellationError {
            throw CodexRemoteEnrolmentError.cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw CodexRemoteEnrolmentError.cancelled
        } catch let error as CodexRemoteEnrolmentError {
            throw error
        } catch {
            throw CodexRemoteEnrolmentError.transportFailed
        }
    }

    private static func makeSession() -> URLSession {
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
            delegate: CodexRemoteNoRedirectDelegate(),
            delegateQueue: nil
        )
    }
}

private final class CodexRemoteNoRedirectDelegate: NSObject,
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

struct CodexRemoteAuthenticatedRESTClient: Sendable {
    private let account: CodexRemoteAccountContext
    private let transport: any CodexRemoteHTTPTransport

    init(
        account: CodexRemoteAccountContext,
        transport: any CodexRemoteHTTPTransport
    ) {
        self.account = account
        self.transport = transport
    }

    func enrolStart() async throws -> CodexRemoteEnrolStartResponse {
        let response = try await transport.send(
            try request(
                method: .post,
                path: CodexRemoteEnrolmentConstants.enrolStartPath,
                body: Data("{}".utf8)
            )
        )
        try validateSuccess(response)
        do {
            return try JSONDecoder().decode(
                CodexRemoteEnrolStartResponse.self,
                from: response.body
            )
        } catch {
            throw CodexRemoteEnrolmentError.invalidResponse
        }
    }

    func encodeEnrolFinish(
        _ body: CodexRemoteEnrolFinishRequest
    ) throws -> Data {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(body)
        } catch {
            throw CodexRemoteEnrolmentError.invalidDeviceProof
        }
    }

    /// Returns the raw response so the caller can persist the
    /// finish-returned-but-unvalidated state before decoding any fields.
    func sendEnrolFinish(
        encodedBody: Data
    ) async throws -> CodexRemoteHTTPResponse {
        return try await transport.send(
            try request(
                method: .post,
                path: CodexRemoteEnrolmentConstants.enrolFinishPath,
                body: encodedBody
            )
        )
    }

    func validateSuccess(_ response: CodexRemoteHTTPResponse) throws {
        guard (200...299).contains(response.statusCode) else {
            throw CodexRemoteEnrolmentError.responseRejected(
                statusCode: response.statusCode
            )
        }
    }

    private func request(
        method: CodexRemoteHTTPRequest.Method,
        path: String,
        body: Data?
    ) throws -> CodexRemoteHTTPRequest {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains(".."),
              let url = URL(string: path, relativeTo: CodexRemoteEnrolmentConstants.APIBaseURL)?
                .absoluteURL,
              url.scheme == "https",
              url.host == "chatgpt.com",
              url.path.hasPrefix("/backend-api/")
        else {
            throw CodexRemoteEnrolmentError.invalidResponse
        }
        var headers = [
            "Authorization": "Bearer \(account.accessToken)",
            "ChatGPT-Account-Id": account.accountID,
            "OpenAI-Client-User-Agent": CodexRemoteEnrolmentConstants.clientUserAgent,
            "Accept": "application/json",
        ]
        if body != nil {
            headers["Content-Type"] = "application/json"
        }
        return CodexRemoteHTTPRequest(
            method: method,
            url: url,
            headers: headers,
            body: body
        )
    }
}

protocol CodexRemoteStepUpAuthorizing: Sendable {
    func authorize(
        accountID: String,
        accountUserID: String,
        timeout: Duration,
        presentSafari: CodexOAuthSafariPresentation
    ) async throws -> CodexRemoteStepUpToken

    func cancel() async
}

actor CodexRemoteStepUpOAuth: CodexRemoteStepUpAuthorizing {
    private struct PKCE: Sendable {
        let verifier: String
        let challenge: String
    }

    private struct TokenResponse: Decodable, CustomStringConvertible,
        CustomDebugStringConvertible
    {
        let accessToken: String

        private enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
        }

        var description: String { "TokenResponse(<redacted>)" }
        var debugDescription: String { description }
    }

    private let transport: any CodexRemoteHTTPTransport
    private let now: @Sendable () -> Date
    private var activeOperationID: UUID?
    private var cancellationRequested = false
    private var callbackServer: CodexOAuthCallbackServer?
    private var safariSession: CodexOAuthSafariSession?
    private var networkTask: Task<CodexRemoteHTTPResponse, Error>?
    private var foregroundWatchTask: Task<Void, Never>?

    init(
        transport: any CodexRemoteHTTPTransport,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.transport = transport
        self.now = now
    }

    func authorize(
        accountID: String,
        accountUserID: String,
        timeout: Duration = .seconds(600),
        presentSafari: CodexOAuthSafariPresentation
    ) async throws -> CodexRemoteStepUpToken {
        guard timeout > .zero else {
            throw CodexRemoteEnrolmentError.invalidTimeout
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
                    accountID: accountID,
                    redirectURI: redirectURI,
                    pkce: pkce,
                    state: state
                )
                let browser = try await presentSafari(authorizationURL) { [weak self] in
                    Task { await self?.cancel(operationID: operationID) }
                }
                safariSession = browser
                try ensureActive(operationID)
                let code = try await server.waitForAuthorizationCode()
                try ensureActive(operationID)
                await dismissSafari()
                let rawToken = try await exchangeCode(
                    code,
                    redirectURI: redirectURI,
                    verifier: pkce.verifier,
                    operationID: operationID
                )
                let token = try CodexRemoteStepUpToken(
                    validating: rawToken,
                    accountUserID: accountUserID,
                    now: now()
                )
                await finish(operationID)
                return token
            } catch {
                let cancelled = cancellationRequested
                    || Task.isCancelled
                    || error is CancellationError
                    || (error as? CodexRemoteEnrolmentError)?.isCancellation == true
                    || (error as? CodexPlanOAuthError)?.isCancellation == true
                await finish(operationID)
                if cancelled {
                    throw CodexRemoteEnrolmentError.cancelled
                }
                throw error
            }
        } onCancel: {
            Task { await self.cancel(operationID: operationID) }
        }
    }

    func cancel() async {
        guard let activeOperationID else { return }
        await cancel(operationID: activeOperationID)
    }

    private func beginForegroundOperation() async throws -> UUID {
        guard activeOperationID == nil else {
            throw CodexRemoteEnrolmentError.alreadyInProgress
        }
        let isActive = await MainActor.run {
            UIApplication.shared.applicationState == .active
        }
        guard isActive else {
            throw CodexRemoteEnrolmentError.applicationNotActive
        }
        guard activeOperationID == nil else {
            throw CodexRemoteEnrolmentError.alreadyInProgress
        }
        let operationID = UUID()
        activeOperationID = operationID
        cancellationRequested = false
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

    private func ensureActive(_ operationID: UUID) throws {
        guard activeOperationID == operationID, !cancellationRequested else {
            throw CodexRemoteEnrolmentError.cancelled
        }
    }

    private func cancel(operationID: UUID) async {
        guard activeOperationID == operationID else { return }
        cancellationRequested = true
        networkTask?.cancel()
        await callbackServer?.cancel()
        await dismissSafari()
    }

    private func finish(_ operationID: UUID) async {
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
    ) async throws -> String {
        let body = Self.formEncoded([
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", redirectURI.absoluteString),
            ("client_id", CodexRemoteEnrolmentConstants.OAuthClientID),
            ("code_verifier", verifier),
        ])
        let request = CodexRemoteHTTPRequest(
            method: .post,
            url: CodexRemoteEnrolmentConstants.tokenEndpoint,
            headers: [
                "Content-Type": "application/x-www-form-urlencoded",
                "Accept": "application/json",
            ],
            body: body
        )
        try ensureActive(operationID)
        let task = Task { try await transport.send(request) }
        networkTask = task
        let response: CodexRemoteHTTPResponse
        do {
            response = try await task.value
        } catch is CancellationError {
            throw CodexRemoteEnrolmentError.cancelled
        } catch let error as CodexRemoteEnrolmentError {
            throw error
        } catch {
            throw CodexRemoteEnrolmentError.transportFailed
        }
        networkTask = nil
        try ensureActive(operationID)
        guard (200...299).contains(response.statusCode) else {
            throw CodexRemoteEnrolmentError.responseRejected(
                statusCode: response.statusCode
            )
        }
        do {
            let decoded = try JSONDecoder().decode(TokenResponse.self, from: response.body)
            guard !decoded.accessToken.isEmpty else {
                throw CodexRemoteEnrolmentError.malformedStepUpToken
            }
            return decoded.accessToken
        } catch let error as CodexRemoteEnrolmentError {
            throw error
        } catch {
            throw CodexRemoteEnrolmentError.malformedStepUpToken
        }
    }

    private static func authorizationURL(
        accountID: String,
        redirectURI: URL,
        pkce: PKCE,
        state: String
    ) throws -> URL {
        var components = URLComponents(
            url: CodexRemoteEnrolmentConstants.authorizationEndpoint,
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: CodexRemoteEnrolmentConstants.OAuthClientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: CodexRemoteEnrolmentConstants.stepUpScope),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "originator", value: CodexRemoteEnrolmentConstants.originator),
            URLQueryItem(name: "reauth", value: "remote_control"),
            URLQueryItem(name: "max_age", value: "0"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "allowed_workspace_id", value: accountID),
            URLQueryItem(name: "current_workspace_id", value: accountID),
        ]
        guard let url = components?.url else {
            throw CodexRemoteEnrolmentError.invalidAuthorizationURL
        }
        return url
    }

    private static func makePKCE() throws -> PKCE {
        let verifier = try randomBase64URL(byteCount: 32)
        return PKCE(
            verifier: verifier,
            challenge: base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        )
    }

    private static func randomBase64URL(byteCount: Int) throws -> String {
        var data = Data(count: byteCount)
        let status = data.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, byteCount, baseAddress)
        }
        guard status == errSecSuccess else {
            throw CodexRemoteEnrolmentError.randomGenerationFailed(status: status)
        }
        return base64URL(data)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEncoded(_ values: [(String, String)]) -> Data {
        let string = values.map { key, value in
            "\(formComponent(key))=\(formComponent(value))"
        }.joined(separator: "&")
        return Data(string.utf8)
    }

    private static func formComponent(_ value: String) -> String {
        let hexadecimal = Array("0123456789ABCDEF".utf8)
        var output = [UInt8]()
        for byte in value.utf8 {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x2E, 0x5F, 0x7E:
                output.append(byte)
            case 0x20:
                output.append(0x2B)
            default:
                output.append(0x25)
                output.append(hexadecimal[Int(byte >> 4)])
                output.append(hexadecimal[Int(byte & 0x0F)])
            }
        }
        return String(decoding: output, as: UTF8.self)
    }
}
