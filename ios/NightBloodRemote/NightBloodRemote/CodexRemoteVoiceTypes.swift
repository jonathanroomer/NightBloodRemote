import Foundation

/// The catalogue proven for Codex's built-in v3 Voice route. The generated
/// protocol union also contains v2-only names that this session rejects.
enum CodexRemoteVoiceName: String, CaseIterable, Identifiable, Sendable {
    case juniper
    case maple
    case spruce
    case ember
    case vale
    case breeze
    case arbor
    case sol
    case cove

    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
}

enum CodexRemoteVoiceConstants {
    static let version = "v3"
    static let model = "gpt-live-1-codex"
    static let outputModality = "audio"

    static let maximumPromptBytes = 8 * 1024
    static let maximumWebSocketFrameBytes = 150 * 1024
    static let maximumAppServerMessageBytes = 8 * 1024 * 1024
    static let maximumSDPBytes = 128 * 1024
    static let maximumChunkSegments = 128
    static let preparedAttestationCount = 3
    static let sessionGuardSeconds: TimeInterval = 30 * 60
    static let heartbeatSeconds: TimeInterval = 30
    static let pongTimeoutSeconds: TimeInterval = 10 * 60
}

/// A non-empty, size-bounded spoken-character prompt. Keeping this as a
/// native value prevents the face WebView from supplying or changing identity
/// instructions at the realtime boundary.
struct CodexRemoteVoicePrompt: Equatable, Sendable {
    let text: String

    init(validating text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= CodexRemoteVoiceConstants.maximumPromptBytes
        else {
            throw CodexRemoteVoiceError.invalidPrompt
        }
        self.text = text
    }
}

enum CodexRemoteVoiceError: Error, LocalizedError, Sendable, Equatable {
    case applicationNotActive
    case invalidEnvironment
    case invalidThreadID
    case invalidSDPOffer
    case invalidPrompt
    case alreadyConnected
    case notConnected
    case startAlreadyAttempted
    case voiceNotStarted
    case stopAlreadyAttempted
    case transportClosed
    case connectionFailed
    case oversizedWebSocketFrame
    case malformedRemoteMessage
    case streamIdentityMismatch(field: String)
    case invalidSequence
    case invalidChunk
    case unsupportedAppServerMethod(String)
    case appServerRejected(String)
    case realtimeFailed(String)
    case realtimeClosedBeforeReady
    case attestationUnavailable
    case invalidAttestation
    case operationOutcomeUnknown(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .applicationNotActive:
            "Codex Voice can connect only while NightBlood is in the foreground."
        case .invalidEnvironment:
            "Choose the exact online paired Mac before connecting Codex Voice."
        case .invalidThreadID:
            "Choose an exact canonical Codex task before starting Voice."
        case .invalidSDPOffer:
            "The iPhone produced an invalid or oversized WebRTC offer."
        case .invalidPrompt:
            "The selected character personality is missing or invalid."
        case .alreadyConnected:
            "Codex Remote Voice is already connected."
        case .notConnected:
            "Codex Remote Voice is not connected."
        case .startAlreadyAttempted:
            "This Codex Voice connection has already attempted to start. Create a new connection instead of retrying it."
        case .voiceNotStarted:
            "There is no Codex Voice session to stop."
        case .stopAlreadyAttempted:
            "This Codex Voice session has already attempted to stop. It will not retry automatically."
        case .transportClosed:
            "The Codex Remote Voice connection is closed."
        case .connectionFailed:
            "The secure Codex Remote connection failed."
        case .oversizedWebSocketFrame:
            "Codex Remote returned an oversized message."
        case .malformedRemoteMessage:
            "Codex Remote returned an invalid message."
        case .streamIdentityMismatch(let field):
            "Codex Remote returned a message for a different \(field)."
        case .invalidSequence:
            "Codex Remote returned a missing or out-of-order message."
        case .invalidChunk:
            "Codex Remote returned invalid message chunks."
        case .unsupportedAppServerMethod:
            "Codex requested an operation that this bounded Voice connection does not support."
        case .appServerRejected(let detail):
            detail
        case .realtimeFailed(let detail):
            detail
        case .realtimeClosedBeforeReady:
            "Codex Voice closed before the WebRTC session became ready."
        case .attestationUnavailable:
            "DeviceCheck is unavailable on this iPhone."
        case .invalidAttestation:
            "DeviceCheck returned an invalid Codex attestation."
        case .operationOutcomeUnknown(let operation):
            "\(operation) may have happened, but its result was not observed. It will not be retried automatically."
        case .cancelled:
            "Codex Remote Voice was cancelled."
        }
    }

    var isOutcomeUnknown: Bool {
        if case .operationOutcomeUnknown = self { return true }
        return false
    }
}

