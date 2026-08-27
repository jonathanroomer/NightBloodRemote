import Foundation
import LocalAuthentication
import Security

/// Public identity sent during Codex Remote controller enrolment.
///
/// The corresponding private key never leaves the Secure Enclave.
struct CodexRemoteDeviceIdentity: Codable, Equatable, Sendable {
    let algorithm: String
    let keyID: String
    let protectionClass: String
    let publicKeySPKIDERBase64: String

    private enum CodingKeys: String, CodingKey {
        case algorithm
        case keyID = "keyId"
        case protectionClass
        case publicKeySPKIDERBase64 = "publicKeySpkiDerBase64"
    }
}

/// Proof returned for a Codex Remote device-key challenge.
struct CodexRemoteDeviceSignature: Codable, Equatable, Sendable {
    let algorithm: String
    let signatureDERBase64: String
    let signedPayloadBase64: String

    private enum CodingKeys: String, CodingKey {
        case algorithm
        case signatureDERBase64 = "signatureDerBase64"
        case signedPayloadBase64
    }
}

enum CodexRemoteDeviceKeyError: LocalizedError, Sendable {
    case simulatorUnsupported
    case biometricsUnavailable
    case invalidKeyID
    case invalidPayload
    case payloadTooLarge
    case keyNotFound
    case authenticationCancelled
    case authenticationFailed
    case secureEnclaveUnavailable(String)
    case cleanupFailed(keyID: String, detail: String)
    case unexpectedKeyProtection
    case unexpectedPublicKey
    case unsupportedSigningAlgorithm
    case security(operation: String, detail: String)

    var errorDescription: String? {
        switch self {
        case .simulatorUnsupported:
            "Codex Remote device keys require a physical iPhone with Secure Enclave."
        case .biometricsUnavailable:
            "Face ID must be enrolled and available before creating a Codex Remote device key."
        case .invalidKeyID:
            "The Codex Remote device-key identifier is invalid."
        case .invalidPayload:
            "A Codex Remote signature requires one JSON object."
        case .payloadTooLarge:
            "The Codex Remote signature payload is too large."
        case .keyNotFound:
            "The Codex Remote device key was not found on this iPhone."
        case .authenticationCancelled:
            "Face ID was cancelled before the Codex Remote device key could be used."
        case .authenticationFailed:
            "Face ID did not authorise use of the Codex Remote device key."
        case .secureEnclaveUnavailable(let detail):
            "The iPhone could not create a Secure Enclave device key: \(detail)"
        case .cleanupFailed:
            "A failed Secure Enclave device key could not be removed safely."
        case .unexpectedKeyProtection:
            "The stored Codex Remote device key is not protected by Secure Enclave."
        case .unexpectedPublicKey:
            "Security.framework returned an unexpected P-256 public key."
        case .unsupportedSigningAlgorithm:
            "The Codex Remote device key does not support ECDSA P-256 SHA-256 signing."
        case .security(let operation, let detail):
            "\(operation) failed: \(detail)"
        }
    }
}

