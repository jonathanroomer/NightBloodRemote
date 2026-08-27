import CryptoKit
import Foundation
import Security

enum CodexRemotePairingLifecycleState: String, Codable, Sendable {
    case ready
    case inFlight = "in_flight"
    case outcomeUnknown = "outcome_unknown"
    case responseReceivedUnverified = "response_received_unverified"
    case confirmed
}

struct CodexRemotePairingLifecycleRecord: Codable, Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    let accountUserID: String
    let clientID: String
    let state: CodexRemotePairingLifecycleState
    let confirmedEnvironmentID: String?

    var description: String {
        "CodexRemotePairingLifecycleRecord(state: \(state.rawValue), identity: <redacted>)"
    }
    var debugDescription: String { description }
}

protocol CodexRemotePairingLifecycleStoring: Sendable {
    func prepare(
        accountUserID: String,
        clientID: String
    ) async throws -> CodexRemotePairingLifecycleRecord

    func transition(
        accountUserID: String,
        clientID: String,
        from expectedStates: Set<CodexRemotePairingLifecycleState>,
        to state: CodexRemotePairingLifecycleState
    ) async throws -> CodexRemotePairingLifecycleRecord

    func confirmAfterEnvironmentVerification(
        _ binding: CodexRemoteVerifiedEnvironmentBinding
    ) async throws -> CodexRemotePairingLifecycleRecord

    func load(
        accountUserID: String,
        clientID: String
    ) async throws -> CodexRemotePairingLifecycleRecord?
}

/// Durable fail-unknown state for the one-time manual pairing mutation.
///
/// `in_flight`, `outcome_unknown` and `response_received_unverified` are never
/// automatically cleared. A fresh, client-scoped environment listing is the
/// only transition this layer provides to `confirmed`.
actor CodexRemotePairingLifecycleStore: CodexRemotePairingLifecycleStoring {
    static let shared = CodexRemotePairingLifecycleStore()
    static let defaultService =
        "com.example.nightblood.remote.codex-controller-pairing-lifecycle"

    private let service: String

    init(
        service: String = CodexRemotePairingLifecycleStore.defaultService
    ) {
        self.service = service
    }

    func prepare(
        accountUserID: String,
        clientID: String
    ) throws -> CodexRemotePairingLifecycleRecord {
        try validateIdentifiers(accountUserID: accountUserID, clientID: clientID)
        if let existing = try load(
            accountUserID: accountUserID,
            clientID: clientID
        ) {
            return existing
        }
        let record = CodexRemotePairingLifecycleRecord(
            accountUserID: accountUserID,
            clientID: clientID,
            state: .ready,
            confirmedEnvironmentID: nil
        )
        var item = baseQuery(accountUserID: accountUserID, clientID: clientID)
        item[kSecValueData as String] = try encode(record)
        item[kSecAttrAccessible as String] =
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem,
           let existing = try load(
               accountUserID: accountUserID,
               clientID: clientID
           )
        {
            return existing
        }
        guard status == errSecSuccess else {
            throw CodexRemoteEnrolmentError.keychain(status: status)
        }
        return record
    }

    func transition(
        accountUserID: String,
        clientID: String,
        from expectedStates: Set<CodexRemotePairingLifecycleState>,
        to state: CodexRemotePairingLifecycleState
    ) throws -> CodexRemotePairingLifecycleRecord {
        guard let current = try load(
            accountUserID: accountUserID,
            clientID: clientID
        ), expectedStates.contains(current.state) else {
            throw CodexRemoteControllerError.pairingAttemptAlreadyConsumed
        }
        let replacement = CodexRemotePairingLifecycleRecord(
            accountUserID: accountUserID,
            clientID: clientID,
            state: state,
            confirmedEnvironmentID:
                state == .confirmed ? current.confirmedEnvironmentID : nil
        )
        let attributes: [String: Any] = [
            kSecValueData as String: try encode(replacement),
            kSecAttrAccessible as String:
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemUpdate(
            baseQuery(accountUserID: accountUserID, clientID: clientID)
                as CFDictionary,
            attributes as CFDictionary
        )
        guard status == errSecSuccess else {
            throw CodexRemoteEnrolmentError.keychain(status: status)
        }
        return replacement
    }

    func confirmAfterEnvironmentVerification(
        _ binding: CodexRemoteVerifiedEnvironmentBinding
    ) throws -> CodexRemotePairingLifecycleRecord {
        let accountUserID = binding.accountUserID
        let clientID = binding.clientID
        let environmentID = binding.environmentID
        try validateIdentifiers(accountUserID: accountUserID, clientID: clientID)
        guard !environmentID.isEmpty, environmentID.utf8.count <= 4_096 else {
            throw CodexRemoteControllerError.environmentSelectionRequired
        }
        let confirmed = CodexRemotePairingLifecycleRecord(
            accountUserID: accountUserID,
            clientID: clientID,
            state: .confirmed,
            confirmedEnvironmentID: environmentID
        )
        let attributes: [String: Any] = [
            kSecValueData as String: try encode(confirmed),
            kSecAttrAccessible as String:
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let query = baseQuery(accountUserID: accountUserID, clientID: clientID)
        var status = SecItemUpdate(
            query as CFDictionary,
            attributes as CFDictionary
        )
        if status == errSecItemNotFound {
            var item = query
            item.merge(attributes) { _, new in new }
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw CodexRemoteEnrolmentError.keychain(status: status)
        }
        return confirmed
    }

    func load(
        accountUserID: String,
        clientID: String
    ) throws -> CodexRemotePairingLifecycleRecord? {
        try validateIdentifiers(accountUserID: accountUserID, clientID: clientID)
        var query = baseQuery(accountUserID: accountUserID, clientID: clientID)
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
        guard accessibility
            == (kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        else {
            throw CodexRemoteEnrolmentError.keychainProtectionMismatch
        }
        let record: CodexRemotePairingLifecycleRecord
        do {
            record = try JSONDecoder().decode(
                CodexRemotePairingLifecycleRecord.self,
                from: data
            )
        } catch {
            throw CodexRemoteControllerError.invalidPairingLifecycle
        }
        guard record.accountUserID == accountUserID,
              record.clientID == clientID,
              record.state != .confirmed
                || record.confirmedEnvironmentID?.isEmpty == false
        else {
            throw CodexRemoteControllerError.invalidPairingLifecycle
        }
        return record
    }

    private func baseQuery(
        accountUserID: String,
        clientID: String
    ) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: recordKey(
                accountUserID: accountUserID,
                clientID: clientID
            ),
            kSecAttrSynchronizable as String: false,
        ]
    }

    private func recordKey(accountUserID: String, clientID: String) -> String {
        let framed =
            "\(accountUserID.utf8.count):\(accountUserID)"
            + "\(clientID.utf8.count):\(clientID)"
        return SHA256.hash(data: Data(framed.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func encode(_ record: CodexRemotePairingLifecycleRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(record)
        } catch {
            throw CodexRemoteControllerError.invalidPairingLifecycle
        }
    }

    private func validateIdentifiers(
        accountUserID: String,
        clientID: String
    ) throws {
        guard !service.isEmpty,
              !accountUserID.isEmpty,
              !clientID.isEmpty,
              accountUserID.utf8.count <= 4_096,
              clientID.utf8.count <= 4_096
        else {
            throw CodexRemoteControllerError.invalidPairingLifecycle
        }
    }
}
