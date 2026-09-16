import Observation
import UIKit

/// One process-wide runtime shared by the iPhone scene, Live Activity and
/// CarPlay scene. CarPlay is a second presentation of the iPhone companion,
/// never a second Codex Remote or WebRTC session.
@MainActor
final class NightBloodSharedRuntime {
    static let shared = NightBloodSharedRuntime()

    let setup: DirectCodexRemoteSetupModel
    let voice: DirectVoiceSessionModel
    let accessGate: DeviceAccessGate

    private var isObservingSetupReadiness = false

    private init() {
        // The voice-based CarPlay scene can cold-launch while the phone scene
        // is locked. Keep its controller identity, plan credentials and
        // pairing lifecycle separate from the Face-ID-bound iPhone records.
        // The key remains non-exportable in Secure Enclave; these records are
        // device-only and readable only after the first unlock since boot.
        let carPlayIdentityStore = CodexRemoteDeviceIdentityStore(
            accessPolicy: .carPlayAfterFirstUnlock
        )
        let carPlayIdentityProvider =
            CodexRemoteSecureEnclaveIdentityProvider(
                store: carPlayIdentityStore
            )
        let carPlayMetadataStore = CodexRemoteEnrolmentMetadataStore(
            service: "com.example.nightblood.remote.codex-carplay-enrolment",
            account: "carplay-controller-identity",
            allowsBackgroundAccess: true
        )
        let carPlayPairingStore = CodexRemotePairingLifecycleStore(
            service: "com.example.nightblood.remote.codex-carplay-pairing-lifecycle",
            allowsBackgroundAccess: true
        )
        let planOAuth = CodexPlanOAuth(
            tokenStore: CodexPlanTokenStore(
                service: "com.example.nightblood.remote.codex-carplay-plan-oauth",
                account: "carplay-codex-plan-tokens",
                allowsBackgroundAccess: true
            )
        )
        let setup = DirectCodexRemoteSetupModel(
            oauth: planOAuth,
            identityProvider: carPlayIdentityProvider,
            metadataStore: carPlayMetadataStore,
            lifecycleStore: carPlayPairingStore
        )
        let voice = DirectVoiceSessionModel()
        let accessGate = DeviceAccessGate()
        self.setup = setup
        self.voice = voice
        self.accessGate = accessGate

        voice.install(setup: setup)
        observeSetupReadiness()
        NightBloodCarPlayDiagnostics.record("runtime.init")
        NightBloodLiveActivityActionBus.install { [weak voice] action in
            guard let voice else { return }
            switch action {
            case .toggleMicrophone:
                await voice.toggleMicrophoneInput()
            case .stopConversation:
                voice.stopFromUserGesture()
            case .toggleSpeakerOutput:
                await voice.toggleSpeakerOutput()
            }
        }
    }

    /// Refresh only persisted, non-interactive setup state. CarPlay must not
    /// trigger Face ID or send the driver back to the phone while in motion.
    func carPlayDidConnect() {
        NightBloodCarPlayDiagnostics.record("runtime.carplay.connect")
        setup.carPlayDidConnect()
        setup.refreshPersistedState()
        voice.carPlayDidConnect()
        voice.refreshAvailability()
    }

    /// `didConnect` can precede the CarPlay scene's active transition. Repeat
    /// only the idempotent readiness work once the system confirms that the
    /// vehicle surface is foreground-active, and restart a suspended page load
    /// without requiring the iPhone window to appear.
    func carPlayDidBecomeActive() {
        NightBloodCarPlayDiagnostics.record("runtime.carplay.active")
        setup.carPlayDidBecomeActive()
        setup.refreshPersistedState()
        voice.carPlayDidConnect()
        voice.refreshAvailability()
    }

    func reconnectFromCarPlayUserGesture() {
        guard !setup.isBusy, voice.resetCarPlayConnectionPreparation() else { return }
        NightBloodCarPlayDiagnostics.record("carplay.action.reconnect")
        setup.refreshPersistedState()
        voice.refreshAvailability()
    }

    func carPlayDidDisconnect() {
        NightBloodCarPlayDiagnostics.record("runtime.carplay.disconnect")
        voice.carPlayDidDisconnect()
        setup.carPlayDidDisconnect()
        if !NightBloodVoiceSceneActivity.isIPhoneApplicationActive {
            accessGate.lock()
        }
    }

    /// Setup reconciliation is asynchronous. Previously only the iPhone
    /// settings view forwarded its eventual `.ready` transition to Voice, so
    /// a CarPlay-only launch remained stale until the phone UI was opened.
    /// Keep that propagation process-wide because neither presentation owns
    /// the secure controller state.
    private func observeSetupReadiness() {
        guard !isObservingSetupReadiness else { return }
        isObservingSetupReadiness = true
        withObservationTracking {
            _ = setup.phase
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isObservingSetupReadiness = false
                NightBloodCarPlayDiagnostics.record(
                    "setup.phase",
                    detail: self.setup.statusLabel
                )
                self.voice.refreshAvailability()
                self.observeSetupReadiness()
            }
        }
    }
}
