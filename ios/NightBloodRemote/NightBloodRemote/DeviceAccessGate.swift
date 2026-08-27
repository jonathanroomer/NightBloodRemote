import Foundation
import Observation

@MainActor
@Observable
final class DeviceAccessGate {
    enum State {
        case locked
        case unlocking
        case unlocked
    }

    private(set) var state: State
    var lastError: String?

    private let identityStore: CodexRemoteDeviceIdentityStore
    private var pendingSessionID: UUID?
    private var activeSessionID: UUID?
    private var lifecycleGeneration: UInt64 = 0
    private var automaticUnlockPending = false

    private static var simulatesLock: Bool {
        ProcessInfo.processInfo.arguments.contains("--nightblood-lock-simulator")
    }

    init(identityStore: CodexRemoteDeviceIdentityStore = .shared) {
        self.identityStore = identityStore
        #if targetEnvironment(simulator)
        // Simulator is a deterministic visual test surface. Physical builds
        // always require the device owner's Face ID before control begins.
        state = Self.simulatesLock ? .locked : .unlocked
        #else
        state = .locked
        #endif
    }

    var isUnlocked: Bool { state == .unlocked }

    /// Only a real background transition arms automatic re-unlock. Face ID
    /// dismissal also produces `.active`, but must never cause a cancelled
    /// prompt to reopen itself.
    func consumeAutomaticUnlockRequest() -> UInt64? {
        guard automaticUnlockPending else { return nil }
        automaticUnlockPending = false
        return lifecycleGeneration
    }

    @discardableResult
    func unlock(expectedLifecycleGeneration: UInt64? = nil) async -> Bool {
        await authenticate(
            reason: "Unlock your private NightBlood connection",
            expectedLifecycleGeneration: expectedLifecycleGeneration
        )
    }

    /// The foreground app has already passed Face ID. A real background
    /// transition locks this gate before settings can be opened again.
    @discardableResult
    func authoriseConnectionSettings() async -> Bool {
        await authenticate(
            reason: "Open NightBlood's private connection settings",
            expectedLifecycleGeneration: nil
        )
    }

    /// One Face ID unlock protects the current foreground app session. Starting
    /// another conversation does not prompt again until NightBlood is reopened.
    @discardableResult
    func authoriseVoiceStart() async -> Bool {
        await authenticate(
            reason: "Start a private Codex Voice session",
            expectedLifecycleGeneration: nil
        )
    }

    private func authenticate(
        reason: String,
        expectedLifecycleGeneration: UInt64?
    ) async -> Bool {
        if isUnlocked { return true }
        guard state != .unlocking else { return false }
        if let expectedLifecycleGeneration,
           expectedLifecycleGeneration != lifecycleGeneration
        {
            return false
        }

        automaticUnlockPending = false
        let generation = lifecycleGeneration
        let sessionID = UUID()
        pendingSessionID = sessionID
        state = .unlocking
        lastError = nil
        do {
            try await identityStore.beginForegroundAuthentication(
                sessionID: sessionID,
                reason: reason
            )
            guard generation == lifecycleGeneration,
                  pendingSessionID == sessionID
            else {
                await identityStore.endForegroundAuthentication(
                    sessionID: sessionID
                )
                return false
            }
            pendingSessionID = nil
            activeSessionID = sessionID
            state = .unlocked
            return true
        } catch {
            guard generation == lifecycleGeneration,
                  pendingSessionID == sessionID
            else {
                return false
            }
            pendingSessionID = nil
            state = .locked
            switch error as? CodexRemoteDeviceKeyError {
            case .authenticationCancelled:
                break
            case .biometricsUnavailable:
                lastError = "Face ID is required before NightBlood can control this Mac."
            default:
                lastError = "NightBlood could not verify Face ID."
            }
            return false
        }
    }

    func lock() {
        automaticUnlockPending = true
        advanceLifecycleGeneration()
        let pending = pendingSessionID
        let active = activeSessionID
        pendingSessionID = nil
        activeSessionID = nil
        state = .locked
        lastError = nil
        let identityStore = identityStore
        Task {
            if let pending {
                await identityStore.endForegroundAuthentication(
                    sessionID: pending
                )
            }
            if let active, active != pending {
                await identityStore.endForegroundAuthentication(
                    sessionID: active
                )
            }
        }
    }

    private func advanceLifecycleGeneration() {
        lifecycleGeneration = lifecycleGeneration == UInt64.max
            ? 0 : lifecycleGeneration + 1
    }
}
