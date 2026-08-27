import Foundation
import Security

protocol CodexRemoteDeviceIdentityProviding: Sendable {
    func createIdentity() async throws -> CodexRemoteDeviceIdentity
    func sign(
        payloadJSON: Data,
        with keyID: String,
        authenticationReason: String
    ) async throws -> CodexRemoteDeviceSignature
    func deleteIdentity(keyID: String) async throws
}

/// Production adapter for the existing Secure Enclave actor. Tests should
/// inject an in-memory provider and must not create a real key.
actor CodexRemoteSecureEnclaveIdentityProvider: CodexRemoteDeviceIdentityProviding {
    private static let applicationTagPrefix =
        "com.example.nightblood.remote.codex-device-key."
    private let store: CodexRemoteDeviceIdentityStore

    init(store: CodexRemoteDeviceIdentityStore = .shared) {
        self.store = store
    }

    func createIdentity() async throws -> CodexRemoteDeviceIdentity {
        try await store.createIdentity()
    }

    func sign(
        payloadJSON: Data,
        with keyID: String,
        authenticationReason: String
    ) async throws -> CodexRemoteDeviceSignature {
        try await store.sign(
            payloadJSON: payloadJSON,
            with: keyID,
            authenticationReason: authenticationReason
        )
    }

    /// This is used only for a failure that is known to have happened before
    /// enrol-finish could complete. Unknown or unvalidated finishes always
    /// preserve the key for recovery.
    func deleteIdentity(keyID: String) throws {
        guard let uuid = UUID(uuidString: keyID) else {
            throw CodexRemoteEnrolmentError.invalidDeviceIdentity
        }
        let normalisedKeyID = uuid.uuidString.lowercased()
        let applicationTag = Data(
            "\(Self.applicationTagPrefix)\(normalisedKeyID)".utf8
        )
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: applicationTag,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CodexRemoteEnrolmentError.cleanupRequired
        }
    }
}

