@preconcurrency import AVFAudio
@preconcurrency import CarPlay
import Observation
import UIKit

struct NightBloodCarPlaySnapshot: Equatable {
    let state: DirectVoiceSessionState
    let microphoneMuted: Bool
    let hasConversation: Bool
    let canStart: Bool
    let canToggleMicrophone: Bool
    let readyFlashActive: Bool
    let visualState: NightBloodCarPlayVisualState
    let canReconnect: Bool

    @MainActor
    init(runtime: NightBloodSharedRuntime) {
        let voice = runtime.voice
        state = voice.state
        visualState = NightBloodCarPlayVisualState(voice.state, readyFlashActive: voice.readyFlashActive, setupPhase: runtime.setup.phase, preparing: voice.isPreparingDesktopConnection)
        canReconnect = voice.canReconnectFromCarPlay && !runtime.setup.isBusy
        readyFlashActive = voice.readyFlashActive
        microphoneMuted = voice.isMicrophoneMuted
        hasConversation = voice.hasOwnedVoice || voice.state.isActive
        canStart = voice.isCarPlayConnected
            && runtime.setup.isVoiceReady
            && voice.canSelectFace
            && (voice.canStartVoice || voice.canRetryVoiceConnection)
        canToggleMicrophone = voice.canToggleMicrophoneInput
    }
}

enum NightBloodCarAudioRoute {
    static func usesVehicleAudio(_ outputs: [AVAudioSession.Port]) -> Bool {
        outputs.contains(where: isVehicleAudio)
    }

    static func isVehicleAudio(_ port: AVAudioSession.Port) -> Bool {
        switch port {
        case .carAudio, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE:
            true
        default:
            false
        }
    }
}

enum NightBloodCarPlayVisualState: String, CaseIterable {
    case ready
    case welcoming
    case unavailable
    case listening
    case working
    case speaking
    case connecting
    case stopping
    case failed
    case needsReview
    case setupRequired

    init(_ state: DirectVoiceSessionState, readyFlashActive: Bool = false,
         setupPhase: DirectCodexRemoteSetupModel.Phase = .ready, preparing: Bool = false) {
        if !state.isActive && state != .outcomeUnknown {
            switch setupPhase {
            case .enrolmentOutcomeUnknown, .pairingOutcomeUnknown, .enrolmentReviewRequired:
                self = .needsReview; return
            case .failed, .selectedEnvironmentUnavailable:
                self = .failed; return
            default: break
            }
        }
        if state == .unavailable {
            if setupPhase.isBusy || preparing { self = .connecting }
            else if setupPhase != .ready && setupPhase != .inactive { self = .setupRequired }
            else { self = .unavailable }
            return
        }
        if state == .listening && readyFlashActive {
            self = .welcoming
            return
        }
        switch state {
        case .ready:
            self = .ready
        case .listening:
            self = .listening
        case .speaking:
            self = .speaking
        case .thinking: self = .working
        case .connecting: self = .connecting
        case .stopping: self = .stopping
        case .failed: self = .failed
        case .outcomeUnknown: self = .needsReview
        case .unavailable: self = .unavailable
        }
    }

    var artworkState: Self {
        switch self {
        case .connecting, .stopping: .working
        case .failed, .needsReview, .setupRequired: .unavailable
        default: self
        }
    }

    var label: String {
        switch self {
        case .ready: "Ready"
        case .welcoming: "Ready"
        case .unavailable: "Disconnected"
        case .listening: "Listening"
        case .working: "Working"
        case .speaking: "Talking"
        case .connecting: "Connecting"
        case .stopping: "Stopping"
        case .failed: "Connection error"
        case .needsReview: "Check iPhone"
        case .setupRequired: "Setup required"
        }
    }
}

/// The voice-control template is the only CarPlay surface that centres an
/// animated image and a short status. NightBlood is the sole car character.
/// The controls use the navigation area: unlike the template's
/// lower CPButton controls, this CarPlay path delivers actions on both the
/// simulator and physical head unit. Their handlers cross explicitly from
/// CarPlay's XPC callback queue to the main actor.
@MainActor
@available(iOS 26.4, *)
final class NightBloodCarPlayPresenter {
    private let runtime: NightBloodSharedRuntime
    private let interfaceController: CPInterfaceController
    private var template: CPVoiceControlTemplate?
    private var voiceStates: [NightBloodCarPlayVisualState: CPVoiceControlState]
        = [:]
    private var routeObserver: NSObjectProtocol?
    private var isObserving = false
    private var hasRequestedTalk = false
    private var cachedImages: [NightBloodCarPlayVisualState: UIImage] = [:]
    private var cachedIntroImage: UIImage?

