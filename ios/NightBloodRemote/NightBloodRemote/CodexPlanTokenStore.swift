import Foundation
import Security

/// The three ChatGPT-plan OAuth credentials returned by the ordinary Codex
/// browser login. The custom descriptions deliberately never expose values.
public struct CodexPlanTokens: Codable, Sendable, Equatable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    public let accessToken: String
    public let refreshToken: String
    public let idToken: String

    public init(accessToken: String, refreshToken: String, idToken: String) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
    }

    public var description: String { "CodexPlanTokens(<redacted>)" }
    public var debugDescription: String { description }
}

/// Stores the complete token set as one Keychain value so callers never need
/// to coordinate three partially updated credentials.
public actor CodexPlanTokenStore {
    public static let defaultService =
        "com.example.nightblood.remote.codex-plan-oauth"
    public static let defaultAccount = "ordinary-codex-plan-tokens"

    private let service: String
    private let account: String

    public init(
        service: String = CodexPlanTokenStore.defaultService,
        account: String = CodexPlanTokenStore.defaultAccount
    ) {
        self.service = service
        self.account = account
    }

    public func load() throws -> CodexPlanTokens? {
        try validateConfiguration()

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
            throw CodexPlanOAuthError.keychain(status: status)
        }

        let accessibility = result[kSecAttrAccessible as String] as? String
        guard accessibility == (kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String) else {
            throw CodexPlanOAuthError.keychainProtectionMismatch
        }

        do {
            return try JSONDecoder().decode(CodexPlanTokens.self, from: data)
        } catch {
            throw CodexPlanOAuthError.invalidStoredTokens
        }
    }

    public func save(_ tokens: CodexPlanTokens) throws {
        try validateConfiguration()
        guard !tokens.accessToken.isEmpty,
              !tokens.refreshToken.isEmpty,
              !tokens.idToken.isEmpty
        else {
            throw CodexPlanOAuthError.invalidTokenResponse
        }

        let data: Data
        do {
            data = try JSONEncoder().encode(tokens)
        } catch {
            throw CodexPlanOAuthError.invalidTokenResponse
        }

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        var status = SecItemUpdate(
            baseQuery as CFDictionary,
            attributes as CFDictionary
        )

        if status == errSecItemNotFound {
            var item = baseQuery
            item.merge(attributes) { _, new in new }
            status = SecItemAdd(item as CFDictionary, nil)

            // A second store instance may have won the add race. Update the
            // now-existing item rather than leaving a stale token set.
            if status == errSecDuplicateItem {
                status = SecItemUpdate(
                    baseQuery as CFDictionary,
                    attributes as CFDictionary
                )
            }
        }

        guard status == errSecSuccess else {
            throw CodexPlanOAuthError.keychain(status: status)
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

    private func validateConfiguration() throws {
        guard !service.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw CodexPlanOAuthError.invalidKeychainConfiguration
        }
    }
}
