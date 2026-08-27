import Foundation

private struct CodexRemotePairRequest: Encodable, Sendable {
    let clientID: String
    let manualPairingCode: String

    private enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case manualPairingCode = "manual_pairing_code"
    }
}

private struct CodexRemotePairResponse: Decodable, Sendable {
    let clientID: String?
    let environmentID: String?
    let alternateEnvironmentID: String?
    let status: String?
    let paired: Bool?

    private enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case environmentID = "env_id"
        case alternateEnvironmentID = "environment_id"
        case status
        case paired
    }
}

private struct CodexRemoteEnvironmentListResponse: Decodable, Sendable {
    let items: [CodexRemotePairedEnvironment]
}

/// Capability produced only after this file has validated a fresh,
/// client-scoped environment response. It has no generally available
/// initializer, so UI or JavaScript strings cannot mark pairing confirmed.
struct CodexRemoteVerifiedEnvironmentBinding: Sendable {
    let accountUserID: String
    let clientID: String
    let environmentID: String

    fileprivate init(
        accountUserID: String,
        clientID: String,
        environmentID: String
    ) {
        self.accountUserID = accountUserID
        self.clientID = clientID
        self.environmentID = environmentID
    }
}

private struct CodexRemoteRefreshStartRequest: Encodable, Sendable {
    let clientID: String

    private enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
    }
}

private struct CodexRemoteRefreshStartResponse: Decodable, Sendable {
    let clientID: String
    let accountUserID: String
    let deviceKeyChallenge: CodexRemoteDeviceKeyChallenge

    private enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case accountUserID = "account_user_id"
        case deviceKeyChallenge = "device_key_challenge"
    }
}

private struct CodexRemoteRefreshFinishRequest: Encodable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    let clientID: String
    let deviceKeyProof: CodexRemoteDeviceKeyProofWire

    private enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case deviceKeyProof = "device_key_proof"
    }

    var description: String { "CodexRemoteRefreshFinishRequest(<redacted>)" }
    var debugDescription: String { description }
}

private struct CodexRemoteRefreshFinishResponse: Decodable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    let clientID: String
    let accountUserID: String
    let token: String
    let expiresAt: CodexRemoteExpirationValue
    let scopes: [String]

    private enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case accountUserID = "account_user_id"
        case token = "remote_control_token"
        case expiresAt = "expires_at"
        case scopes
    }

    var description: String { "CodexRemoteRefreshFinishResponse(<redacted>)" }
    var debugDescription: String { description }
}

private enum CodexRemoteExpirationValue: Decodable, Sendable {
    case integer(Int64)
    case number(Double)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported expiration"
            )
        }
    }
}

private enum CodexRemoteControllerRESTFactory {
    static func request<Body: Encodable>(
        account: CodexRemoteAccountContext,
        method: CodexRemoteHTTPRequest.Method,
        path: String,
        body: Body?
    ) throws -> CodexRemoteHTTPRequest {
        let encodedBody: Data?
        if let body {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            do {
                encodedBody = try encoder.encode(body)
            } catch {
                throw CodexRemoteControllerError.invalidRequest
            }
        } else {
            encodedBody = nil
        }
        return try request(
            account: account,
            method: method,
            path: path,
            encodedBody: encodedBody
        )
    }

    static func request(
        account: CodexRemoteAccountContext,
        method: CodexRemoteHTTPRequest.Method,
        path: String,
        encodedBody: Data?
    ) throws -> CodexRemoteHTTPRequest {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains(".."),
              let url = URL(
                  string: path,
                  relativeTo: CodexRemoteEnrolmentConstants.APIBaseURL
              )?.absoluteURL,
              url.scheme == "https",
              url.host == "chatgpt.com",
              url.path.hasPrefix("/backend-api/")
        else {
            throw CodexRemoteControllerError.invalidRequest
        }
        var headers = [
            "Authorization": "Bearer \(account.accessToken)",
            "ChatGPT-Account-Id": account.accountID,
            "OpenAI-Client-User-Agent":
                CodexRemoteEnrolmentConstants.clientUserAgent,
            "Accept": "application/json",
        ]
        if encodedBody != nil {
            headers["Content-Type"] = "application/json"
        }
        return CodexRemoteHTTPRequest(
            method: method,
            url: url,
            headers: headers,
            body: encodedBody
        )
    }

    static func encodedPathComponent(_ value: String) throws -> String {
        guard !value.isEmpty else {
            throw CodexRemoteControllerError.clientMismatch
        }
        var allowed = CharacterSet.alphanumerics
        allowed.formUnion(CharacterSet(charactersIn: "-._~"))
        guard let encoded = value.addingPercentEncoding(
            withAllowedCharacters: allowed
        ), !encoded.isEmpty else {
            throw CodexRemoteControllerError.invalidRequest
        }
        return encoded
    }

