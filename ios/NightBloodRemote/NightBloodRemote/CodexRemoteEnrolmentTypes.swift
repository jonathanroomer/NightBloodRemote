import CryptoKit
import Foundation
import Security

enum CodexRemoteEnrolmentConstants {
    static let APIBaseURL = URL(string: "https://chatgpt.com/backend-api/")!
    static let authorizationEndpoint = URL(
        string: "https://auth.openai.com/oauth/authorize"
    )!
    static let tokenEndpoint = URL(string: "https://auth.openai.com/oauth/token")!
    static var OAuthClientID: String { CodexPlanOAuthConstants.clientID }
    static let stepUpScope = "codex.remote_control.enroll"
    static let controllerScope = "remote_control_controller_websocket"
    static let originator = "NightBlood Remote"
    static let clientUserAgent = "NightBlood Remote"
    static let enrolStartPath = "codex/remote/control/client/enroll/start"
    static let enrolFinishPath = "codex/remote/control/client/enroll/finish"
    static let stepUpMaximumAgeSeconds: TimeInterval = 300
}

enum CodexRemoteEnrolmentError: Error, LocalizedError, Sendable {
    case alreadyInProgress
    case existingState(CodexRemoteEnrolmentState)
    case malformedOrdinaryAccessToken
    case missingAccountClaims
    case ordinaryAccessTokenNeedsRefresh
    case malformedStepUpToken
    case stepUpAccountMismatch
    case staleStepUpAuthentication
    case stepUpPasswordAuthenticationMissing
    case unexpectedStepUpScope
    case applicationNotActive
    case invalidAuthorizationURL
    case invalidTimeout
    case randomGenerationFailed(status: OSStatus)
    case transportFailed
    case responseRejected(statusCode: Int)
    case oversizedResponse
    case invalidResponse
    case accountMismatch
    case clientMismatch
    case invalidChallenge(field: String)
    case invalidDeviceIdentity
    case invalidDeviceProof
    case unexpectedControllerScope
    case enrolmentFinishUnknown
    case reviewRequired
    case cleanupRequired
    case keychain(status: OSStatus)
    case keychainProtectionMismatch
    case invalidStoredMetadata
    case cancelled

    var errorDescription: String? {
        switch self {
        case .alreadyInProgress:
            "Codex Remote enrolment is already in progress."
        case .existingState(let state):
            "Codex Remote already has controller state \(state.rawValue); it was not overwritten."
        case .malformedOrdinaryAccessToken:
            "The ordinary Codex access token is malformed."
        case .missingAccountClaims:
            "The ordinary Codex access token is missing its account claims."
        case .ordinaryAccessTokenNeedsRefresh:
            "The ordinary Codex access token must be refreshed before Remote enrolment."
        case .malformedStepUpToken:
            "The Remote authorisation token is malformed."
        case .stepUpAccountMismatch:
            "The Remote authorisation belongs to a different Codex account."
        case .staleStepUpAuthentication:
            "The Remote authorisation is no longer fresh."
        case .stepUpPasswordAuthenticationMissing:
            "The Remote authorisation lacks fresh password authentication."
        case .unexpectedStepUpScope:
            "The Remote authorisation has unexpected permissions."
        case .applicationNotActive:
            "Remote authorisation can start only while NightBlood is in the foreground."
        case .invalidAuthorizationURL:
            "The Remote authorisation URL could not be constructed."
        case .invalidTimeout:
            "The Remote authorisation timeout must be greater than zero."
        case .randomGenerationFailed(let status):
            "Secure random generation failed (status \(status))."
        case .transportFailed:
            "The Codex Remote service could not be reached."
        case .responseRejected(let statusCode):
            "The Codex Remote service rejected the request (HTTP \(statusCode))."
        case .oversizedResponse:
            "The Codex Remote service returned an oversized response."
        case .invalidResponse:
            "The Codex Remote service returned an invalid response."
        case .accountMismatch:
            "The Codex Remote response belongs to a different account."
        case .clientMismatch:
            "The Codex Remote response belongs to a different controller."
        case .invalidChallenge(let field):
            "The Codex Remote device-key challenge has an invalid \(field)."
        case .invalidDeviceIdentity:
            "The Codex Remote device identity is invalid."
        case .invalidDeviceProof:
            "The Codex Remote device-key proof is invalid."
        case .unexpectedControllerScope:
            "The Codex Remote controller has unexpected permissions."
        case .enrolmentFinishUnknown:
            "Codex Remote enrolment may have completed. It will not be retried automatically."
        case .reviewRequired:
            "Codex Remote enrolment returned success but its response requires review."
        case .cleanupRequired:
            "A failed Codex Remote enrolment could not be cleaned up completely."
        case .keychain(let status):
            "The Codex Remote Keychain operation failed (status \(status))."
        case .keychainProtectionMismatch:
            "The Codex Remote metadata lacks the required device-only protection."
        case .invalidStoredMetadata:
            "The stored Codex Remote enrolment metadata is invalid."
        case .cancelled:
            "Codex Remote enrolment was cancelled."
        }
    }

