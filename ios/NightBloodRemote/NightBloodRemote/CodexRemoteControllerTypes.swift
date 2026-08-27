import Foundation

enum CodexRemoteControllerConstants {
    static let pairPath = "wham/remote/control/client/pair"
    static let environmentsPathPrefix = "codex/remote/control/clients"
    static let refreshStartPath = "codex/remote/control/client/refresh/start"
    static let refreshFinishPath = "codex/remote/control/client/refresh/finish"
    static let webSocketPath = "codex/remote/control/client"
    static let protocolVersion = "3"
    static let maximumWebSocketMessageBytes = 150 * 1_024
    static let expectedOrigin = "https://chatgpt.com"
    static let webSocketURL = URL(
        string: "wss://chatgpt.com/backend-api/codex/remote/control/client"
    )!
}

enum CodexRemoteControllerError: Error, LocalizedError, Sendable {
    case invalidPairingCode
    case pairingAttemptAlreadyConsumed
    case pairingOutcomeUnknown
    case pairingVerificationRequired
    case invalidPairingLifecycle
    case invalidEnrolmentState
    case accountMismatch
    case clientMismatch
    case invalidRequest
    case responseRejected(statusCode: Int)
    case invalidResponse
    case tooManyEnvironments
    case environmentSelectionRequired
    case environmentNotFound
    case duplicateEnvironment
    case environmentOffline
    case refreshAlreadyInProgress
    case invalidChallenge(field: String)
    case invalidDeviceProof
    case invalidExpiration
    case sessionExpired
    case unexpectedControllerScope
    case insecureWebSocketEndpoint
    case invalidWebSocketMessage

    var errorDescription: String? {
        switch self {
        case .invalidPairingCode:
            "The Codex pairing code must contain exactly eight letters or digits."
        case .pairingAttemptAlreadyConsumed:
            "That pairing attempt has already been used. Start a new explicit pairing attempt."
        case .pairingOutcomeUnknown:
            "Codex pairing may have completed. It will not be retried automatically; verify the paired environments first."
        case .pairingVerificationRequired:
            "Verify the selected paired Mac before requesting a controller session."
        case .invalidPairingLifecycle:
            "The stored Codex pairing lifecycle is invalid."
        case .invalidEnrolmentState:
            "This iPhone does not have a completed Codex Remote controller enrolment."
        case .accountMismatch:
            "The Codex Remote data belongs to a different account."
        case .clientMismatch:
            "The Codex Remote data belongs to a different controller."
        case .invalidRequest:
            "The Codex Remote request could not be constructed safely."
        case .responseRejected(let statusCode):
            "The Codex Remote service rejected the request (HTTP \(statusCode))."
        case .invalidResponse:
            "The Codex Remote service returned an invalid response."
        case .tooManyEnvironments:
            "Codex returned more paired environments than requested."
        case .environmentSelectionRequired:
            "Choose the exact paired Mac before connecting."
        case .environmentNotFound:
            "The selected paired Mac was not returned by Codex."
        case .duplicateEnvironment:
            "Codex returned the selected environment more than once."
        case .environmentOffline:
            "The selected paired Mac is currently offline."
        case .refreshAlreadyInProgress:
            "A Codex Remote controller-session refresh is already in progress."
        case .invalidChallenge(let field):
            "The Codex Remote device-key challenge has an invalid \(field)."
        case .invalidDeviceProof:
            "The Codex Remote device-key proof is invalid."
        case .invalidExpiration:
            "The Codex Remote controller session has an invalid expiration."
        case .sessionExpired:
            "The Codex Remote controller session has expired."
        case .unexpectedControllerScope:
            "The Codex Remote controller session has unexpected permissions."
        case .insecureWebSocketEndpoint:
            "The Codex Remote WebSocket endpoint is not secure."
        case .invalidWebSocketMessage:
            "The Codex Remote relay returned an invalid handshake message."
        }
    }
}

/// A manual Codex pairing code. Only the exact normalised value is sent; the
/// original and normalised code are deliberately omitted from descriptions.
struct CodexRemoteManualPairingCode: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    let normalisedValue: String

    init(_ value: String) throws {
        var compact = String.UnicodeScalarView()
        for scalar in value.unicodeScalars where scalar.value != 0x2D {
            let ascii = scalar.value
            switch ascii {
            case 0x30...0x39, 0x41...0x5A:
                compact.append(scalar)
            case 0x61...0x7A:
                guard let upper = UnicodeScalar(ascii - 0x20) else {
                    throw CodexRemoteControllerError.invalidPairingCode
                }
                compact.append(upper)
            default:
                // Reject non-ASCII before case conversion so Unicode
                // expansions can never turn one scalar into valid code text.
                throw CodexRemoteControllerError.invalidPairingCode
            }
        }
        guard compact.count == 8,
              compact.allSatisfy({ scalar in
                  (0x41...0x5A).contains(scalar.value)
                      || (0x30...0x39).contains(scalar.value)
              })
        else {
            throw CodexRemoteControllerError.invalidPairingCode
        }
        let compactString = String(compact)
        let split = compactString.unicodeScalars.index(
            compactString.unicodeScalars.startIndex,
            offsetBy: 4
        )
        normalisedValue =
            "\(String(compactString.unicodeScalars[..<split]))-"
            + String(compactString.unicodeScalars[split...])
    }

    var description: String { "CodexRemoteManualPairingCode(<redacted>)" }
    var debugDescription: String { description }
}

