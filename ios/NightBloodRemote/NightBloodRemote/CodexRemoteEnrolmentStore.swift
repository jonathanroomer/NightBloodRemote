import Foundation
import Security

enum CodexRemoteEnrolmentState: String, Codable, Sendable {
    case authorising
    case finishInFlight = "finish_in_flight"
    case finishUnknown = "finish_unknown"
    case finishReturnedUnvalidated = "finish_returned_unvalidated"
    case reviewRequired = "review_required"
    case enrolled
    case cleanupRequired = "cleanup_required"
}

struct CodexRemoteEnrolmentMetadata: Codable, Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    let accountUserID: String
    let clientID: String
    let keyID: String
    let publicKeySPKIDERBase64: String
    let algorithm: String
    let protectionClass: String
    let state: CodexRemoteEnrolmentState

    init(
        accountUserID: String,
        clientID: String,
        identity: CodexRemoteDeviceIdentity,
        state: CodexRemoteEnrolmentState
    ) {
        self.accountUserID = accountUserID
        self.clientID = clientID
        keyID = identity.keyID
        publicKeySPKIDERBase64 = identity.publicKeySPKIDERBase64
        algorithm = identity.algorithm
        protectionClass = identity.protectionClass
        self.state = state
    }

    private init(
        accountUserID: String,
        clientID: String,
        keyID: String,
        publicKeySPKIDERBase64: String,
        algorithm: String,
        protectionClass: String,
        state: CodexRemoteEnrolmentState
    ) {
        self.accountUserID = accountUserID
        self.clientID = clientID
        self.keyID = keyID
        self.publicKeySPKIDERBase64 = publicKeySPKIDERBase64
        self.algorithm = algorithm
        self.protectionClass = protectionClass
        self.state = state
    }

    func transitioning(to state: CodexRemoteEnrolmentState) -> Self {
        Self(
            accountUserID: accountUserID,
            clientID: clientID,
            keyID: keyID,
            publicKeySPKIDERBase64: publicKeySPKIDERBase64,
            algorithm: algorithm,
            protectionClass: protectionClass,
            state: state
        )
    }

    var identity: CodexRemoteDeviceIdentity {
        CodexRemoteDeviceIdentity(
            algorithm: algorithm,
            keyID: keyID,
            protectionClass: protectionClass,
            publicKeySPKIDERBase64: publicKeySPKIDERBase64
        )
    }

    var description: String {
        "CodexRemoteEnrolmentMetadata(state: \(state.rawValue), identity: <redacted>)"
    }
    var debugDescription: String { description }
}

protocol CodexRemoteEnrolmentMetadataStoring: Sendable {
    func load() async throws -> CodexRemoteEnrolmentMetadata?
    func create(_ metadata: CodexRemoteEnrolmentMetadata) async throws
    func update(_ metadata: CodexRemoteEnrolmentMetadata) async throws
    func delete(ifMatching metadata: CodexRemoteEnrolmentMetadata) async throws
}