    var isCancellation: Bool {
        if case .cancelled = self { return true }
        return false
    }
}

struct CodexRemoteAccountContext: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    let accessToken: String
    let accountID: String
    let accountUserID: String
    let tokenUserID: String?
    let expiresAt: Int64

    var description: String { "CodexRemoteAccountContext(<redacted>)" }
    var debugDescription: String { description }

    static func parse(
        accessToken: String,
        now: Date = Date(),
        minimumValidity: TimeInterval = 60
    ) throws -> Self {
        let payload = try CodexRemoteJWT.payload(
            accessToken,
            malformedError: .malformedOrdinaryAccessToken
        )
        guard let auth = payload["https://api.openai.com/auth"] as? [String: Any]
        else {
            throw CodexRemoteEnrolmentError.missingAccountClaims
        }
        guard let accountID = CodexRemoteJSON.nonEmptyString(
            auth["chatgpt_account_id"] ?? auth["account_id"]
        ), let accountUserID = CodexRemoteJSON.nonEmptyString(
            auth["chatgpt_account_user_id"] ?? auth["account_user_id"]
        ) else {
            throw CodexRemoteEnrolmentError.missingAccountClaims
        }
        guard let expiresAt = CodexRemoteJSON.integer(payload["exp"]),
              TimeInterval(expiresAt) > now.timeIntervalSince1970 + minimumValidity
        else {
            throw CodexRemoteEnrolmentError.ordinaryAccessTokenNeedsRefresh
        }
        return Self(
            accessToken: accessToken,
            accountID: accountID,
            accountUserID: accountUserID,
            tokenUserID: CodexRemoteJSON.nonEmptyString(auth["user_id"]),
            expiresAt: expiresAt
        )
    }
}

struct CodexRemoteStepUpToken: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    let rawValue: String

    init(validating rawValue: String, accountUserID: String, now: Date) throws {
        guard !rawValue.isEmpty else {
            throw CodexRemoteEnrolmentError.malformedStepUpToken
        }
        let payload = try CodexRemoteJWT.payload(
            rawValue,
            malformedError: .malformedStepUpToken
        )
        guard let auth = payload["https://api.openai.com/auth"] as? [String: Any],
              let tokenAccountUserID = CodexRemoteJSON.nonEmptyString(
                auth["chatgpt_account_user_id"] ?? auth["account_user_id"]
              )
        else {
            throw CodexRemoteEnrolmentError.malformedStepUpToken
        }
        guard tokenAccountUserID == accountUserID else {
            throw CodexRemoteEnrolmentError.stepUpAccountMismatch
        }

        let nowSeconds = now.timeIntervalSince1970
        guard let issuedAt = CodexRemoteJSON.integer(payload["iat"]),
              nowSeconds - TimeInterval(issuedAt)
                <= CodexRemoteEnrolmentConstants.stepUpMaximumAgeSeconds
        else {
            throw CodexRemoteEnrolmentError.staleStepUpAuthentication
        }
        guard let passwordAuthenticationMilliseconds = CodexRemoteJSON.number(
            payload["pwd_auth_time"]
        ) else {
            throw CodexRemoteEnrolmentError.stepUpPasswordAuthenticationMissing
        }
        guard nowSeconds * 1_000 - passwordAuthenticationMilliseconds
                <= CodexRemoteEnrolmentConstants.stepUpMaximumAgeSeconds * 1_000
        else {
            throw CodexRemoteEnrolmentError.staleStepUpAuthentication
        }

        var scopes = Set<String>()
        if let scope = payload["scope"] as? String {
            scopes.formUnion(scope.split(whereSeparator: { $0.isWhitespace }).map(String.init))
        }
        if let scp = payload["scp"] as? [Any] {
            scopes.formUnion(scp.compactMap(CodexRemoteJSON.nonEmptyString))
        }
        guard scopes == Set([CodexRemoteEnrolmentConstants.stepUpScope]) else {
            throw CodexRemoteEnrolmentError.unexpectedStepUpScope
        }
        self.rawValue = rawValue
    }

    var description: String { "CodexRemoteStepUpToken(<redacted>)" }
    var debugDescription: String { description }
}

