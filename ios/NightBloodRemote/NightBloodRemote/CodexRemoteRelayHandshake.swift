import CryptoKit
import Foundation

enum CodexRemoteControllerChallengeSigner {
    private static let enrolmentPurpose = "remote_control_client_enrollment"
    private static let enrolmentAudience = "remote_control_client_enrollment"

    static func signEnrollmentChallenge(
        _ challenge: CodexRemoteDeviceKeyChallenge,
        expectedPath: String,
        requireDeviceIdentityHash: Bool,
        accountUserID: String,
        clientID: String,
        identity: CodexRemoteDeviceIdentity,
        identityProvider: any CodexRemoteDeviceIdentityProviding,
        authenticationReason: String
    ) async throws -> CodexRemoteDeviceKeyProofWire {
        let expected: [(String, String, String)] = [
            ("purpose", challenge.purpose, enrolmentPurpose),
            ("audience", challenge.audience, enrolmentAudience),
            ("account_user_id", challenge.accountUserID, accountUserID),
            ("client_id", challenge.clientID, clientID),
            (
                "target_origin",
                challenge.targetOrigin,
                CodexRemoteControllerConstants.expectedOrigin
            ),
            (
                "target_path",
                challenge.targetPath,
                "/backend-api/\(expectedPath)"
            ),
        ]
        for (field, actual, required) in expected where actual != required {
            throw CodexRemoteControllerError.invalidChallenge(field: field)
        }
        for (field, value) in [
            ("nonce", challenge.nonce),
            ("challenge_id", challenge.challengeID),
            ("challenge_token", challenge.challengeToken),
        ] where value.isEmpty {
            throw CodexRemoteControllerError.invalidChallenge(field: field)
        }

        let localIdentityHash = try CodexRemoteEnrolmentCryptography
            .deviceIdentityHash(identity)
        if requireDeviceIdentityHash,
           challenge.deviceIdentityHash == nil
        {
            throw CodexRemoteControllerError.invalidChallenge(
                field: "device_identity_hash"
            )
        }
        if let challengedHash = challenge.deviceIdentityHash,
           challengedHash != localIdentityHash
        {
            throw CodexRemoteControllerError.invalidChallenge(
                field: "device_identity_hash"
            )
        }

        let payload = CodexRemoteEnrollmentSigningPayload(
            nonce: challenge.nonce,
            audience: enrolmentAudience,
            challengeID: challenge.challengeID,
            targetOrigin: challenge.targetOrigin,
            targetPath: challenge.targetPath,
            accountUserID: accountUserID,
            clientID: clientID,
            deviceIdentitySHA256Base64URL:
                challenge.deviceIdentityHash ?? localIdentityHash,
            challengeExpiresAt: challenge.challengeExpiresAt
        )
        let payloadJSON = try CodexRemoteEnrolmentCryptography
            .encodeSigningPayload(payload)
        let signature = try await identityProvider.sign(
            payloadJSON: payloadJSON,
            with: identity.keyID,
            authenticationReason: authenticationReason
        )
        do {
            return try CodexRemoteEnrolmentCryptography.validateAndMakeProof(
                challengeToken: challenge.challengeToken,
                identity: identity,
                payloadJSON: payloadJSON,
                signature: signature
            )
        } catch {
            throw CodexRemoteControllerError.invalidDeviceProof
        }
    }
}

/// A token-bearing URLRequest wrapped in a redacted value. Callers can unwrap
/// it only to hand it to an injected WebSocket transport.
struct CodexRemoteWebSocketRequest: @unchecked Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    private let request: URLRequest

    init(_ request: URLRequest) {
        self.request = request
    }

    func makeURLRequest() -> URLRequest { request }

    var description: String { "CodexRemoteWebSocketRequest(<redacted>)" }
    var debugDescription: String { description }
}

/// The production URLSession adapter is intentionally outside this offline
/// layer. Tests can inject a scripted connection without opening a socket.
protocol CodexRemoteWebSocketTransport: Sendable {
    func open(
        _ request: CodexRemoteWebSocketRequest
    ) async throws -> any CodexRemoteWebSocketConnection
}

protocol CodexRemoteWebSocketConnection: Sendable {
    func receive() async throws -> Data
    func send(_ data: Data) async throws
    func close() async
}