    static func validateSuccess(_ response: CodexRemoteHTTPResponse) throws {
        guard (200...299).contains(response.statusCode) else {
            throw CodexRemoteControllerError.responseRejected(
                statusCode: response.statusCode
            )
        }
    }

    static func decode<Value: Decodable>(
        _ type: Value.Type,
        from response: CodexRemoteHTTPResponse
    ) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: response.body)
        } catch {
            throw CodexRemoteControllerError.invalidResponse
        }
    }
}

/// One object represents one manual-code claim. Once the request has crossed
/// the transport boundary it is consumed forever, including cancellation and
/// transport failure, because the server-side pairing result may be unknown.
actor CodexRemoteManualPairingClaim {
    private enum State: Sendable {
        case ready
        case inFlight
        case outcomeUnknown
        case finished
    }

    private let account: CodexRemoteAccountContext
    private let metadata: CodexRemoteEnrolmentMetadata
    private let transport: any CodexRemoteHTTPTransport
    private let lifecycleStore: any CodexRemotePairingLifecycleStoring
    private let now: @Sendable () -> Date
    private var state: State = .ready

    init(
        account: CodexRemoteAccountContext,
        metadata: CodexRemoteEnrolmentMetadata,
        transport: any CodexRemoteHTTPTransport,
        lifecycleStore: any CodexRemotePairingLifecycleStoring =
            CodexRemotePairingLifecycleStore.shared,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.account = account
        self.metadata = metadata
        self.transport = transport
        self.lifecycleStore = lifecycleStore
        self.now = now
    }

    func claim(code rawCode: String) async throws -> CodexRemotePairingReceipt {
        guard case .ready = state else {
            throw CodexRemoteControllerError.pairingAttemptAlreadyConsumed
        }
        try CodexRemoteControllerValidation.validate(
            account: account,
            metadata: metadata,
            now: now()
        )
        let code = try CodexRemoteManualPairingCode(rawCode)
        let body = CodexRemotePairRequest(
            clientID: metadata.clientID,
            manualPairingCode: code.normalisedValue
        )
        let request = try CodexRemoteControllerRESTFactory.request(
            account: account,
            method: .post,
            path: CodexRemoteControllerConstants.pairPath,
            body: body
        )

        let lifecycle = try await lifecycleStore.prepare(
            accountUserID: metadata.accountUserID,
            clientID: metadata.clientID
        )
        guard lifecycle.state == .ready else {
            throw CodexRemoteControllerError.pairingAttemptAlreadyConsumed
        }
        _ = try await lifecycleStore.transition(
            accountUserID: metadata.accountUserID,
            clientID: metadata.clientID,
            from: [.ready],
            to: .inFlight
        )
        state = .inFlight
        let response: CodexRemoteHTTPResponse
        do {
            response = try await transport.send(request)
        } catch {
            state = .outcomeUnknown
            _ = try? await lifecycleStore.transition(
                accountUserID: metadata.accountUserID,
                clientID: metadata.clientID,
                from: [.inFlight],
                to: .outcomeUnknown
            )
            throw CodexRemoteControllerError.pairingOutcomeUnknown
        }

        guard (200...299).contains(response.statusCode) else {
            // A private mutation endpoint can return an error after committing.
            // Once bytes crossed the transport boundary, every outcome other
            // than verified paired-environment state remains fail-unknown.
            state = .outcomeUnknown
            _ = try? await lifecycleStore.transition(
                accountUserID: metadata.accountUserID,
                clientID: metadata.clientID,
                from: [.inFlight],
                to: .outcomeUnknown
            )
            throw CodexRemoteControllerError.pairingOutcomeUnknown
        }

        let wire: CodexRemotePairResponse
        do {
            wire = try JSONDecoder().decode(
                CodexRemotePairResponse.self,
                from: response.body
            )
            if let returnedClientID = wire.clientID,
               returnedClientID != metadata.clientID
            {
                throw CodexRemoteControllerError.clientMismatch
            }
        } catch {
            // A 2xx response means pairing may already have mutated server
            // state even if its private-protocol response is unrecognisable.
            state = .outcomeUnknown
            _ = try? await lifecycleStore.transition(
                accountUserID: metadata.accountUserID,
                clientID: metadata.clientID,
                from: [.inFlight],
                to: .outcomeUnknown
            )
            throw CodexRemoteControllerError.pairingOutcomeUnknown
        }

        do {
            _ = try await lifecycleStore.transition(
                accountUserID: metadata.accountUserID,
                clientID: metadata.clientID,
                from: [.inFlight],
                to: .responseReceivedUnverified
            )
        } catch {
            state = .outcomeUnknown
            throw CodexRemoteControllerError.pairingOutcomeUnknown
        }
        state = .finished
        return CodexRemotePairingReceipt(
            clientID: wire.clientID,
            envID: wire.environmentID,
            environmentID: wire.alternateEnvironmentID,
            status: wire.status,
            paired: wire.paired
        )
    }
}