enum CodexRemoteJSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([Self])
    case object([String: Self])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([Self].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: Self].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

struct CodexRemoteDeviceKeyChallenge: Decodable, Sendable {
    let purpose: String
    let audience: String
    let accountUserID: String
    let clientID: String
    let targetOrigin: String
    let targetPath: String
    let deviceIdentityHash: String?
    let nonce: String
    let challengeID: String
    let challengeToken: String
    let challengeExpiresAt: CodexRemoteJSONValue

    private enum CodingKeys: String, CodingKey {
        case purpose
        case audience
        case accountUserID = "account_user_id"
        case clientID = "client_id"
        case targetOrigin = "target_origin"
        case targetPath = "target_path"
        case deviceIdentityHash = "device_identity_hash"
        case nonce
        case challengeID = "challenge_id"
        case challengeToken = "challenge_token"
        case challengeExpiresAt = "challenge_expires_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        purpose = try container.decode(String.self, forKey: .purpose)
        audience = try container.decode(String.self, forKey: .audience)
        accountUserID = try container.decode(String.self, forKey: .accountUserID)
        clientID = try container.decode(String.self, forKey: .clientID)
        targetOrigin = try container.decode(String.self, forKey: .targetOrigin)
        targetPath = try container.decode(String.self, forKey: .targetPath)
        deviceIdentityHash = try container.decodeIfPresent(
            String.self,
            forKey: .deviceIdentityHash
        )
        nonce = try container.decode(String.self, forKey: .nonce)
        challengeID = try container.decode(String.self, forKey: .challengeID)
        challengeToken = try container.decode(String.self, forKey: .challengeToken)
        challengeExpiresAt = try container.decodeIfPresent(
            CodexRemoteJSONValue.self,
            forKey: .challengeExpiresAt
        ) ?? .null
    }
}

struct CodexRemoteEnrolStartResponse: Decodable, Sendable {
    let accountUserID: String
    let clientID: String
    let deviceKeyChallenge: CodexRemoteDeviceKeyChallenge

    private enum CodingKeys: String, CodingKey {
        case accountUserID = "account_user_id"
        case clientID = "client_id"
        case deviceKeyChallenge = "device_key_challenge"
    }
}

struct CodexRemoteEnrolFinishResponse: Decodable, Sendable {
    let accountUserID: String
    let clientID: String
    let scopes: [String]

    private enum CodingKeys: String, CodingKey {
        case accountUserID = "account_user_id"
        case clientID = "client_id"
        case scopes
    }
}

struct CodexRemoteDeviceIdentityWire: Encodable, Sendable {
    let keyID: String
    let publicKeySPKIDERBase64: String
    let algorithm: String
    let protectionClass: String

    init(_ identity: CodexRemoteDeviceIdentity) {
        keyID = identity.keyID
        publicKeySPKIDERBase64 = identity.publicKeySPKIDERBase64
        algorithm = identity.algorithm
        protectionClass = identity.protectionClass
    }

    private enum CodingKeys: String, CodingKey {
        case keyID = "key_id"
        case publicKeySPKIDERBase64 = "public_key_spki_der_base64"
        case algorithm
        case protectionClass = "protection_class"
    }
}