    init(
        runtime: NightBloodSharedRuntime,
        interfaceController: CPInterfaceController
    ) {
        self.runtime = runtime
        self.interfaceController = interfaceController
        interfaceController.prefersDarkUserInterfaceStyle = true
        installTemplate(
            using: NightBloodCarPlaySnapshot(runtime: runtime),
            animated: false
        )
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAndObserve()
            }
        }
        observeChanges()
    }

    deinit {
        if let routeObserver {
            NotificationCenter.default.removeObserver(routeObserver)
        }
    }

    private func observeChanges() {
        guard !isObserving else { return }
        isObserving = true
        withObservationTracking {
            _ = runtime.setup.phase
            _ = runtime.voice.state
            _ = runtime.voice.readyFlashActive
            _ = runtime.voice.isMicrophoneMuted
            _ = runtime.voice.isCarPlayConnected
            _ = runtime.voice.canToggleMicrophoneInput
            _ = runtime.voice.isPreparingDesktopConnection
            _ = runtime.voice.canReconnectFromCarPlay
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.isObserving = false
                self?.refreshAndObserve()
            }
        }
    }

    private func refreshAndObserve() {
        refresh(using: NightBloodCarPlaySnapshot(runtime: runtime))
        observeChanges()
    }

    private func refresh(using snapshot: NightBloodCarPlaySnapshot) {
        guard let template else {
            installTemplate(using: snapshot, animated: true)
            return
        }
        let identifier = resolvedStateIdentifier(for: snapshot)
        guard template.voiceControlStates.contains(where: { $0.identifier == identifier }) else {
            installTemplate(using: snapshot, animated: false)
            return
        }
        configureControls(for: snapshot, states: voiceStates)
        template.activateVoiceControlState(withIdentifier: identifier)
    }

    private func installTemplate(
        using snapshot: NightBloodCarPlaySnapshot,
        animated: Bool
    ) {
        let identifier = resolvedStateIdentifier(for: snapshot)
        let visual = resolvedVisualState(for: snapshot)
        let showingIntro = identifier.hasPrefix("codex-intro-")
        var states: [NightBloodCarPlayVisualState: CPVoiceControlState] = [:]
        let orderedStates = Self.templateStates(current: visual).map { visual in
            let image: UIImage
            if showingIntro {
                if cachedIntroImage == nil {
                    cachedIntroImage = NightBloodCarPlayArtwork.codexIntro(
                        traits: interfaceController.carTraitCollection
                    )
                }
                image = cachedIntroImage!
            } else {
                let artwork = visual.artworkState
                image = cachedImages[artwork] ?? NightBloodCarPlayArtwork.animatedFace(
                    visualState: artwork, traits: interfaceController.carTraitCollection
                )
                cachedImages[artwork] = image
            }
            let state = CPVoiceControlState(
                identifier: (showingIntro ? "codex-intro-" : "") + visual.rawValue,
                titleVariants: [previewState == nil ? visual.label : "Preview · " + visual.label],
                image: image,
                repeats: !showingIntro && visual != .welcoming
            )
            states[visual] = state
            return state
        }
        let template = CPVoiceControlTemplate(voiceControlStates: orderedStates)
        self.template = template
        voiceStates = states
        configureControls(for: snapshot, states: states)

        interfaceController.setRootTemplate(
            template,
            animated: animated
        ) { success, error in
            guard self.template === template else { return }
            if success {
                self.refresh(using: NightBloodCarPlaySnapshot(runtime: self.runtime))
            }
            #if DEBUG
            if !success {
                print(
                    "NightBloodCarPlay root template failed: "
                        + (error?.localizedDescription ?? "unknown error")
                )
            }
            #endif
        }
    }

    /// CarPlay ignores every state after the first five. Put the current
    /// state first (also the initial display), then the frequent voice states.
    /// A transition outside this small set installs a new bounded template.
    static func templateStates(current: NightBloodCarPlayVisualState) -> [NightBloodCarPlayVisualState] {
        var states = [current]
        for state: NightBloodCarPlayVisualState in [.listening, .speaking, .working, .welcoming, .ready] {
            if !states.contains(state) { states.append(state) }
        }
        return Array(states.prefix(5))
    }

    private func resolvedStateIdentifier(for snapshot: NightBloodCarPlaySnapshot) -> String {
        if snapshot.hasConversation { hasRequestedTalk = true }
        let visual = resolvedVisualState(for: snapshot)
        return Self.stateIdentifier(
            visual: visual, hasRequestedTalk: hasRequestedTalk,
            hasConversation: snapshot.hasConversation, isPreview: previewState != nil
        )
    }

    static func stateIdentifier(
        visual: NightBloodCarPlayVisualState, hasRequestedTalk: Bool,
        hasConversation: Bool, isPreview: Bool = false
    ) -> String {
        let showLogo = !hasRequestedTalk && !hasConversation && !isPreview
        return (showLogo ? "codex-intro-" : "") + visual.rawValue
    }

    private func resolvedVisualState(
        for snapshot: NightBloodCarPlaySnapshot
    ) -> NightBloodCarPlayVisualState {
        previewState ?? snapshot.visualState
    }

    private var previewState: NightBloodCarPlayVisualState? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--nightblood-carplay-preview-speaking") {
            return .speaking
        }
        if let argument = arguments.first(where: {
            $0.hasPrefix("--nightblood-carplay-preview=")
        }) {
            return NightBloodCarPlayVisualState(rawValue: String(argument.split(separator: "=").last ?? ""))
        }
        #endif
        return nil
    }

    private func configureControls(
        for snapshot: NightBloodCarPlaySnapshot,
        states: [NightBloodCarPlayVisualState: CPVoiceControlState]
    ) {
        guard let template else { return }
        for state in states.values { state.actionButtons = [] }

        let microphone = Self.imageBarButton(
            image: NightBloodCarPlayArtwork.symbol(
                snapshot.microphoneMuted ? "mic.slash.fill" : "mic.fill",
                pointSize: 24
            )
        ) { [weak self] in
            #if DEBUG
            print("NightBloodCarPlay action=microphone")
            #endif
            await self?.runtime.voice.toggleMicrophoneInput()
        }
        microphone.isEnabled = snapshot.canToggleMicrophone

        let conversation = Self.titleBarButton(
            title: snapshot.hasConversation ? "Stop" : "Talk"
        ) { [weak self] in
            #if DEBUG
            print("NightBloodCarPlay action=conversation")
            #endif
            self?.performConversationAction()
        }
        conversation.buttonStyle = .rounded
        conversation.isEnabled = true

        let reconnect = Self.titleBarButton(title: "Reconnect") { [weak self] in
            self?.runtime.reconnectFromCarPlayUserGesture()
        }
        reconnect.isEnabled = snapshot.canReconnect
        template.leadingNavigationBarButtons = [reconnect]
        template.trailingNavigationBarButtons = [microphone, conversation]
    }

    /// CarPlay delivers button callbacks on an XPC queue. Constructing those
    /// closures inside this `@MainActor` presenter makes Swift infer main-actor
    /// isolation and trap before their bodies run. These nonisolated factories
    /// receive the callback on CarPlay's queue and cross to the main actor
    /// explicitly before touching application state.
    private nonisolated static func imageBarButton(
        image: UIImage,
        action: @escaping @MainActor @Sendable () async -> Void
    ) -> CPBarButton {
        CPBarButton(image: image) { _ in
            Task { @MainActor in await action() }
        }
    }

    private nonisolated static func titleBarButton(
        title: String,
        action: @escaping @MainActor @Sendable () async -> Void
    ) -> CPBarButton {
        CPBarButton(title: title) { _ in
            Task { @MainActor in await action() }
        }
    }

    private func performConversationAction() {
        let snapshot = NightBloodCarPlaySnapshot(runtime: runtime)
        if snapshot.hasConversation {
            NightBloodCarPlayDiagnostics.record("carplay.action.stop")
            runtime.voice.stopFromUserGesture()
            return
        }
        // This visual switch follows the tap, not a successful network reply.
        // Keep normal error/readiness handling below unchanged.
        hasRequestedTalk = true
        refresh(using: snapshot)
        guard snapshot.canStart else {
            NightBloodCarPlayDiagnostics.record(
                "carplay.action.unavailable",
                detail: runtime.setup.statusLabel
            )
            presentUnavailableReason()
            return
        }
        NightBloodCarPlayDiagnostics.record("carplay.action.talk")
        runtime.voice.authoriseAndStartFromCarPlayUserGesture()
    }

    private func presentUnavailableReason() {
        let message: String
        if !runtime.setup.isVoiceReady {
            message = "Complete secure Codex Remote setup before this drive."
        } else {
            message = runtime.voice.lastError ?? "NightBlood Voice is not ready."
        }
        let dismiss = CPAlertAction(title: "OK", style: .cancel) {
            [weak self] _ in
            self?.interfaceController.dismissTemplate(
                animated: true,
                completion: nil
            )
        }
        let alert = CPAlertTemplate(
            titleVariants: [message],
            actions: [dismiss]
        )
        interfaceController.presentTemplate(
            alert,
            animated: true,
            completion: nil
        )
    }
}