struct CodexRemotePairedEnvironmentClient: Sendable {
    private let account: CodexRemoteAccountContext
    private let metadata: CodexRemoteEnrolmentMetadata
    private let transport: any CodexRemoteHTTPTransport
    private let lifecycleStore: any CodexRemotePairingLifecycleStoring
    private let now: @Sendable () -> Date

    init(
        account: CodexRemoteAccountContext,
        metadata: CodexRemoteEnrolmentMetadata,
        transport: any CodexRemoteHTTPTransport,
        lifecycleStore: any CodexRemotePairingLifecycleStoring =
            CodexRemotePairingLifecycleStore.shared,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.account = account
        self.metadata = metadata
        self.transport = transport
        self.lifecycleStore = lifecycleStore
        self.now = now
    }

    func list() async throws -> CodexRemoteEnvironmentListing {
        try CodexRemoteControllerValidation.validate(
            account: account,
            metadata: metadata,
            now: now()
        )
        let clientID = try CodexRemoteControllerRESTFactory.encodedPathComponent(
            metadata.clientID
        )
        let request = try CodexRemoteControllerRESTFactory.request(
            account: account,
            method: .get,
            path: "\(CodexRemoteControllerConstants.environmentsPathPrefix)/"
                + "\(clientID)/environments?limit=100",
            encodedBody: nil
        )
        let response = try await transport.send(request)
        try CodexRemoteControllerRESTFactory.validateSuccess(response)
        let wire = try CodexRemoteControllerRESTFactory.decode(
            CodexRemoteEnvironmentListResponse.self,
            from: response
        )
        guard wire.items.count <= 100 else {
            throw CodexRemoteControllerError.tooManyEnvironments
        }
        return CodexRemoteEnvironmentListing(environments: wire.items)
    }

    /// A pair response is provisional. Only a fresh client-scoped listing that
    /// contains the explicitly selected online Mac confirms the mutation.
    func verifyAndConfirm(
        environmentID: String
    ) async throws -> CodexRemotePairedEnvironment {
        let listing = try await list()
        let selected = try listing.selecting(environmentID: environmentID)
        _ = try await lifecycleStore.confirmAfterEnvironmentVerification(
            CodexRemoteVerifiedEnvironmentBinding(
                accountUserID: metadata.accountUserID,
                clientID: metadata.clientID,
                environmentID: environmentID
            )
        )
        return selected
    }

    /// Revalidates the persisted native environment binding immediately before
    /// each Remote connection. No web view or JavaScript-supplied identifier is
    /// accepted by this operation.
    func confirmedEnvironmentForConnection() async throws
        -> CodexRemotePairedEnvironment
    {
        let pairing = try await lifecycleStore.load(
            accountUserID: metadata.accountUserID,
            clientID: metadata.clientID
        )
        guard pairing?.state == .confirmed,
              let environmentID = pairing?.confirmedEnvironmentID,
              !environmentID.isEmpty
        else {
            throw CodexRemoteControllerError.pairingVerificationRequired
        }
        let listing = try await list()
        let selected = try listing.selecting(environmentID: environmentID)
        let current = try await lifecycleStore.load(
            accountUserID: metadata.accountUserID,
            clientID: metadata.clientID
        )
        guard current?.state == .confirmed,
              current?.confirmedEnvironmentID == environmentID
        else {
            throw CodexRemoteControllerError.pairingVerificationRequired
        }
        return selected
    }
}