struct CodexRemoteEnrollmentSigningPayload: Encodable, Sendable {
    let type = "remoteControlClientEnrollment"
    let nonce: String
    let audience: String
    let challengeID: String
    let targetOrigin: String
    let targetPath: String
    let accountUserID: String
    let clientID: String
    let deviceIdentitySHA256Base64URL: String
    let challengeExpiresAt: CodexRemoteJSONValue

    private enum CodingKeys: String, CodingKey {
        case type
        case nonce
        case audience
        case challengeID = "challengeId"
        case targetOrigin
        case targetPath
        case accountUserID = "accountUserId"
        case clientID = "clientId"
        case deviceIdentitySHA256Base64URL = "deviceIdentitySha256Base64url"
        case challengeExpiresAt
    }
}

struct CodexRemoteDeviceKeyProofWire: Encodable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    let challengeToken: String
    let keyID: String
    let signatureDERBase64: String
    let signedPayloadBase64: String
    let algorithm: String

    private enum CodingKeys: String, CodingKey {
        case challengeToken = "challenge_token"
        case keyID = "key_id"
        case signatureDERBase64 = "signature_der_base64"
        case signedPayloadBase64 = "signed_payload_base64"
        case algorithm
    }

    var description: String { "CodexRemoteDeviceKeyProofWire(<redacted>)" }
    var debugDescription: String { description }
}

struct CodexRemoteEnrolFinishRequest: Encodable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    let clientID: String
    let stepUpToken: String
    let deviceIdentity: CodexRemoteDeviceIdentityWire
    let deviceKeyProof: CodexRemoteDeviceKeyProofWire

    private enum CodingKeys: String, CodingKey {
        case clientID = "client_id"
        case stepUpToken = "step_up_token"
        case deviceIdentity = "device_identity"
        case deviceKeyProof = "device_key_proof"
    }

    var description: String { "CodexRemoteEnrolFinishRequest(<redacted>)" }
    var debugDescription: String { description }
}

enum CodexRemoteEnrolmentCryptography {
    private static let challengePurpose = "remote_control_client_enrollment"
    private static let challengeAudience = "remote_control_client_enrollment"
    private static let signingDomain = "codex-device-key-sign-payload/v1"

    static func validateAndMakeSigningPayload(
        challenge: CodexRemoteDeviceKeyChallenge,
        identity: CodexRemoteDeviceIdentity,
        accountUserID: String,
        clientID: String
    ) throws -> (payload: CodexRemoteEnrollmentSigningPayload, identityHash: String) {
        let expected: [(String, String, String)] = [
            ("purpose", challenge.purpose, challengePurpose),
            ("audience", challenge.audience, challengeAudience),
            ("account_user_id", challenge.accountUserID, accountUserID),
            ("client_id", challenge.clientID, clientID),
            ("target_origin", challenge.targetOrigin, "https://chatgpt.com"),
            (
                "target_path",
                challenge.targetPath,
                "/backend-api/\(CodexRemoteEnrolmentConstants.enrolFinishPath)"
            ),
        ]
        for (field, actual, required) in expected where actual != required {
            throw CodexRemoteEnrolmentError.invalidChallenge(field: field)
        }
        for (field, value) in [
            ("nonce", challenge.nonce),
            ("challenge_id", challenge.challengeID),
            ("challenge_token", challenge.challengeToken),
        ] where value.isEmpty {
            throw CodexRemoteEnrolmentError.invalidChallenge(field: field)
        }
        try validate(identity)
        let identityHash = try deviceIdentityHash(identity)
        if let challengedHash = challenge.deviceIdentityHash,
           challengedHash != identityHash
        {
            throw CodexRemoteEnrolmentError.invalidChallenge(
                field: "device_identity_hash"
            )
        }
        return (
            CodexRemoteEnrollmentSigningPayload(
                nonce: challenge.nonce,
                audience: challengeAudience,
                challengeID: challenge.challengeID,
                targetOrigin: challenge.targetOrigin,
                targetPath: challenge.targetPath,
                accountUserID: accountUserID,
                clientID: clientID,
                deviceIdentitySHA256Base64URL: identityHash,
                challengeExpiresAt: challenge.challengeExpiresAt
            ),
            identityHash
        )
    }