@MainActor
@available(iOS 26.4, *)
final class NightBloodCarPlaySceneDelegate: UIResponder,
    CPTemplateApplicationSceneDelegate
{
    private var presenter: NightBloodCarPlayPresenter?

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        NightBloodCarPlayDiagnostics.record("carplay.scene.didConnect")
        let runtime = NightBloodSharedRuntime.shared
        // The iPhone can still offer both characters; the car intentionally
        // has one identity and starts NightBlood whenever it can do so safely.
        _ = runtime.voice.selectFace(NightBloodCarPlayArtwork.character)
        runtime.carPlayDidConnect()
        presenter = NightBloodCarPlayPresenter(
            runtime: runtime,
            interfaceController: interfaceController
        )
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        guard scene is CPTemplateApplicationScene else {
            return
        }
        NightBloodCarPlayDiagnostics.record("carplay.scene.didBecomeActive")
        NightBloodSharedRuntime.shared.carPlayDidBecomeActive()
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        NightBloodCarPlayDiagnostics.record("carplay.scene.didDisconnect")
        presenter = nil
        NightBloodSharedRuntime.shared.carPlayDidDisconnect()
    }
}

enum NightBloodCarPlayArtwork {
    static let character: DirectFaceSkin = .nightblood
    static let frameCount = 30
    static let framesPerSecond: Double = 24
    static let pointSize: CGFloat = 150
    private static let columns = 6
    private static let sourceTileSize = 450