enum CodexRemoteVoiceState: String, Sendable {
    case disconnected
    case connecting
    case connected
    case preparing
    case starting
    case started
    case stopping
    case startOutcomeUnknown = "start_outcome_unknown"
    case stopOutcomeUnknown = "stop_outcome_unknown"
    case failed
    case closed
}

struct CodexRemoteVoiceSnapshot: Equatable, Sendable {
    let state: CodexRemoteVoiceState
    let threadID: String?
    /// True only while App Server reports a backing Codex turn for this exact
    /// Voice task. This is bounded presentation evidence, not task content.
    let backingWorkActive: Bool
    let serverStarted: Bool
    let realtimeClosed: Bool
    let transportClosed: Bool
    let guardTriggered: Bool
    let errorDescription: String?
    let revision: UInt64
}

struct CodexRemoteVoiceStartResult: Equatable, Sendable {
    let sdpAnswer: String
    let threadID: String
    let voice: String
    let version: String
    let model: String
    let serverStarted: Bool
}

protocol CodexRemoteVoiceControllerSessionProviding: Sendable {
    func controllerSessionForVoice() async throws -> CodexRemoteControllerSession
}

protocol CodexRemoteVoiceEnvironmentProviding: Sendable {
    func confirmedEnvironmentForVoice() async throws
        -> CodexRemotePairedEnvironment
}

extension CodexRemotePairedEnvironmentClient:
    CodexRemoteVoiceEnvironmentProviding
{
    func confirmedEnvironmentForVoice() async throws
        -> CodexRemotePairedEnvironment
    {
        try await confirmedEnvironmentForConnection()
    }
}

extension CodexRemoteControllerSessionManager:
    CodexRemoteVoiceControllerSessionProviding
{
    func controllerSessionForVoice() async throws -> CodexRemoteControllerSession {
        if let session = currentValidSession() {
            return session
        }
        return try await refresh(
            authenticationReason:
                "Use Face ID to connect NightBlood Voice to your paired Codex Mac."
        )
    }
}

protocol CodexRemoteVoiceAttestationProviding: Sendable {
    /// Returns one fresh, opaque App Server attestation. Implementations must
    /// not cache it outside memory or return a simulator placeholder.
    func generateAttestation() async throws -> String
}

protocol CodexRemoteVoiceForegroundProviding: Sendable {
    func isApplicationActive() async -> Bool
}

/// A Sendable JSON tree keeps arbitrary Remote JSON inside the transport
/// without allowing untyped dictionaries to cross an actor boundary.
indirect enum CodexRemoteVoiceJSON: Equatable, Sendable, Codable {
    case null
    case bool(Bool)
    case integer(Int64)
    case number(Double)
    case string(String)
    case array([CodexRemoteVoiceJSON])
    case object([String: CodexRemoteVoiceJSON])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            guard value.isFinite else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Non-finite JSON number"
                )
            }
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(
            [CodexRemoteVoiceJSON].self
        ) {
            self = .array(value)
        } else if let value = try? container.decode(
            [String: CodexRemoteVoiceJSON].self
        ) {
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
            guard value.isFinite else {
                throw EncodingError.invalidValue(
                    value,
                    EncodingError.Context(
                        codingPath: encoder.codingPath,
                        debugDescription: "Non-finite JSON number"
                    )
                )
            }
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    var objectValue: [String: CodexRemoteVoiceJSON]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    var integerValue: Int64? {
        switch self {
        case .integer(let value):
            value
        case .number(let value)
            where value.isFinite
                && value.rounded(.towardZero) == value
                && value >= Double(Int64.min)
                && value <= Double(Int64.max):
            Int64(value)
        default:
            nil
        }
    }

    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    var arrayValue: [CodexRemoteVoiceJSON]? {
        guard case .array(let value) = self else { return nil }
        return value
    }
}