    static func deviceIdentityHash(_ identity: CodexRemoteDeviceIdentity) throws -> String {
        try validate(identity)

        // Live gate: the Mac prototype reports `os_protected_nonextractable`,
        // while the iPhone Secure Enclave implementation currently reports
        // `hardware_secure_enclave`. The backend-accepted iPhone value is not
        // proven without physical-device enrolment. Hash and send the exact
        // identity value; never translate it after a challenge has bound it.
        let canonical: [String: Any] = [
            "algorithm": identity.algorithm,
            "keyId": identity.keyID,
            "protectionClass": identity.protectionClass,
            "publicKeySpkiDerBase64": identity.publicKeySPKIDERBase64,
        ]
        let data: Data
        do {
            data = try JSONSerialization.data(
                withJSONObject: canonical,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        } catch {
            throw CodexRemoteEnrolmentError.invalidDeviceIdentity
        }
        return base64URL(Data(SHA256.hash(data: data)))
    }

    static func encodeSigningPayload(
        _ payload: CodexRemoteEnrollmentSigningPayload
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(payload)
        } catch {
            throw CodexRemoteEnrolmentError.invalidDeviceProof
        }
    }

    static func validateAndMakeProof(
        challengeToken: String,
        identity: CodexRemoteDeviceIdentity,
        payloadJSON: Data,
        signature: CodexRemoteDeviceSignature
    ) throws -> CodexRemoteDeviceKeyProofWire {
        guard !challengeToken.isEmpty,
              signature.algorithm == identity.algorithm,
              !signature.signatureDERBase64.isEmpty,
              !signature.signedPayloadBase64.isEmpty,
              Data(base64Encoded: signature.signatureDERBase64) != nil,
              let signedPayload = Data(base64Encoded: signature.signedPayloadBase64),
              signedPayload == (try canonicalSigningEnvelope(payloadJSON))
        else {
            throw CodexRemoteEnrolmentError.invalidDeviceProof
        }
        return CodexRemoteDeviceKeyProofWire(
            challengeToken: challengeToken,
            keyID: identity.keyID,
            signatureDERBase64: signature.signatureDERBase64,
            signedPayloadBase64: signature.signedPayloadBase64,
            algorithm: signature.algorithm
        )
    }

    private static func validate(_ identity: CodexRemoteDeviceIdentity) throws {
        guard identity.algorithm == "ecdsa_p256_sha256",
              UUID(uuidString: identity.keyID) != nil,
              !identity.protectionClass.isEmpty,
              let publicKey = Data(base64Encoded: identity.publicKeySPKIDERBase64),
              publicKey.count == 91
        else {
            throw CodexRemoteEnrolmentError.invalidDeviceIdentity
        }
    }

    private static func canonicalSigningEnvelope(_ payloadJSON: Data) throws -> Data {
        let payload: Any
        do {
            payload = try JSONSerialization.jsonObject(with: payloadJSON)
        } catch {
            throw CodexRemoteEnrolmentError.invalidDeviceProof
        }
        guard payload is [String: Any] else {
            throw CodexRemoteEnrolmentError.invalidDeviceProof
        }
        do {
            return try JSONSerialization.data(
                withJSONObject: ["domain": signingDomain, "payload": payload],
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        } catch {
            throw CodexRemoteEnrolmentError.invalidDeviceProof
        }
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

enum CodexRemoteJSON {
    static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }

    static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let double = number.doubleValue
        guard double.isFinite,
              double.rounded(.towardZero) == double,
              double >= Double(Int64.min),
              double <= Double(Int64.max)
        else { return nil }
        return Int64(double)
    }

    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite
        else { return nil }
        return number.doubleValue
    }
}

enum CodexRemoteJWT {
    static func payload(
        _ token: String,
        malformedError: CodexRemoteEnrolmentError
    ) throws -> [String: Any] {
        let parts = token.components(separatedBy: ".")
        guard parts.count >= 2, !parts[1].isEmpty else {
            throw malformedError
        }
        var encoded = parts[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded.append(String(repeating: "=", count: (4 - encoded.count % 4) % 4))
        guard let data = Data(base64Encoded: encoded),
              let object = try? JSONSerialization.jsonObject(with: data),
              let payload = object as? [String: Any]
        else {
            throw malformedError
        }
        return payload
    }
}
