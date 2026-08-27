import SwiftUI
import UIKit

@main
@MainActor
struct DirectNightBloodRemoteApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var setup = DirectCodexRemoteSetupModel()
    @State private var voice: DirectVoiceSessionModel
    @State private var accessGate = DeviceAccessGate()

    init() {
        let voice = DirectVoiceSessionModel()
        _voice = State(initialValue: voice)
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

    var body: some Scene {
        WindowGroup {
            DirectCompanionView(
                voice: voice,
                setup: setup,
                accessGate: accessGate
            )
            .preferredColorScheme(.dark)
            .task {
                if scenePhase == .active {
                    UIApplication.shared.isIdleTimerDisabled = true
                }
                voice.install(setup: setup)
                guard await accessGate.unlock() else { return }
                setup.applicationDidBecomeActive()
                setup.refreshPersistedState()
                voice.startGazeTracking()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // NightBlood is a face, not a transient utility screen. Keep
                // it fully awake while visible; backgrounding restores the
                // owner's ordinary iPhone dimming and lock settings.
                UIApplication.shared.isIdleTimerDisabled = true
                // An established Voice session is allowed to remain live
                // under the audio background mode. Returning foreground only
                // restores its lifecycle marker; it never starts or retries a
                // session without the device owner's original tap and Face ID.
                voice.applicationDidBecomeActive()
                // Face ID, Secure Enclave signing and Safari overlays can all
                // produce `.inactive` -> `.active` without backgrounding.
                // Only a real background transition arms automatic unlock;
                // otherwise a cancelled biometric prompt could reopen itself.
                guard let lifecycleGeneration = accessGate
                    .consumeAutomaticUnlockRequest()
                else {
                    break
                }
                Task {
                    guard await accessGate.unlock(
                        expectedLifecycleGeneration: lifecycleGeneration
                    ) else {
                        return
                    }
                    setup.applicationDidBecomeActive()
                    setup.refreshPersistedState()
                    voice.startGazeTracking()
                }
            case .background:
                UIApplication.shared.isIdleTimerDisabled = false
                // Listening/thinking/speaking sessions keep their WebRTC
                // audio and private relay. Setup and incomplete starts still
                // cancel and discard credentials exactly as before.
                voice.applicationDidEnterBackground()
                setup.applicationDidEnterBackground()
                accessGate.lock()
            case .inactive:
                // Face ID and other system overlays temporarily make the app
                // inactive. Cancelling authentication here creates a prompt /
                // lock loop; a real departure always reaches `.background`.
                break
            @unknown default:
                break
            }
        }
    }
}