actor CodexRemoteControllerSessionManager {
    private let account: CodexRemoteAccountContext
    private let metadata: CodexRemoteEnrolmentMetadata
    private let transport: any CodexRemoteHTTPTransport
    private let identityProvider: any CodexRemoteDeviceIdentityProviding
    private let pairingLifecycleStore: any CodexRemotePairingLifecycleStoring
    private let now: @Sendable () -> Date
    private var refreshInProgress = false
    private var session: CodexRemoteControllerSession?

    init(
        account: CodexRemoteAccountContext,
        metadata: CodexRemoteEnrolmentMetadata,
        transport: any CodexRemoteHTTPTransport,
        identityProvider: any CodexRemoteDeviceIdentityProviding,
        pairingLifecycleStore: any CodexRemotePairingLifecycleStoring =
            CodexRemotePairingLifecycleStore.shared,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.account = account
        self.metadata = metadata
        self.transport = transport
        self.identityProvider = identityProvider
        self.pairingLifecycleStore = pairingLifecycleStore
        self.now = now
    }

    func currentValidSession() -> CodexRemoteControllerSession? {
        guard let session, session.isValid(at: now()) else {
            self.session = nil
            return nil
        }
        return session
    }

    func invalidateSession() {
        session = nil
    }

    func refresh(
        authenticationReason: String =
            "Use Face ID to connect NightBlood to your paired Codex Mac."
    ) async throws -> CodexRemoteControllerSession {
        guard !refreshInProgress else {
            throw CodexRemoteControllerError.refreshAlreadyInProgress
        }
        refreshInProgress = true
        defer { refreshInProgress = false }

        try CodexRemoteControllerValidation.validate(
            account: account,
            metadata: metadata,
            now: now()
        )
        let pairing = try await pairingLifecycleStore.load(
            accountUserID: metadata.accountUserID,
            clientID: metadata.clientID
        )
        guard pairing?.state == .confirmed else {
            throw CodexRemoteControllerError.pairingVerificationRequired
        }
        let startBody = CodexRemoteRefreshStartRequest(clientID: metadata.clientID)
        let startRequest = try CodexRemoteControllerRESTFactory.request(
            account: account,
            method: .post,
            path: CodexRemoteControllerConstants.refreshStartPath,
            body: startBody
        )
        let startHTTP = try await transport.send(startRequest)
        try CodexRemoteControllerRESTFactory.validateSuccess(startHTTP)
        let start = try CodexRemoteControllerRESTFactory.decode(
            CodexRemoteRefreshStartResponse.self,
            from: startHTTP
        )
        guard start.clientID == metadata.clientID else {
            throw CodexRemoteControllerError.clientMismatch
        }
        guard start.accountUserID == metadata.accountUserID else {
            throw CodexRemoteControllerError.accountMismatch
        }

        let proof = try await CodexRemoteControllerChallengeSigner
            .signEnrollmentChallenge(
                start.deviceKeyChallenge,
                expectedPath: CodexRemoteControllerConstants.refreshFinishPath,
                requireDeviceIdentityHash: true,
                accountUserID: metadata.accountUserID,
                clientID: metadata.clientID,
                identity: metadata.identity,
                identityProvider: identityProvider,
                authenticationReason: authenticationReason
            )
        let finishBody = CodexRemoteRefreshFinishRequest(
            clientID: metadata.clientID,
            deviceKeyProof: proof
        )
        let finishRequest = try CodexRemoteControllerRESTFactory.request(
            account: account,
            method: .post,
            path: CodexRemoteControllerConstants.refreshFinishPath,
            body: finishBody
        )
        // Deliberately one send only. A failed finish starts a fresh challenge
        // on the next explicit refresh; this challenge is never replayed.
        let finishHTTP = try await transport.send(finishRequest)
        try CodexRemoteControllerRESTFactory.validateSuccess(finishHTTP)
        let finish = try CodexRemoteControllerRESTFactory.decode(
            CodexRemoteRefreshFinishResponse.self,
            from: finishHTTP
        )
        guard finish.clientID == metadata.clientID else {
            throw CodexRemoteControllerError.clientMismatch
        }
        guard finish.accountUserID == metadata.accountUserID else {
            throw CodexRemoteControllerError.accountMismatch
        }
        guard finish.scopes == [CodexRemoteEnrolmentConstants.controllerScope]
        else {
            throw CodexRemoteControllerError.unexpectedControllerScope
        }
        guard !finish.token.isEmpty else {
            throw CodexRemoteControllerError.invalidResponse
        }
        let expiration = try Self.parseExpiration(finish.expiresAt)
        guard TimeInterval(expiration) > now().timeIntervalSince1970 else {
            throw CodexRemoteControllerError.sessionExpired
        }

        let issued = CodexRemoteControllerSession(
            clientID: metadata.clientID,
            accountUserID: metadata.accountUserID,
            token: finish.token,
            expiresAt: expiration,
            scopes: finish.scopes
        )
        session = issued
        return issued
    }

    private static func parseExpiration(
        _ value: CodexRemoteExpirationValue
    ) throws -> Int64 {
        switch value {
        case .integer(let integer):
            return integer
        case .number(let number):
            guard number.isFinite,
                  number.rounded(.towardZero) == number,
                  number >= Double(Int64.min),
                  number <= Double(Int64.max)
            else {
                throw CodexRemoteControllerError.invalidExpiration
            }
            return Int64(number)
        case .string(let string):
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [
                .withInternetDateTime,
                .withFractionalSeconds,
            ]
            let fallback = ISO8601DateFormatter()
            fallback.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: string)
                    ?? fallback.date(from: string)
            else {
                throw CodexRemoteControllerError.invalidExpiration
            }
            let seconds = date.timeIntervalSince1970
            guard seconds.isFinite,
                  seconds >= Double(Int64.min),
                  seconds <= Double(Int64.max)
            else {
                throw CodexRemoteControllerError.invalidExpiration
            }
            return Int64(seconds)
        }
    }
}