actor CodexRemoteEnrolment {
    private let transport: any CodexRemoteHTTPTransport
    private let stepUpAuthorizer: any CodexRemoteStepUpAuthorizing
    private let identityProvider: any CodexRemoteDeviceIdentityProviding
    private let metadataStore: any CodexRemoteEnrolmentMetadataStoring
    private let now: @Sendable () -> Date
    private var operationInProgress = false
    private var cancellationRequested = false
    private var finishTask: Task<CodexRemoteHTTPResponse, Error>?

    init(
        transport: any CodexRemoteHTTPTransport = CodexRemoteURLSessionTransport(),
        stepUpAuthorizer: (any CodexRemoteStepUpAuthorizing)? = nil,
        identityProvider: any CodexRemoteDeviceIdentityProviding =
            CodexRemoteSecureEnclaveIdentityProvider(),
        metadataStore: any CodexRemoteEnrolmentMetadataStoring =
            CodexRemoteEnrolmentMetadataStore(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.transport = transport
        self.stepUpAuthorizer = stepUpAuthorizer
            ?? CodexRemoteStepUpOAuth(transport: transport, now: now)
        self.identityProvider = identityProvider
        self.metadataStore = metadataStore
        self.now = now
    }

    /// Enrols one controller identity. This method deliberately has no retry
    /// path: any existing lifecycle record must be reviewed or cleaned up by a
    /// separate, explicit recovery flow.
    func enrol(
        ordinaryAccessToken: String,
        stepUpTimeout: Duration = .seconds(600),
        presentSafari: CodexOAuthSafariPresentation
    ) async throws -> CodexRemoteEnrolmentMetadata {
        guard !operationInProgress else {
            throw CodexRemoteEnrolmentError.alreadyInProgress
        }
        operationInProgress = true
        cancellationRequested = false
        defer {
            finishTask?.cancel()
            finishTask = nil
            cancellationRequested = false
            operationInProgress = false
        }

        return try await withTaskCancellationHandler {
            try await performEnrolment(
                ordinaryAccessToken: ordinaryAccessToken,
                stepUpTimeout: stepUpTimeout,
                presentSafari: presentSafari
            )
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    func cancel() async {
        cancellationRequested = true
        finishTask?.cancel()
        await stepUpAuthorizer.cancel()
    }

    func storedMetadata() async throws -> CodexRemoteEnrolmentMetadata? {
        try await metadataStore.load()
    }

    private func performEnrolment(
        ordinaryAccessToken: String,
        stepUpTimeout: Duration,
        presentSafari: CodexOAuthSafariPresentation
    ) async throws -> CodexRemoteEnrolmentMetadata {
        if let existing = try await metadataStore.load() {
            throw CodexRemoteEnrolmentError.existingState(existing.state)
        }
        try ensureNotCancelled()
        let account = try CodexRemoteAccountContext.parse(
            accessToken: ordinaryAccessToken,
            now: now()
        )
        let rest = CodexRemoteAuthenticatedRESTClient(
            account: account,
            transport: transport
        )
        let started = try await rest.enrolStart()
        try ensureNotCancelled()
        try validateStart(started, account: account)

        let identity = try await identityProvider.createIdentity()
        var metadata = CodexRemoteEnrolmentMetadata(
            accountUserID: started.accountUserID,
            clientID: started.clientID,
            identity: identity,
            state: .authorising
        )
        do {
            try await metadataStore.create(metadata)
        } catch {
            do {
                try await identityProvider.deleteIdentity(keyID: identity.keyID)
            } catch {
                throw CodexRemoteEnrolmentError.cleanupRequired
            }
            throw error
        }

        var phase = CodexRemoteEnrolmentState.authorising
        do {
            try ensureNotCancelled()
            let signing = try CodexRemoteEnrolmentCryptography
                .validateAndMakeSigningPayload(
                    challenge: started.deviceKeyChallenge,
                    identity: identity,
                    accountUserID: started.accountUserID,
                    clientID: started.clientID
                )
            let payloadJSON = try CodexRemoteEnrolmentCryptography
                .encodeSigningPayload(signing.payload)
            let stepUpToken = try await stepUpAuthorizer.authorize(
                accountID: account.accountID,
                accountUserID: account.accountUserID,
                timeout: stepUpTimeout,
                presentSafari: presentSafari
            )
            try ensureNotCancelled()
            let signature = try await identityProvider.sign(
                payloadJSON: payloadJSON,
                with: identity.keyID,
                authenticationReason: "Authorise Codex Remote enrolment"
            )
            try ensureNotCancelled()
            let proof = try CodexRemoteEnrolmentCryptography.validateAndMakeProof(
                challengeToken: started.deviceKeyChallenge.challengeToken,
                identity: identity,
                payloadJSON: payloadJSON,
                signature: signature
            )
            let finishRequest = CodexRemoteEnrolFinishRequest(
                clientID: started.clientID,
                stepUpToken: stepUpToken.rawValue,
                deviceIdentity: CodexRemoteDeviceIdentityWire(identity),
                deviceKeyProof: proof
            )
            // Encode locally before recording finish-in-flight. A failure here
            // proves that no enrol-finish request could have been transmitted.
            let encodedFinish = try rest.encodeEnrolFinish(finishRequest)

            metadata = metadata.transitioning(to: .finishInFlight)
            try await metadataStore.update(metadata)
            phase = .finishInFlight
            // Actor re-entrancy during the Keychain write may have delivered a
            // cancellation. Check once more before any mutation can be sent.
            try ensureNotCancelled()

            let response: CodexRemoteHTTPResponse
            let task = Task {
                try await rest.sendEnrolFinish(encodedBody: encodedFinish)
            }
            finishTask = task
            do {
                response = try await task.value
                finishTask = nil
            } catch {
                finishTask = nil
                phase = .finishUnknown
                metadata = metadata.transitioning(to: .finishUnknown)
                try? await metadataStore.update(metadata)
                throw CodexRemoteEnrolmentError.enrolmentFinishUnknown
            }

            // No private-protocol status is documented as proving that this
            // mutation did not commit. A 4xx, timeout status or 5xx may still
            // arrive after enrolment executed, so every non-2xx result is
            // fail-unknown and preserves the matching key and metadata.
            guard (200...299).contains(response.statusCode) else {
                phase = .finishUnknown
                metadata = metadata.transitioning(to: .finishUnknown)
                try? await metadataStore.update(metadata)
                throw CodexRemoteEnrolmentError.enrolmentFinishUnknown
            }
            phase = .finishReturnedUnvalidated
            metadata = metadata.transitioning(to: .finishReturnedUnvalidated)
            try await metadataStore.update(metadata)

            do {
                let finished = try JSONDecoder().decode(
                    CodexRemoteEnrolFinishResponse.self,
                    from: response.body
                )
                try validateFinish(
                    finished,
                    accountUserID: started.accountUserID,
                    clientID: started.clientID
                )
            } catch {
                phase = .reviewRequired
                metadata = metadata.transitioning(to: .reviewRequired)
                try? await metadataStore.update(metadata)
                throw CodexRemoteEnrolmentError.reviewRequired
            }

            do {
                let enrolled = metadata.transitioning(to: .enrolled)
                try await metadataStore.update(enrolled)
                phase = .enrolled
                return enrolled
            } catch {
                phase = .reviewRequired
                metadata = metadata.transitioning(to: .reviewRequired)
                try? await metadataStore.update(metadata)
                throw CodexRemoteEnrolmentError.reviewRequired
            }
        } catch {
            switch phase {
            case .finishUnknown:
                throw CodexRemoteEnrolmentError.enrolmentFinishUnknown
            case .finishReturnedUnvalidated, .reviewRequired, .enrolled:
                if phase != .enrolled {
                    metadata = metadata.transitioning(to: .reviewRequired)
                    try? await metadataStore.update(metadata)
                }
                throw error
            case .authorising, .finishInFlight, .cleanupRequired:
                do {
                    try await identityProvider.deleteIdentity(keyID: identity.keyID)
                    try await metadataStore.delete(ifMatching: metadata)
                } catch {
                    metadata = metadata.transitioning(to: .cleanupRequired)
                    try? await metadataStore.update(metadata)
                    throw CodexRemoteEnrolmentError.cleanupRequired
                }
                if error is CancellationError {
                    throw CodexRemoteEnrolmentError.cancelled
                }
                throw error
            }
        }
    }

    private func ensureNotCancelled() throws {
        guard !cancellationRequested, !Task.isCancelled else {
            throw CodexRemoteEnrolmentError.cancelled
        }
    }

    private func validateStart(
        _ started: CodexRemoteEnrolStartResponse,
        account: CodexRemoteAccountContext
    ) throws {
        guard !started.clientID.isEmpty else {
            throw CodexRemoteEnrolmentError.invalidResponse
        }
        let acceptedAccountIDs = Set(
            [account.accountUserID, account.tokenUserID].compactMap { $0 }
        )
        guard acceptedAccountIDs.contains(started.accountUserID) else {
            throw CodexRemoteEnrolmentError.accountMismatch
        }
    }

    private func validateFinish(
        _ finished: CodexRemoteEnrolFinishResponse,
        accountUserID: String,
        clientID: String
    ) throws {
        guard finished.clientID == clientID else {
            throw CodexRemoteEnrolmentError.clientMismatch
        }
        guard finished.accountUserID == accountUserID else {
            throw CodexRemoteEnrolmentError.accountMismatch
        }
        guard finished.scopes == [CodexRemoteEnrolmentConstants.controllerScope]
        else {
            throw CodexRemoteEnrolmentError.unexpectedControllerScope
        }
    }
}