/// Serialises access to the phone's Codex Remote controller key.
///
/// There is deliberately no software-key fallback. A Simulator, a device
/// without enrolled biometrics, or a failed Secure Enclave operation stops
/// here instead of creating a weaker controller identity.
actor CodexRemoteDeviceIdentityStore {
    static let shared = CodexRemoteDeviceIdentityStore()

    private enum Constants {
        static let algorithm = "ecdsa_p256_sha256"
        static let protectionClass = "hardware_secure_enclave"
        static let signingDomain = "codex-device-key-sign-payload/v1"
        static let applicationTagPrefix =
            "com.example.nightblood.remote.codex-device-key."
        static let maximumPayloadBytes = 1_048_576

        // SubjectPublicKeyInfo for id-ecPublicKey with the prime256v1 curve.
        static let p256SPKIHeader = Data([
            0x30, 0x59,
            0x30, 0x13,
            0x06, 0x07, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01,
            0x06, 0x08, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07,
            0x03, 0x42, 0x00,
        ])
    }

    /// The LAContext is authenticated once when NightBlood opens, then reused
    /// only for this foreground app session. It never leaves this actor and is
    /// made non-interactive after the initial Face ID success so key use cannot
    /// create surprise repeat prompts.
    private var foregroundSessionID: UUID?
    private var foregroundContext: LAContext?
    private var pendingSessionID: UUID?
    private var pendingContext: LAContext?

    func beginForegroundAuthentication(
        sessionID: UUID,
        reason: String
    ) async throws {
        try requireAvailableBiometrics()
        let accessControl = try deviceKeyAccessControl()
        let context = operationAuthenticationContext(reason: reason)

        pendingContext?.invalidate()
        foregroundContext?.invalidate()
        pendingSessionID = sessionID
        pendingContext = context
        foregroundSessionID = nil
        foregroundContext = nil

        do {
            try await context.evaluateAccessControl(
                accessControl,
                operation: .useKeySign,
                localizedReason: reason
            )
        } catch {
            let isCurrent = pendingSessionID == sessionID
                && pendingContext === context
            if isCurrent {
                pendingSessionID = nil
                pendingContext = nil
            }
            context.invalidate()
            guard isCurrent else {
                throw CodexRemoteDeviceKeyError.authenticationCancelled
            }
            throw mapAuthenticationError(error)
        }

        guard pendingSessionID == sessionID,
              pendingContext === context
        else {
            context.invalidate()
            throw CodexRemoteDeviceKeyError.authenticationCancelled
        }
        pendingSessionID = nil
        pendingContext = nil
        context.interactionNotAllowed = true
        foregroundSessionID = sessionID
        foregroundContext = context
    }

    func endForegroundAuthentication(sessionID: UUID) {
        if pendingSessionID == sessionID {
            pendingContext?.invalidate()
            pendingContext = nil
            pendingSessionID = nil
        }
        if foregroundSessionID == sessionID {
            foregroundContext?.invalidate()
            foregroundContext = nil
            foregroundSessionID = nil
        }
    }

    /// Creates a permanent, non-exportable P-256 identity in Secure Enclave.
    func createIdentity() throws -> CodexRemoteDeviceIdentity {
        try requirePhysicalDevice()
        try requireAvailableBiometrics()

        let keyID = UUID().uuidString.lowercased()
        let privateKey = try createSecureEnclavePrivateKey(keyID: keyID)
        do {
            return try identity(keyID: keyID, privateKey: privateKey)
        } catch {
            let cleanupStatus = deleteWithoutAuthentication(keyID: keyID)
            guard cleanupStatus == errSecSuccess || cleanupStatus == errSecItemNotFound else {
                throw CodexRemoteDeviceKeyError.cleanupFailed(
                    keyID: keyID,
                    detail: securityDetail(status: cleanupStatus)
                )
            }
            throw error
        }
    }

    /// Re-derives the public enrolment identity for a previously created key.
    func identity(
        for keyID: String,
        authenticationReason: String = "Use your private Codex Remote identity"
    ) throws -> CodexRemoteDeviceIdentity {
        try requirePhysicalDevice()
        let normalisedKeyID = try normaliseKeyID(keyID)
        let privateKey = try copyPrivateKey(
            keyID: normalisedKeyID,
            authenticationReason: authenticationReason
        )
        return try identity(keyID: normalisedKeyID, privateKey: privateKey)
    }

    /// Signs a challenge payload using the exact Codex device-key wire format.
    ///
    /// `payloadJSON` must encode one JSON object. The object is wrapped as
    /// `{ "domain": "codex-device-key-sign-payload/v1", "payload": ... }`,
    /// recursively key-sorted without escaped slashes, then signed. The
    /// signature returned by Security.framework is ANSI X9.62 DER.
    func sign(
        payloadJSON: Data,
        with keyID: String,
        authenticationReason: String = "Authorise this Codex Remote connection"
    ) throws -> CodexRemoteDeviceSignature {
        try requirePhysicalDevice()
        let normalisedKeyID = try normaliseKeyID(keyID)
        let signedPayload = try canonicalSignedPayload(from: payloadJSON)
        let privateKey = try copyPrivateKey(
            keyID: normalisedKeyID,
            authenticationReason: authenticationReason
        )
        try requireSecureEnclave(privateKey)

        let signingAlgorithm = SecKeyAlgorithm.ecdsaSignatureMessageX962SHA256
        guard SecKeyIsAlgorithmSupported(privateKey, .sign, signingAlgorithm) else {
            throw CodexRemoteDeviceKeyError.unsupportedSigningAlgorithm
        }

        var signatureError: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            signingAlgorithm,
            signedPayload as CFData,
            &signatureError
        ) as Data? else {
            throw mappedSignatureError(signatureError)
        }

        return CodexRemoteDeviceSignature(
            algorithm: Constants.algorithm,
            signatureDERBase64: signature.base64EncodedString(),
            signedPayloadBase64: signedPayload.base64EncodedString()
        )
    }

    private func requirePhysicalDevice() throws {
        #if targetEnvironment(simulator)
        throw CodexRemoteDeviceKeyError.simulatorUnsupported
        #endif
    }

    private func requireAvailableBiometrics() throws {
        let context = LAContext()
        var evaluationError: NSError?
        guard context.canEvaluatePolicy(
            .deviceOwnerAuthenticationWithBiometrics,
            error: &evaluationError
        ) else {
            throw CodexRemoteDeviceKeyError.biometricsUnavailable
        }
    }

    private func createSecureEnclavePrivateKey(keyID: String) throws -> SecKey {
        let accessControl = try deviceKeyAccessControl()

        let privateKeyAttributes: [String: Any] = [
            kSecAttrApplicationTag as String: applicationTag(for: keyID),
            kSecAttrIsPermanent as String: true,
            kSecAttrAccessControl as String: accessControl,
        ]
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: privateKeyAttributes,
        ]

        var creationError: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(
            attributes as CFDictionary,
            &creationError
        ) else {
            let detail = consumeSecurityDetail(creationError)
            throw CodexRemoteDeviceKeyError.secureEnclaveUnavailable(detail)
        }
        try requireSecureEnclave(privateKey)
        return privateKey
    }

    private func deviceKeyAccessControl() throws -> SecAccessControl {
        var accessControlError: Unmanaged<CFError>?
        guard let accessControl = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage, .biometryCurrentSet],
            &accessControlError
        ) else {
            throw securityError(
                operation: "Secure Enclave access-control creation",
                error: accessControlError
            )
        }
        return accessControl
    }

    private func copyPrivateKey(
        keyID: String,
        authenticationReason: String
    ) throws -> SecKey {
        let context = try foregroundAuthenticationContext(
            reason: authenticationReason
        )
        var query = privateKeyQuery(keyID: keyID, returnReference: true)
        query[kSecUseAuthenticationContext as String] = context

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            break
        case errSecItemNotFound:
            throw CodexRemoteDeviceKeyError.keyNotFound
        case errSecUserCanceled:
            throw CodexRemoteDeviceKeyError.authenticationCancelled
        case errSecAuthFailed:
            throw CodexRemoteDeviceKeyError.authenticationFailed
        default:
            throw securityError(operation: "Secure Enclave device-key lookup", status: status)
        }

        guard let result, CFGetTypeID(result) == SecKeyGetTypeID() else {
            throw CodexRemoteDeviceKeyError.security(
                operation: "Secure Enclave device-key lookup",
                detail: "Security.framework returned an invalid key reference"
            )
        }
        let privateKey = unsafeDowncast(result, to: SecKey.self)
        try requireSecureEnclave(privateKey)
        return privateKey
    }

    private func privateKeyQuery(keyID: String, returnReference: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: applicationTag(for: keyID),
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
        ]
        if returnReference {
            query[kSecReturnRef as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
        }
        return query
    }

    private func applicationTag(for keyID: String) -> Data {
        Data("\(Constants.applicationTagPrefix)\(keyID)".utf8)
    }

    private func normaliseKeyID(_ candidate: String) throws -> String {
        guard let uuid = UUID(uuidString: candidate) else {
            throw CodexRemoteDeviceKeyError.invalidKeyID
        }
        return uuid.uuidString.lowercased()
    }

    private func operationAuthenticationContext(reason: String) -> LAContext {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        context.localizedReason = reason
        return context
    }

    private func foregroundAuthenticationContext(
        reason: String
    ) throws -> LAContext {
        guard foregroundSessionID != nil,
              let context = foregroundContext
        else {
            throw CodexRemoteDeviceKeyError.authenticationFailed
        }
        context.localizedReason = reason
        return context
    }

    private func mapAuthenticationError(
        _ error: any Error
    ) -> CodexRemoteDeviceKeyError {
        guard let localError = error as? LAError else {
            return .authenticationFailed
        }
        switch localError.code {
        case .userCancel, .appCancel, .systemCancel:
            return .authenticationCancelled
        case .biometryNotAvailable, .biometryNotEnrolled, .biometryLockout:
            return .biometricsUnavailable
        default:
            return .authenticationFailed
        }
    }

    private func requireSecureEnclave(_ privateKey: SecKey) throws {
        guard let attributes = SecKeyCopyAttributes(privateKey) as? [String: Any],
              let tokenID = attributes[kSecAttrTokenID as String] as? String,
              tokenID == (kSecAttrTokenIDSecureEnclave as String)
        else {
            throw CodexRemoteDeviceKeyError.unexpectedKeyProtection
        }
    }

    private func identity(
        keyID: String,
        privateKey: SecKey
    ) throws -> CodexRemoteDeviceIdentity {
        try requireSecureEnclave(privateKey)
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw CodexRemoteDeviceKeyError.security(
                operation: "Secure Enclave public-key lookup",
                detail: "Security.framework returned no public key"
            )
        }

        var exportError: Unmanaged<CFError>?
        guard let external = SecKeyCopyExternalRepresentation(
            publicKey,
            &exportError
        ) as Data? else {
            throw securityError(
                operation: "Secure Enclave public-key export",
                error: exportError
            )
        }

        // Security.framework exports an EC public key as ANSI X9.63:
        // 0x04 || X || Y. The relay expects a DER SubjectPublicKeyInfo value.
        guard external.count == 65, external.first == 0x04 else {
            throw CodexRemoteDeviceKeyError.unexpectedPublicKey
        }
        var spki = Constants.p256SPKIHeader
        spki.append(external)

        return CodexRemoteDeviceIdentity(
            algorithm: Constants.algorithm,
            keyID: keyID,
            protectionClass: Constants.protectionClass,
            publicKeySPKIDERBase64: spki.base64EncodedString()
        )
    }

    private func canonicalSignedPayload(from payloadJSON: Data) throws -> Data {
        guard payloadJSON.count <= Constants.maximumPayloadBytes else {
            throw CodexRemoteDeviceKeyError.payloadTooLarge
        }
        guard !payloadJSON.isEmpty else {
            throw CodexRemoteDeviceKeyError.invalidPayload
        }

        let payload: Any
        do {
            payload = try JSONSerialization.jsonObject(with: payloadJSON)
        } catch {
            throw CodexRemoteDeviceKeyError.invalidPayload
        }
        guard payload is [String: Any] else {
            throw CodexRemoteDeviceKeyError.invalidPayload
        }

        let envelope: [String: Any] = [
            "domain": Constants.signingDomain,
            "payload": payload,
        ]
        do {
            return try JSONSerialization.data(
                withJSONObject: envelope,
                options: [.sortedKeys, .withoutEscapingSlashes]
            )
        } catch {
            throw CodexRemoteDeviceKeyError.invalidPayload
        }
    }

    private func deleteWithoutAuthentication(keyID: String) -> OSStatus {
        SecItemDelete(
            privateKeyQuery(keyID: keyID, returnReference: false) as CFDictionary
        )
    }

    private func mappedSignatureError(
        _ error: Unmanaged<CFError>?
    ) -> CodexRemoteDeviceKeyError {
        guard let error else {
            return .security(
                operation: "Secure Enclave device-key signing",
                detail: "Security.framework returned no error"
            )
        }
        let retained = error.takeRetainedValue()
        let status = CFErrorGetCode(retained)
        if status == Int(errSecUserCanceled) {
            return .authenticationCancelled
        }
        if status == Int(errSecAuthFailed) {
            return .authenticationFailed
        }
        return .security(
            operation: "Secure Enclave device-key signing",
            detail: (retained as Error).localizedDescription
        )
    }

    private func securityError(
        operation: String,
        status: OSStatus
    ) -> CodexRemoteDeviceKeyError {
        .security(operation: operation, detail: securityDetail(status: status))
    }

    private func securityError(
        operation: String,
        error: Unmanaged<CFError>?
    ) -> CodexRemoteDeviceKeyError {
        .security(operation: operation, detail: consumeSecurityDetail(error))
    }

    private func consumeSecurityDetail(_ error: Unmanaged<CFError>?) -> String {
        guard let error else {
            return "Security.framework returned no error"
        }
        return (error.takeRetainedValue() as Error).localizedDescription
    }

    private func securityDetail(status: OSStatus) -> String {
        SecCopyErrorMessageString(status, nil) as String?
            ?? "Security.framework status \(status)"
    }
}