actor CodexRemoteEnrolmentMetadataStore: CodexRemoteEnrolmentMetadataStoring {
    static let defaultService =
        "com.example.nightblood.remote.codex-controller-enrolment"
    static let defaultAccount = "controller-identity"

    private let service: String
    private let account: String

    init(
        service: String = CodexRemoteEnrolmentMetadataStore.defaultService,
        account: String = CodexRemoteEnrolmentMetadataStore.defaultAccount
    ) {
        self.service = service
        self.account = account
    }

    func load() throws -> CodexRemoteEnrolmentMetadata? {
        var query = baseQuery
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess,
              let result = item as? [String: Any],
              let data = result[kSecValueData as String] as? Data
        else {
            throw CodexRemoteEnrolmentError.keychain(status: status)
        }
        let accessibility = result[kSecAttrAccessible as String] as? String
        guard accessibility == (kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        else {
            throw CodexRemoteEnrolmentError.keychainProtectionMismatch
        }
        let metadata: CodexRemoteEnrolmentMetadata
        do {
            metadata = try JSONDecoder().decode(
                CodexRemoteEnrolmentMetadata.self,
                from: data
            )
        } catch {
            throw CodexRemoteEnrolmentError.invalidStoredMetadata
        }
        try validate(metadata)
        return metadata
    }

    func create(_ metadata: CodexRemoteEnrolmentMetadata) throws {
        try validate(metadata)
        let data = try encode(metadata)
        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem {
            if let existing = try load() {
                throw CodexRemoteEnrolmentError.existingState(existing.state)
            }
            throw CodexRemoteEnrolmentError.invalidStoredMetadata
        }
        guard status == errSecSuccess else {
            throw CodexRemoteEnrolmentError.keychain(status: status)
        }
    }

    func update(_ metadata: CodexRemoteEnrolmentMetadata) throws {
        try validate(metadata)
        guard let current = try load() else {
            throw CodexRemoteEnrolmentError.invalidStoredMetadata
        }
        guard current.hasSameIdentity(as: metadata),
              Self.allowsTransition(from: current.state, to: metadata.state)
        else {
            throw CodexRemoteEnrolmentError.existingState(current.state)
        }
        let attributes: [String: Any] = [
            kSecValueData as String: try encode(metadata),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemUpdate(
            baseQuery as CFDictionary,
            attributes as CFDictionary
        )
        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                throw CodexRemoteEnrolmentError.invalidStoredMetadata
            }
            throw CodexRemoteEnrolmentError.keychain(status: status)
        }
    }

    func delete(ifMatching metadata: CodexRemoteEnrolmentMetadata) throws {
        if let current = try load() {
            guard current.hasSameIdentity(as: metadata) else {
                throw CodexRemoteEnrolmentError.existingState(current.state)
            }
        } else {
            return
        }
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CodexRemoteEnrolmentError.keychain(status: status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }

    private func encode(_ metadata: CodexRemoteEnrolmentMetadata) throws -> Data {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return try encoder.encode(metadata)
        } catch {
            throw CodexRemoteEnrolmentError.invalidStoredMetadata
        }
    }

    private func validate(_ metadata: CodexRemoteEnrolmentMetadata) throws {
        guard !metadata.accountUserID.isEmpty,
              !metadata.clientID.isEmpty,
              UUID(uuidString: metadata.keyID) != nil,
              metadata.algorithm == "ecdsa_p256_sha256",
              !metadata.protectionClass.isEmpty,
              let publicKey = Data(base64Encoded: metadata.publicKeySPKIDERBase64),
              publicKey.count == 91
        else {
            throw CodexRemoteEnrolmentError.invalidStoredMetadata
        }
    }

    private static func allowsTransition(
        from current: CodexRemoteEnrolmentState,
        to next: CodexRemoteEnrolmentState
    ) -> Bool {
        if current == next {
            return current == .reviewRequired || current == .cleanupRequired
        }
        switch (current, next) {
        case (.authorising, .finishInFlight),
             (.authorising, .cleanupRequired),
             (.finishInFlight, .finishUnknown),
             (.finishInFlight, .finishReturnedUnvalidated),
             (.finishInFlight, .reviewRequired),
             (.finishInFlight, .cleanupRequired),
             (.finishReturnedUnvalidated, .reviewRequired),
             (.finishReturnedUnvalidated, .enrolled):
            return true
        default:
            return false
        }
    }
}

private extension CodexRemoteEnrolmentMetadata {
    func hasSameIdentity(as other: Self) -> Bool {
        accountUserID == other.accountUserID
            && clientID == other.clientID
            && keyID == other.keyID
            && publicKeySPKIDERBase64 == other.publicKeySPKIDERBase64
            && algorithm == other.algorithm
            && protectionClass == other.protectionClass
    }
}