enum CodexRemoteWebSocketRequestFactory {
    static func make(
        account: CodexRemoteAccountContext,
        metadata: CodexRemoteEnrolmentMetadata,
        session: CodexRemoteControllerSession,
        now: Date = Date()
    ) throws -> CodexRemoteWebSocketRequest {
        try CodexRemoteControllerValidation.validate(
            session: session,
            account: account,
            metadata: metadata,
            now: now
        )
        let url = CodexRemoteControllerConstants.webSocketURL
        guard url.scheme == "wss",
              url.host == "chatgpt.com",
              url.path == "/backend-api/\(CodexRemoteControllerConstants.webSocketPath)"
        else {
            throw CodexRemoteControllerError.insecureWebSocketEndpoint
        }
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 30
        )
        request.httpMethod = "GET"
        request.setValue(
            "Bearer \(account.accessToken)",
            forHTTPHeaderField: "Authorization"
        )
        request.setValue(
            account.accountID,
            forHTTPHeaderField: "ChatGPT-Account-Id"
        )
        request.setValue(
            CodexRemoteEnrolmentConstants.clientUserAgent,
            forHTTPHeaderField: "OpenAI-Client-User-Agent"
        )
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(
            "Bearer \(session.token)",
            forHTTPHeaderField: "x-codex-client-session-token"
        )
        request.setValue(
            session.clientID,
            forHTTPHeaderField: "x-codex-client-id"
        )
        request.setValue(
            CodexRemoteControllerConstants.protocolVersion,
            forHTTPHeaderField: "x-codex-protocol-version"
        )
        return CodexRemoteWebSocketRequest(request)
    }
}

struct CodexRemoteRelayDeviceKeyChallenge: Decodable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    let type: String
    let purpose: String
    let audience: String
    let nonce: String
    let sessionID: String
    let targetOrigin: String
    let targetPath: String
    let accountUserID: String
    let clientID: String
    let tokenSHA256Base64URL: String
    let tokenExpiresAt: Int64
    let scopes: [String]

    private enum CodingKeys: String, CodingKey {
        case type
        case purpose
        case audience
        case nonce
        case sessionID = "sessionId"
        case targetOrigin
        case targetPath
        case accountUserID = "accountUserId"
        case clientID = "clientId"
        case tokenSHA256Base64URL = "tokenSha256Base64url"
        case tokenExpiresAt
        case scopes
    }

    var description: String {
        "CodexRemoteRelayDeviceKeyChallenge(<redacted>)"
    }
    var debugDescription: String { description }
}

struct CodexRemoteRelayDeviceKeyProof: Encodable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    let type = "device_key_proof"
    let keyID: String
    let signatureDERBase64: String
    let signedPayloadBase64: String
    let algorithm: String

    private enum CodingKeys: String, CodingKey {
        case type
        case keyID = "keyId"
        case signatureDERBase64 = "signatureDerBase64"
        case signedPayloadBase64
        case algorithm
    }

    var description: String { "CodexRemoteRelayDeviceKeyProof(<redacted>)" }
    var debugDescription: String { description }
}

private struct CodexRemoteRelaySigningPayload: Encodable, Sendable {
    let type = "remoteControlClientConnection"
    let nonce: String
    let audience: String
    let sessionID: String
    let targetOrigin: String
    let targetPath: String
    let accountUserID: String
    let clientID: String
    let tokenSHA256Base64URL: String
    let tokenExpiresAt: Int64
    let scopes: [String]

    private enum CodingKeys: String, CodingKey {
        case type
        case nonce
        case audience
        case sessionID = "sessionId"
        case targetOrigin
        case targetPath
        case accountUserID = "accountUserId"
        case clientID = "clientId"
        case tokenSHA256Base64URL = "tokenSha256Base64url"
        case tokenExpiresAt
        case scopes
    }
}

enum CodexRemoteRelayChallengeSigner {
    private static let purpose = "remote_control_client_websocket"
    private static let audience = "remote_control_client_websocket"
    private static let signingDomain = "codex-device-key-sign-payload/v1"

    static func decode(_ data: Data) throws -> CodexRemoteRelayDeviceKeyChallenge {
        guard data.count <= CodexRemoteControllerConstants.maximumWebSocketMessageBytes
        else {
            throw CodexRemoteControllerError.invalidWebSocketMessage
        }
        do {
            return try JSONDecoder().decode(
                CodexRemoteRelayDeviceKeyChallenge.self,
                from: data
            )
        } catch {
            throw CodexRemoteControllerError.invalidWebSocketMessage
        }
    }

