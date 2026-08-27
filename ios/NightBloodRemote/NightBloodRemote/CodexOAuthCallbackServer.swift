import Foundation
@preconcurrency import Network

/// One-use, loopback-only OAuth callback server. It deliberately implements
/// only the small HTTP subset needed for the registered Codex redirect URI.
actor CodexOAuthCallbackServer {
    private static let ports = CodexPlanOAuthConstants.callbackPorts
    private static let callbackPath = CodexPlanOAuthConstants.callbackPath
    private static let maximumHeaderBytes = 16 * 1024

    private struct OpenConnection {
        let connection: NWConnection
        var received = Data()
    }

    private enum BindFailure: Error {
        case unavailable
    }

    private enum Outcome: Sendable {
        case code(String)
        case failure(CodexPlanOAuthError)
    }

    private enum CallbackDecision {
        case reject(status: Int, reason: String)
        case finish(status: Int, reason: String, outcome: Outcome)
    }

    private let queue = DispatchQueue(
        label: "com.example.nightblood.codex-oauth-callback",
        qos: .userInitiated
    )

    private var listener: NWListener?
    private var activePort: UInt16?
    private var expectedState: String?
    private var connections: [UUID: OpenConnection] = [:]
    private var bindContinuation: CheckedContinuation<Void, Error>?
    private var callbackContinuation: CheckedContinuation<String, Error>?
    private var pendingOutcome: Outcome?
    private var terminalOutcomeAwaitingResponse: Outcome?
    private var timeoutTask: Task<Void, Never>?
    private var started = false
    private var finished = false

    /// Binds 127.0.0.1:1455 first and falls back only to 127.0.0.1:1457.
    /// The returned URI always uses the registered `localhost` hostname.
    func start(expectedState: String, timeout: Duration) async throws -> URL {
        guard !started else {
            throw CodexPlanOAuthError.alreadyInProgress
        }
        started = true
        self.expectedState = expectedState

        for port in Self.ports {
            do {
                try await bind(port: port)
                guard let redirectURI = URL(
                    string: "http://localhost:\(port)\(Self.callbackPath)"
                ) else {
                    cancel()
                    throw CodexPlanOAuthError.invalidAuthorizationURL
                }
                armTimeout(timeout)
                return redirectURI
            } catch let error as CodexPlanOAuthError where error.isCancellation {
                throw error
            } catch is CancellationError {
                cancel()
                throw CodexPlanOAuthError.cancelled
            } catch {
                discardTransport()
            }
        }

        finished = true
        self.expectedState = nil
        throw CodexPlanOAuthError.callbackPortsUnavailable
    }

    func waitForAuthorizationCode() async throws -> String {
        if let pendingOutcome {
            self.pendingOutcome = nil
            return try value(from: pendingOutcome)
        }
        guard started, !finished, listener != nil else {
            throw CodexPlanOAuthError.callbackListenerFailed
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                callbackContinuation = continuation
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func cancel() {
        guard started, !finished else { return }
        complete(with: .failure(.cancelled))
    }

    private func bind(port: UInt16) async throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw BindFailure.unavailable
        }

        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = true
        parameters.allowLocalEndpointReuse = false
        parameters.requiredLocalEndpoint = .hostPort(
            host: .ipv4(.loopback),
            port: endpointPort
        )

        let candidate: NWListener
        do {
            candidate = try NWListener(using: parameters)
        } catch {
            throw BindFailure.unavailable
        }
        candidate.newConnectionLimit = 16
        listener = candidate
        activePort = port

        candidate.newConnectionHandler = { [weak self, weak candidate] connection in
            guard let candidate else {
                connection.cancel()
                return
            }
            Task { await self?.accept(connection, from: candidate) }
        }
        candidate.stateUpdateHandler = { [weak self, weak candidate] state in
            guard let candidate else { return }
            Task { await self?.listener(candidate, changedTo: state, requestedPort: port) }
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                bindContinuation = continuation
                candidate.start(queue: queue)
            }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    private func listener(
        _ candidate: NWListener,
        changedTo state: NWListener.State,
        requestedPort: UInt16
    ) {
        guard listener === candidate else { return }

        switch state {
        case .ready:
            guard candidate.port?.rawValue == requestedPort else {
                failBinding(candidate)
                return
            }
            let continuation = bindContinuation
            bindContinuation = nil
            continuation?.resume()
        case .waiting, .failed:
            if bindContinuation != nil {
                failBinding(candidate)
            } else {
                complete(with: .failure(.callbackListenerFailed))
            }
        case .cancelled:
            if bindContinuation != nil {
                failBinding(candidate)
            } else if !finished {
                complete(with: .failure(.callbackListenerFailed))
            }
        case .setup:
            break
        @unknown default:
            if bindContinuation != nil {
                failBinding(candidate)
            } else {
                complete(with: .failure(.callbackListenerFailed))
            }
        }
    }

    private func failBinding(_ candidate: NWListener) {
        guard listener === candidate else { return }
        let continuation = bindContinuation
        bindContinuation = nil
        discardTransport()
        continuation?.resume(throwing: BindFailure.unavailable)
    }

    private func accept(_ connection: NWConnection, from candidate: NWListener) {
        guard listener === candidate,
              !finished,
              terminalOutcomeAwaitingResponse == nil,
              isLoopback(connection.endpoint)
        else {
            connection.cancel()
            return
        }

        let identifier = UUID()
        connections[identifier] = OpenConnection(connection: connection)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { await self?.removeConnection(identifier) }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveMore(on: identifier)
    }

    private func receiveMore(on identifier: UUID) {
        guard let open = connections[identifier] else { return }
        open.connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 4 * 1024
        ) { [weak self] content, _, isComplete, error in
            Task {
                await self?.received(
                    content,
                    isComplete: isComplete,
                    error: error,
                    on: identifier
                )
            }
        }
    }

    private func received(
        _ content: Data?,
        isComplete: Bool,
        error: NWError?,
        on identifier: UUID
    ) {
        guard var open = connections[identifier] else { return }
        if let content {
            open.received.append(content)
        }
        guard open.received.count <= Self.maximumHeaderBytes else {
            connections[identifier] = open
            sendResponse(status: 431, reason: "Request headers are too large.", on: identifier)
            return
        }

        let terminator = Data("\r\n\r\n".utf8)
        if let range = open.received.range(of: terminator) {
            let header = open.received[..<range.lowerBound]
            let trailingBytes = open.received[range.upperBound...]
            connections[identifier] = open
            guard trailingBytes.isEmpty else {
                sendResponse(status: 400, reason: "Invalid callback request.", on: identifier)
                return
            }
            handle(header: Data(header), on: identifier)
            return
        }

        connections[identifier] = open
        if error != nil || isComplete {
            removeConnection(identifier)
        } else {
            receiveMore(on: identifier)
        }
    }

    private func handle(header: Data, on identifier: UUID) {
        let decision = validate(header: header)
        switch decision {
        case .reject(let status, let reason):
            sendResponse(status: status, reason: reason, on: identifier)
        case .finish(let status, let reason, let outcome):
            terminalOutcomeAwaitingResponse = outcome
            listener?.newConnectionHandler = nil
            sendResponse(
                status: status,
                reason: reason,
                on: identifier,
                completesFlow: true
            )
        }
    }

    private func validate(header: Data) -> CallbackDecision {
        guard let request = String(data: header, encoding: .utf8) else {
            return .reject(status: 400, reason: "Invalid callback request.")
        }
        let lines = request.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return .reject(status: 400, reason: "Invalid callback request.")
        }
        let requestParts = requestLine.split(
            separator: " ",
            omittingEmptySubsequences: false
        )
        guard requestParts.count == 3,
              requestParts[0] == "GET",
              requestParts[2] == "HTTP/1.1"
        else {
            return .reject(status: 405, reason: "Only the OAuth GET callback is accepted.")
        }

        let target = String(requestParts[1])
        guard target.first == "/", !target.contains("#") else {
            return .reject(status: 400, reason: "Invalid callback target.")
        }
        let targetParts = target.split(
            separator: "?",
            maxSplits: 1,
            omittingEmptySubsequences: false
        )
        guard targetParts.first == Substring(Self.callbackPath) else {
            return .reject(status: 404, reason: "Not found.")
        }

        var headers: [String: [String]] = [:]
        for line in lines.dropFirst() {
            guard !line.isEmpty,
                  let colon = line.firstIndex(of: ":")
            else {
                return .reject(status: 400, reason: "Invalid callback request.")
            }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
            guard isHTTPToken(name), !value.contains("\0") else {
                return .reject(status: 400, reason: "Invalid callback request.")
            }
            headers[name, default: []].append(value)
        }

        guard let activePort,
              headers["host"] == ["localhost:\(activePort)"],
              headers["transfer-encoding"] == nil,
              headers["content-length"] == nil || headers["content-length"] == ["0"]
        else {
            return .reject(status: 400, reason: "Invalid callback request.")
        }

        guard let components = URLComponents(
            string: "http://localhost:\(activePort)\(target)"
        ), components.path == Self.callbackPath else {
            return .reject(status: 400, reason: "Invalid callback target.")
        }

        var parameters: [String: [String?]] = [:]
        for item in components.queryItems ?? [] {
            parameters[item.name, default: []].append(item.value)
        }

        guard let expectedState,
              let states = parameters["state"],
              states.count == 1,
              let returnedState = states[0],
              !returnedState.isEmpty,
              constantTimeEqual(returnedState, expectedState)
        else {
            // A local process without the random state must not be able to
            // terminate the real browser flow.
            return .reject(status: 400, reason: "OAuth state did not match.")
        }

        let errors = parameters["error"] ?? []
        let descriptions = parameters["error_description"] ?? []
        let codes = parameters["code"] ?? []

        if !errors.isEmpty {
            guard errors.count == 1,
                  let errorCode = errors[0],
                  isSafeOAuthErrorCode(errorCode),
                  codes.isEmpty,
                  descriptions.count <= 1
            else {
                return .finish(
                    status: 400,
                    reason: "Invalid OAuth error response.",
                    outcome: .failure(.invalidCallback)
                )
            }
            let description: String?
            if descriptions.isEmpty {
                description = nil
            } else {
                guard let candidate = descriptions[0],
                      isSafeDescription(candidate)
                else {
                    return .finish(
                        status: 400,
                        reason: "Invalid OAuth error response.",
                        outcome: .failure(.invalidCallback)
                    )
                }
                description = candidate
            }
            return .finish(
                status: 200,
                reason: "Sign-in was not completed. Return to NightBlood.",
                outcome: .failure(
                    .authorizationServerError(
                        code: errorCode,
                        description: description
                    )
                )
            )
        }

        guard descriptions.isEmpty,
              codes.count == 1,
              let code = codes[0],
              isSafeAuthorizationCode(code)
        else {
            return .finish(
                status: 400,
                reason: "The authorization code was missing or invalid.",
                outcome: .failure(.invalidCallback)
            )
        }

        return .finish(
            status: 200,
            reason: "Sign-in received. Return to NightBlood.",
            outcome: .code(code)
        )
    }

    private func sendResponse(
        status: Int,
        reason: String,
        on identifier: UUID,
        completesFlow: Bool = false
    ) {
        guard let connection = connections[identifier]?.connection else {
            if completesFlow, let outcome = terminalOutcomeAwaitingResponse {
                terminalOutcomeAwaitingResponse = nil
                complete(with: outcome)
            }
            return
        }

        let body = """
        <!doctype html><meta name="viewport" content="width=device-width">
        <title>NightBlood</title><p>\(htmlEscaped(reason))</p>
        """
        let bodyData = Data(body.utf8)
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 404: statusText = "Not Found"
        case 405: statusText = "Method Not Allowed"
        case 431: statusText = "Request Header Fields Too Large"
        default: statusText = "Bad Request"
        }
        var head = "HTTP/1.1 \(status) \(statusText)\r\n"
        head += "Content-Type: text/html; charset=utf-8\r\n"
        head += "Content-Length: \(bodyData.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Content-Security-Policy: default-src 'none'; style-src 'none'\r\n"
        head += "Referrer-Policy: no-referrer\r\n"
        head += "Connection: close\r\n\r\n"
        var response = Data(head.utf8)
        response.append(bodyData)

        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            Task { await self?.responseFinished(on: identifier, completesFlow: completesFlow) }
        })
    }

    private func responseFinished(on identifier: UUID, completesFlow: Bool) {
        removeConnection(identifier)
        if completesFlow, let outcome = terminalOutcomeAwaitingResponse {
            terminalOutcomeAwaitingResponse = nil
            complete(with: outcome)
        }
    }

    private func removeConnection(_ identifier: UUID) {
        guard let open = connections.removeValue(forKey: identifier) else { return }
        open.connection.stateUpdateHandler = nil
        open.connection.cancel()
    }

    private func armTimeout(_ timeout: Duration) {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            await self?.complete(with: .failure(.timedOut))
        }
    }

    private func complete(with outcome: Outcome) {
        guard !finished else { return }
        finished = true
        expectedState = nil
        terminalOutcomeAwaitingResponse = nil

        let binding = bindContinuation
        bindContinuation = nil
        let callback = callbackContinuation
        callbackContinuation = nil
        discardTransport()

        if let binding {
            switch outcome {
            case .failure(let error):
                binding.resume(throwing: error)
            case .code:
                binding.resume(throwing: CodexPlanOAuthError.callbackListenerFailed)
            }
        } else if let callback {
            resume(callback, with: outcome)
        } else {
            pendingOutcome = outcome
        }
    }

    private func discardTransport() {
        timeoutTask?.cancel()
        timeoutTask = nil

        if let listener {
            listener.stateUpdateHandler = nil
            listener.newConnectionHandler = nil
            listener.cancel()
        }
        listener = nil
        activePort = nil

        let openConnections = Array(connections.values)
        connections.removeAll()
        for open in openConnections {
            open.connection.stateUpdateHandler = nil
            open.connection.cancel()
        }
    }

    private func value(from outcome: Outcome) throws -> String {
        switch outcome {
        case .code(let code):
            return code
        case .failure(let error):
            throw error
        }
    }

    private func resume(
        _ continuation: CheckedContinuation<String, Error>,
        with outcome: Outcome
    ) {
        switch outcome {
        case .code(let code):
            continuation.resume(returning: code)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    private func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address):
            return address.isLoopback
        case .ipv6(let address):
            return address.isLoopback
        case .name(let name, _):
            return name.caseInsensitiveCompare("localhost") == .orderedSame
        @unknown default:
            return false
        }
    }

    private func isHTTPToken(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        let separators = Set("()<>@,;:\\\"/[]?={} \t".utf8)
        return value.utf8.allSatisfy { byte in
            byte >= 0x21 && byte <= 0x7e && !separators.contains(byte)
        }
    }

    private func isSafeOAuthErrorCode(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else { return false }
        return value.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39)
                || (byte >= 0x41 && byte <= 0x5a)
                || (byte >= 0x61 && byte <= 0x7a)
                || byte == 0x2d || byte == 0x2e || byte == 0x5f
        }
    }

    private func isSafeAuthorizationCode(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 8 * 1024 else { return false }
        return value.utf8.allSatisfy { $0 >= 0x21 && $0 <= 0x7e }
    }

    private func isSafeDescription(_ value: String) -> Bool {
        value.utf8.count <= 1024
            && value.unicodeScalars.allSatisfy {
                !CharacterSet.controlCharacters.contains($0)
            }
    }

    private func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(left, right) {
            difference |= a ^ b
        }
        return difference == 0
    }

    private func htmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