    // Public builds use a system terminal symbol, not a vendor app icon.
    static func codexIntro(traits: UITraitCollection) -> UIImage {
        let size = CGSize(width: pointSize, height: pointSize)
        let format = UIGraphicsImageRendererFormat()
        format.scale = displayScale(for: traits)
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            symbol("terminal", pointSize: 110).withTintColor(.white, renderingMode: .alwaysOriginal)
                .draw(in: CGRect(origin: .zero, size: size))
        }.withRenderingMode(.alwaysOriginal)
    }

    static func symbol(_ name: String, pointSize: CGFloat) -> UIImage {
        UIImage(
            systemName: name,
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: pointSize, weight: .semibold
            )
        ) ?? UIImage()
    }

    static func displayScale(for traits: UITraitCollection) -> CGFloat {
        let scale = traits.displayScale
        return scale.isFinite && scale > 0 ? min(3, max(1, scale)) : 2
    }

    // Load once per state while installing the template, not once per frame.
    // contentsOfFile avoids UIImage's global named-image cache retaining the
    // full 3x atlases after the independent, car-sized frames have been made.
    static func sourceAtlas(for state: NightBloodCarPlayVisualState) -> CGImage? {
        guard let url = Bundle.main.url(
            forResource: "CarPlayFace-" + state.artworkState.rawValue,
            withExtension: "png", subdirectory: "CarPlayArtwork"
        ) else { return nil }
        return UIImage(contentsOfFile: url.path)?.cgImage
    }

    static func animatedFace(
        visualState: NightBloodCarPlayVisualState,
        traits: UITraitCollection
    ) -> UIImage {
        autoreleasepool {
            guard let atlas = sourceAtlas(for: visualState) else {
                assertionFailure("Missing original NightBlood CarPlay artwork")
                return symbol("exclamationmark.triangle", pointSize: 40)
            }
            let frames = (0..<frameCount).map { index in
                autoreleasepool { faceFrame(atlas: atlas, index: index, traits: traits) }
            }
            if visualState == .welcoming {
                return UIImage.animatedImage(with: frames, duration: 2.7) ?? frames[0]
            }
            // Reuse the same UIImage objects on the return leg. A seamless
            // native loop without decoding duplicate frames or a display timer.
            let loop = frames + frames.dropFirst().dropLast().reversed()
            return UIImage.animatedImage(
                with: loop, duration: Double(loop.count) / framesPerSecond
            ) ?? frames[0]
        }
    }

    static func faceFrame(
        atlas: CGImage, index: Int, traits: UITraitCollection
    ) -> UIImage {
        let size = CGSize(width: pointSize, height: pointSize)
        let format = UIGraphicsImageRendererFormat()
        format.scale = displayScale(for: traits)
        format.opaque = false
        format.preferredRange = .standard
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let frame = min(frameCount - 1, max(0, index))
        let crop = atlas.cropping(to: CGRect(
            x: (frame % columns) * sourceTileSize,
            y: (frame / columns) * sourceTileSize,
            width: sourceTileSize, height: sourceTileSize
        ))
        return renderer.image { context in
            context.cgContext.interpolationQuality = .high
            if let crop {
                UIImage(cgImage: crop).draw(in: CGRect(origin: .zero, size: size))
            }
        }.withRenderingMode(.alwaysOriginal)
    }
}