    static func sign(
        challenge: CodexRemoteRelayDeviceKeyChallenge,
        account: CodexRemoteAccountContext,
        metadata: CodexRemoteEnrolmentMetadata,
        session: CodexRemoteControllerSession,
        identityProvider: any CodexRemoteDeviceIdentityProviding,
        authenticationReason: String =
            "Use Face ID to prove this iPhone may control your paired Codex Mac.",
        now: Date = Date()
    ) async throws -> CodexRemoteRelayDeviceKeyProof {
        try CodexRemoteControllerValidation.validate(
            session: session,
            account: account,
            metadata: metadata,
            now: now
        )
        let expectedTokenHash = base64URL(
            Data(SHA256.hash(data: Data(session.token.utf8)))
        )
        let expected: [(String, String, String)] = [
            ("type", challenge.type, "device_key_challenge"),
            ("purpose", challenge.purpose, purpose),
            ("audience", challenge.audience, audience),
            ("accountUserId", challenge.accountUserID, metadata.accountUserID),
            ("clientId", challenge.clientID, metadata.clientID),
            (
                "targetOrigin",
                challenge.targetOrigin,
                CodexRemoteControllerConstants.expectedOrigin
            ),
            (
                "targetPath",
                challenge.targetPath,
                "/backend-api/\(CodexRemoteControllerConstants.webSocketPath)"
            ),
            (
                "tokenSha256Base64url",
                challenge.tokenSHA256Base64URL,
                expectedTokenHash
            ),
        ]
        for (field, actual, required) in expected where actual != required {
            throw CodexRemoteControllerError.invalidChallenge(field: field)
        }
        for (field, value) in [
            ("nonce", challenge.nonce),
            ("sessionId", challenge.sessionID),
        ] where value.isEmpty {
            throw CodexRemoteControllerError.invalidChallenge(field: field)
        }
        guard challenge.tokenExpiresAt == session.expiresAt,
              TimeInterval(challenge.tokenExpiresAt) > now.timeIntervalSince1970
        else {
            throw CodexRemoteControllerError.invalidChallenge(
                field: "tokenExpiresAt"
            )
        }
        guard challenge.scopes == session.scopes,
              challenge.scopes == [
                  CodexRemoteEnrolmentConstants.controllerScope
              ]
        else {
            throw CodexRemoteControllerError.invalidChallenge(field: "scopes")
        }

        let payload = CodexRemoteRelaySigningPayload(
            nonce: challenge.nonce,
            audience: challenge.audience,
            sessionID: challenge.sessionID,
            targetOrigin: challenge.targetOrigin,
            targetPath: challenge.targetPath,
            accountUserID: challenge.accountUserID,
            clientID: challenge.clientID,
            tokenSHA256Base64URL: challenge.tokenSHA256Base64URL,
            tokenExpiresAt: challenge.tokenExpiresAt,
            scopes: challenge.scopes
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payloadJSON: Data
        do {
            payloadJSON = try encoder.encode(payload)
        } catch {
            throw CodexRemoteControllerError.invalidDeviceProof
        }
        let signature = try await identityProvider.sign(
            payloadJSON: payloadJSON,
            with: metadata.keyID,
            authenticationReason: authenticationReason
        )
        try validate(
            signature: signature,
            identity: metadata.identity,
            payloadJSON: payloadJSON
        )
        return CodexRemoteRelayDeviceKeyProof(
            keyID: metadata.keyID,
            signatureDERBase64: signature.signatureDERBase64,
            signedPayloadBase64: signature.signedPayloadBase64,
            algorithm: signature.algorithm
        )
    }

    static func encode(
        _ proof: CodexRemoteRelayDeviceKeyProof
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(proof)
        } catch {
            throw CodexRemoteControllerError.invalidDeviceProof
        }
    }

    private static func validate(
        signature: CodexRemoteDeviceSignature,
        identity: CodexRemoteDeviceIdentity,
        payloadJSON: Data
    ) throws {
        guard signature.algorithm == identity.algorithm,
              !signature.signatureDERBase64.isEmpty,
              Data(base64Encoded: signature.signatureDERBase64) != nil,
              let actualEnvelope = Data(
                  base64Encoded: signature.signedPayloadBase64
              )
        else {
            throw CodexRemoteControllerError.invalidDeviceProof
        }
        let payloadObject: Any
        do {
            payloadObject = try JSONSerialization.jsonObject(with: payloadJSON)
        } catch {
            throw CodexRemoteControllerError.invalidDeviceProof
        }
        guard payloadObject is [String: Any] else {
            throw CodexRemoteControllerError.invalidDeviceProof
        }
        let expectedEnvelope: Data
        do {
            expectedEnvelope = try JSONSerialization.data(
                withJSONObject: [
                    "domain": signingDomain,
                    "payload": payloadObject,
                ],
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        } catch {
            throw CodexRemoteControllerError.invalidDeviceProof
        }
        guard actualEnvelope == expectedEnvelope else {
            throw CodexRemoteControllerError.invalidDeviceProof
        }
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