struct CodexRemotePairingReceipt: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    /// HTTP success is not pairing proof. A fresh client-environment listing
    /// must still confirm the explicitly selected Mac.
    let isProvisional = true
    let clientID: String?
    let envID: String?
    let environmentID: String?
    let status: String?
    let paired: Bool?

    var description: String { "CodexRemotePairingReceipt(<redacted>)" }
    var debugDescription: String { description }
}

struct CodexRemotePairedEnvironment: Decodable, Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    let environmentID: String?
    let name: String?
    let displayName: String?
    let hostName: String?
    let online: Bool?
    let busy: Bool?
    let kind: String?
    let clientType: String?
    let operatingSystem: String?
    let architecture: String?
    let appServerVersion: String?

    private enum CodingKeys: String, CodingKey {
        case environmentID = "env_id"
        case name
        case displayName = "display_name"
        case hostName = "host_name"
        case online
        case busy
        case kind
        case clientType = "client_type"
        case operatingSystem = "os"
        case architecture = "arch"
        case appServerVersion = "app_server_version"
    }

    var description: String { "CodexRemotePairedEnvironment(<redacted>)" }
    var debugDescription: String { description }
}

struct CodexRemoteEnvironmentListing: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    let environments: [CodexRemotePairedEnvironment]

    /// Selection is intentionally never implicit, including when only one Mac
    /// is online. The environment identifier must come from a user-visible row.
    func selecting(environmentID: String) throws -> CodexRemotePairedEnvironment {
        guard !environmentID.isEmpty else {
            throw CodexRemoteControllerError.environmentSelectionRequired
        }
        let matches = environments.filter { $0.environmentID == environmentID }
        guard !matches.isEmpty else {
            throw CodexRemoteControllerError.environmentNotFound
        }
        guard matches.count == 1 else {
            throw CodexRemoteControllerError.duplicateEnvironment
        }
        guard matches[0].online == true else {
            throw CodexRemoteControllerError.environmentOffline
        }
        return matches[0]
    }

    var description: String {
        "CodexRemoteEnvironmentListing(count: \(environments.count))"
    }
    var debugDescription: String { description }
}

/// A short-lived controller credential. It is intentionally not Codable and
/// no store accepts it; its bearer token exists only in memory.
struct CodexRemoteControllerSession: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    let clientID: String
    let accountUserID: String
    let token: String
    let expiresAt: Int64
    let scopes: [String]

    func isValid(at date: Date) -> Bool {
        TimeInterval(expiresAt) > date.timeIntervalSince1970
    }

    var description: String {
        "CodexRemoteControllerSession(expiresAt: \(expiresAt), token: <redacted>)"
    }
    var debugDescription: String { description }
}

enum CodexRemoteControllerValidation {
    static func validate(
        account: CodexRemoteAccountContext,
        metadata: CodexRemoteEnrolmentMetadata,
        now: Date
    ) throws {
        guard metadata.state == .enrolled else {
            throw CodexRemoteControllerError.invalidEnrolmentState
        }
        let acceptedAccountUserIDs = Set(
            [account.accountUserID, account.tokenUserID].compactMap { $0 }
        )
        guard acceptedAccountUserIDs.contains(metadata.accountUserID) else {
            throw CodexRemoteControllerError.accountMismatch
        }
        guard TimeInterval(account.expiresAt) > now.timeIntervalSince1970 + 60 else {
            throw CodexRemoteEnrolmentError.ordinaryAccessTokenNeedsRefresh
        }
    }

    static func validate(
        session: CodexRemoteControllerSession,
        account: CodexRemoteAccountContext,
        metadata: CodexRemoteEnrolmentMetadata,
        now: Date
    ) throws {
        try validate(account: account, metadata: metadata, now: now)
        guard session.accountUserID == metadata.accountUserID else {
            throw CodexRemoteControllerError.accountMismatch
        }
        guard session.clientID == metadata.clientID else {
            throw CodexRemoteControllerError.clientMismatch
        }
        guard session.scopes == [CodexRemoteEnrolmentConstants.controllerScope]
        else {
            throw CodexRemoteControllerError.unexpectedControllerScope
        }
        guard session.isValid(at: now) else {
            throw CodexRemoteControllerError.sessionExpired
        }
    }
}
