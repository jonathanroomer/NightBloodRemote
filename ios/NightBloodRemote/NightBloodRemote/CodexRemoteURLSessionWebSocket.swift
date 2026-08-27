@preconcurrency import Foundation

/// The production socket is outbound WSS only. It uses an isolated ephemeral
/// URLSession with no cookies, cache, credential persistence, or redirects.
/// Creating this value performs no network operation; `open` is the sole
/// connection boundary and remains injectable in the voice transport.
struct CodexRemoteURLSessionWebSocketTransport:
    CodexRemoteWebSocketTransport
{
    func open(
        _ redactedRequest: CodexRemoteWebSocketRequest
    ) async throws -> any CodexRemoteWebSocketConnection {
        let request = redactedRequest.makeURLRequest()
        guard let url = request.url,
              url.scheme == "wss",
              url.host == "chatgpt.com",
              url.path == "/backend-api/"
                + CodexRemoteControllerConstants.webSocketPath,
              url.query == nil,
              url.fragment == nil,
              url.user == nil,
              url.password == nil,
              request.httpMethod == "GET",
              request.httpBody == nil,
              request.value(forHTTPHeaderField: "Authorization")?.isEmpty == false,
              request.value(
                  forHTTPHeaderField: "x-codex-client-session-token"
              )?.isEmpty == false,
              request.value(forHTTPHeaderField: "x-codex-client-id")?.isEmpty
                == false,
              request.value(forHTTPHeaderField: "x-codex-protocol-version")
                == CodexRemoteControllerConstants.protocolVersion
        else {
            throw CodexRemoteControllerError.insecureWebSocketEndpoint
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource =
            CodexRemoteVoiceConstants.sessionGuardSeconds + 60
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 1

        let delegate = CodexRemoteWebSocketSessionDelegate()
        let queue = OperationQueue()
        queue.name = "com.example.nightblood.codex-remote-wss"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: queue
        )
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = CodexRemoteVoiceConstants
            .maximumWebSocketFrameBytes
        task.resume()
        return CodexRemoteURLSessionWebSocketConnection(
            session: session,
            task: task,
            delegate: delegate
        )
    }
}

private final class CodexRemoteWebSocketSessionDelegate: NSObject,
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
        // A redirect must never receive either bearer credential.
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (
            URLSession.AuthChallengeDisposition,
            URLCredential?
        ) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod
            == NSURLAuthenticationMethodServerTrust
        {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.rejectProtectionSpace, nil)
        }
    }
}

private actor CodexRemoteURLSessionWebSocketConnection:
    CodexRemoteWebSocketConnection
{
    private let session: URLSession
    private let task: URLSessionWebSocketTask
    // Retained explicitly so the redirect/auth policy survives for the full
    // socket lifetime even if URLSession changes its delegate retention.
    private let delegate: CodexRemoteWebSocketSessionDelegate
    private var closed = false

    init(
        session: URLSession,
        task: URLSessionWebSocketTask,
        delegate: CodexRemoteWebSocketSessionDelegate
    ) {
        self.session = session
        self.task = task
        self.delegate = delegate
    }

    func receive() async throws -> Data {
        guard !closed else {
            throw CodexRemoteVoiceError.transportClosed
        }
        let message: URLSessionWebSocketTask.Message
        do {
            message = try await task.receive()
        } catch is CancellationError {
            throw CodexRemoteVoiceError.cancelled
        } catch {
            throw CodexRemoteVoiceError.connectionFailed
        }
        let data: Data
        switch message {
        case .string(let value):
            data = Data(value.utf8)
        case .data(let value):
            data = value
        @unknown default:
            throw CodexRemoteVoiceError.malformedRemoteMessage
        }
        guard data.count <= CodexRemoteVoiceConstants.maximumWebSocketFrameBytes
        else {
            throw CodexRemoteVoiceError.oversizedWebSocketFrame
        }
        return data
    }

    func send(_ data: Data) async throws {
        guard !closed else {
            throw CodexRemoteVoiceError.transportClosed
        }
        guard data.count <= CodexRemoteVoiceConstants.maximumWebSocketFrameBytes,
              let value = String(data: data, encoding: .utf8)
        else {
            throw CodexRemoteVoiceError.oversizedWebSocketFrame
        }
        do {
            try await task.send(.string(value))
        } catch is CancellationError {
            throw CodexRemoteVoiceError.cancelled
        } catch {
            throw CodexRemoteVoiceError.connectionFailed
        }
    }

    func close() async {
        guard !closed else { return }
        closed = true
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
        _ = delegate
    }
}
