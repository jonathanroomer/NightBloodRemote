import Foundation
import Observation
import OSLog
import UIKit

enum DirectVoiceSessionState: String, Sendable {
    case unavailable
    case ready
    case connecting
    case listening
    case thinking
    case speaking
    case stopping
    case outcomeUnknown = "outcome_unknown"
    case failed

    func label(agentName: String) -> String {
        switch self {
        case .unavailable: "Codex Remote unavailable"
        case .ready: "Ready to talk"
        case .connecting: "Connecting"
        case .listening: "Listening"
        case .thinking: "\(agentName) is thinking"
        case .speaking: "\(agentName) is speaking"
        case .stopping: "Ending conversation"
        case .outcomeUnknown: "Voice outcome needs review"
        case .failed: "Something went wrong"
        }
    }

    var isActive: Bool {
        switch self {
        case .connecting, .listening, .thinking, .speaking, .stopping: true
        case .unavailable, .ready, .outcomeUnknown, .failed: false
        }
    }

    /// iOS background audio is reserved for a conversation whose media path
    /// has already reached a stable interactive state. Pairing, connecting,
    /// stopping and uncertain outcomes remain foreground-only.
    var mayContinueInBackground: Bool {
        switch self {
        case .listening, .thinking, .speaking: true
        default: false
        }
    }
}

enum DirectReadySound: String, CaseIterable, Sendable {
    case character
    case tone

    var label: String {
        switch self {
        case .character: "Character welcome"
        case .tone: "Short ready tone"
        }
    }
}

enum DirectFaceSkin: String, CaseIterable, Sendable {
    case nightblood
    case marshmallow

    var displayName: String {
        switch self {
        case .nightblood: "NightBlood"
        case .marshmallow: "Marshmallow"
        }
    }
}

private enum DirectVoiceStartSurface {
    case iPhone
    case carPlay
}

struct DirectTranscriptItem: Identifiable, Equatable {
    enum Role: String {
        case user
        case codex
    }

    let id: UUID
    let role: Role
    var text: String
    var isFinal: Bool

    init(
        id: UUID = UUID(),
        role: Role,
        text: String,
        isFinal: Bool
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.isFinal = isFinal
    }
}

enum DirectTranscriptPartialSemantics {
    /// The event contains the complete in-progress text seen so far.
    case cumulative
    /// The event contains only the next exact fragment.
    case incremental
}

/// A native-only provider creates the bounded voice transport. The WebView
/// can neither implement this protocol nor see the context used to build it.
@MainActor
protocol DirectCodexVoiceTransportCreating: AnyObject {
    var isVoiceReady: Bool { get }
    func makeVoiceTransport() async throws -> CodexRemoteVoiceTransport
}

extension DirectCodexRemoteSetupModel: DirectCodexVoiceTransportCreating {
    var isVoiceReady: Bool { phase == .ready }

    func makeVoiceTransport() async throws -> CodexRemoteVoiceTransport {
        try makeVoiceContext().makeVoiceTransport()
    }
}

@MainActor
protocol DirectFaceJavaScriptControlling: AnyObject {
    func setAvailable(_ available: Bool)
    func setWorking(_ active: Bool)
    func setInputMuted(_ muted: Bool) async -> Bool
    func setOutputMuted(_ muted: Bool) async -> Bool
    func resumeAfterBackground(state: DirectVoiceSessionState) async -> Bool
    func setSkin(_ skin: DirectFaceSkin)
    func start(character: DirectFaceSkin)
    func stop()
    func closeLocalOnly()
    func gaze(_ sample: GazeSample)
}

/// Owns one direct Codex Voice session and the one-shot permission allowing
/// the bundled face to submit one SDP offer after the user taps Start.
@MainActor
@Observable
final class DirectVoiceSessionModel {
    /// A cold WKWebView microphone/WebRTC start can take longer than fifteen
    /// seconds on the physical phone. The grant is still foreground-only,
    /// bound to this lifecycle generation and consumed by its first offer.
    private static let startGrantLifetime: TimeInterval = 60

    /// Face ID and the microphone permission sheet can finish just before
    /// UIKit reports the app active again. Wait only for that brief hand-off;
    /// a real background transition invalidates the lifecycle generation.
    private static let foregroundSettleTimeout: TimeInterval = 5

    /// WebKit normally reaches either the native SDP bridge or the live media
    /// event within a few seconds. A native watchdog is still required because
    /// a suspended page cannot run its own JavaScript timeout, which otherwise
    /// leaves every surface permanently showing Connecting until force-quit.
    private static let defaultStartupWatchdogDuration: Duration = .seconds(20)

    private enum StorageKey {
        static let taskID = "nightblood.direct.codex-task-id"
        static let faceSkin = "nightblood.face.skin"
        static let readySound = "nightblood.direct.ready-sound"
        static let nightBloodVoice = "nightblood.direct.voice.nightblood"
        static let marshmallowVoice = "nightblood.direct.voice.marshmallow"
    }

    let agentName: String
    var readySound: DirectReadySound = .character {
        didSet { UserDefaults.standard.set(readySound.rawValue, forKey: StorageKey.readySound) }
    }
    private(set) var selectedFace: DirectFaceSkin = .nightblood {
        didSet {
            UserDefaults.standard.set(
                selectedFace.rawValue,
                forKey: StorageKey.faceSkin
            )
            iPhoneFace?.setSkin(selectedFace)
            carPlayFace?.setSkin(selectedFace)
        }
    }
    private(set) var nightBloodVoice: CodexRemoteVoiceName = .cove {
        didSet {
            UserDefaults.standard.set(
                nightBloodVoice.rawValue,
                forKey: StorageKey.nightBloodVoice
            )
        }
    }
    private(set) var marshmallowVoice: CodexRemoteVoiceName = .sol {
        didSet {
            UserDefaults.standard.set(
                marshmallowVoice.rawValue,
                forKey: StorageKey.marshmallowVoice
            )
        }
    }
    private(set) var isMicrophoneMuted = false {
        didSet { publishLiveActivityState() }
    }
    private(set) var isSpeakerOutputMuted = false {
        didSet { publishLiveActivityState() }
    }
    var state: DirectVoiceSessionState = .unavailable {
        didSet { publishLiveActivityState() }
    }
    var transcript: [DirectTranscriptItem] = [] {
        didSet { transcriptRevision &+= 1 }
    }
    private(set) var transcriptRevision: UInt64 = 0
    private(set) var transcriptCompletionRevision: UInt64 = 0
    var lastError: String?
    var taskReference: String {
        didSet {
            // A pasted Codex URL can contain routing or account context that
            // is not needed after validation. Persist only its canonical task
            // UUID; keep invalid or partially typed input in memory only.
            if let taskID = Self.canonicalTaskID(from: taskReference) {
                UserDefaults.standard.set(taskID, forKey: StorageKey.taskID)
            } else {
                UserDefaults.standard.removeObject(forKey: StorageKey.taskID)
            }
            refreshAvailability()
        }
    }
    private(set) var webReady = false
    private(set) var isCarPlayConnected = false
    private(set) var readyFlashActive = false
    private var readyFlashTask: Task<Void, Never>?

    var hasOwnedVoice: Bool { voice != nil }
    var canStartVoice: Bool {
        state == .ready && desktopPrepared && desktopTransport != nil
    }
    var canRetryVoiceConnection: Bool {
        state == .failed && voice == nil && stopOperation == nil
    }

    var isPreparingDesktopConnection: Bool {
        desktopPreparationID != nil && !desktopPrepared
    }

    var canReconnectFromCarPlay: Bool {
        isCarPlayConnected && canSelectFace && !isPreparingDesktopConnection
    }

    /// Rebuild only idle connection preparation. Never clear an uncertain
    /// session, issue a realtime start, or replay a transcript/tool action.
    @discardableResult
    func resetCarPlayConnectionPreparation() -> Bool {
        guard canReconnectFromCarPlay else { return false }
        cancelDesktopPreparation()
        desktopPreparationFailed = false
        state = .unavailable
        lastError = nil
        return true
    }

    var canSelectFace: Bool {
        voice == nil
            && oneShotStartGrant == nil
            && activeStartOperationID == nil
            && stopOperation == nil
            && !state.isActive
            && state != .outcomeUnknown
    }

    var canChangeVoicePreferences: Bool { canSelectFace }

    private weak var setup: (any DirectCodexVoiceTransportCreating)?
    private weak var iPhoneFace: (any DirectFaceJavaScriptControlling)?
    private weak var carPlayFace: (any DirectFaceJavaScriptControlling)?
    private weak var sessionFace: (any DirectFaceJavaScriptControlling)?
    private var isCarPlayMediaSurfaceHosted = false
    private var face: (any DirectFaceJavaScriptControlling)? {
        // Never switch media owners during a conversation just because the
        // phone UI later appears. Before start, prefer its proven attached
        // controller; a CarPlay-only launch uses the controller hosted by the
        // active CPWindow rather than a suspended, detached WKWebView.
        if let sessionFace { return sessionFace }
        return iPhoneFace ?? carPlayFace
    }
    private let backgroundAudio: any DirectVoiceBackgroundAudioConfiguring
    private let nativeMediaFactory: any DirectNativeVoiceMediaCreating
    private let liveActivityPublisher: any DirectVoiceLiveActivityPublishing
    private let startupWatchdogDuration: Duration
    private let interactiveSurfaceIsActive: @MainActor () -> Bool
    private let gazeTracker = FrontCameraGazeTracker()
    private var gazeRequested = false
    private var faceVisible = true
    @ObservationIgnored private var performanceID = UUID()
    @ObservationIgnored private var performanceOrigin = ProcessInfo.processInfo.systemUptime
    private static let performanceLog = Logger(subsystem: "com.example.nightblood.remote", category: "performance")
    private var latestGaze = GazeSample.absent
    private var voice: CodexRemoteVoiceTransport?
    private var desktopPreparation: Task<Void, Never>?
    private var desktopPreparationID: UUID?
    private var desktopPreparedTaskID: String?
    private var desktopTransport: CodexRemoteVoiceTransport?
    private var desktopPrepared = false
    private var desktopPreparationFailed = false
    private var appInBackground = false
    private var voiceUpdatesTask: Task<Void, Never>?
    private var nativeTranscriptUpdatesTask: Task<Void, Never>?
    private var nativeMedia: (any DirectNativeVoiceMediaControlling)?
    private var oneShotStartGrant: StartGrant?
    private var activeStartOperationID: UUID?
    private var preparedStartID: UUID?
    private var preparedStart: Task<CodexRemoteVoiceTransport, any Error>?
    private var lifecycleGeneration: UInt64 = 0
    private var stopOperation: Task<Void, any Error>?
    private var stopOperationVoice: CodexRemoteVoiceTransport?
    private var terminalCleanupVoice: CodexRemoteVoiceTransport?
    private var lastStopConfirmedAt: Date?
    private var backingWorkActive = false
    private var awaitingAssistant = false
    private var inputMuteOperationID: UUID?
    private var outputMuteOperationID: UUID?
    private var awaitingMediaReady = false
    private var startupWatchdog: Task<Void, Never>?
    private var conversationWasBackgrounded = false

    private struct StartGrant {
        let id: UUID
        let expiresAt: Date
        let taskID: String
        let character: DirectFaceSkin
        let realtimeVoice: CodexRemoteVoiceName
        let personalityPrompt: CodexRemoteVoicePrompt
        let readySound: DirectReadySound
        let lifecycleGeneration: UInt64
        let surface: DirectVoiceStartSurface
    }

    init(
        agentName: String = "NightBlood",
        backgroundAudio: any DirectVoiceBackgroundAudioConfiguring =
            DirectVoiceBackgroundAudioController(),
        nativeMediaFactory: any DirectNativeVoiceMediaCreating =
            DirectNativeWebRTCSessionFactory(),
        liveActivityPublisher: any DirectVoiceLiveActivityPublishing =
            NightBloodVoiceLiveActivityManager.shared,
        startupWatchdogDuration: Duration =
            DirectVoiceSessionModel.defaultStartupWatchdogDuration,
        interactiveSurfaceIsActive: @escaping @MainActor () -> Bool = {
            NightBloodVoiceSceneActivity.isInteractive
        }
    ) {
        self.agentName = agentName
        self.backgroundAudio = backgroundAudio
        self.nativeMediaFactory = nativeMediaFactory
        self.liveActivityPublisher = liveActivityPublisher
        self.startupWatchdogDuration = startupWatchdogDuration
        self.interactiveSurfaceIsActive = interactiveSurfaceIsActive
        let defaults = UserDefaults.standard
        selectedFace = defaults.string(forKey: StorageKey.faceSkin)
            .flatMap(DirectFaceSkin.init(rawValue:)) ?? .nightblood
        nightBloodVoice = defaults.string(forKey: StorageKey.nightBloodVoice)
            .flatMap(CodexRemoteVoiceName.init(rawValue:)) ?? .cove
        marshmallowVoice = defaults.string(forKey: StorageKey.marshmallowVoice)
            .flatMap(CodexRemoteVoiceName.init(rawValue:)) ?? .sol
        // A task ID is account metadata. Public builds start empty. Older
        // builds could store the complete pasted link, so canonicalise it on
        // read and immediately discard any other stored representation.
        readySound = defaults.string(forKey: StorageKey.readySound)
            .flatMap(DirectReadySound.init(rawValue:)) ?? .tone
        let storedTaskReference = defaults.string(forKey: StorageKey.taskID)
        if let storedTaskReference,
           let taskID = Self.canonicalTaskID(from: storedTaskReference)
        {
            taskReference = taskID
            if storedTaskReference != taskID {
                defaults.set(taskID, forKey: StorageKey.taskID)
            }
        } else {
            taskReference = ""
            defaults.removeObject(forKey: StorageKey.taskID)
        }
        gazeTracker.onSample = { [weak self] sample in
            guard let self else { return }
            latestGaze = sample
            iPhoneFace?.gaze(sample)
            carPlayFace?.gaze(sample)
        }
        publishLiveActivityState()
    }



    var statusLabel: String {
        if state == .unavailable, setup?.isVoiceReady == true,
           Self.canonicalTaskID(from: taskReference) == nil {
            return taskReference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Choose a Codex task"
                : "Enter a valid Codex task link or UUID"
        }
        if desktopPreparationID != nil, !desktopPrepared, voice == nil {
            return "Connecting transcript to Codex"
        }
        return state.label(agentName: displayAgentName)
    }

    var displayAgentName: String {
        selectedFace.displayName
    }

    private func publishLiveActivityState() {
        liveActivityPublisher.publish(
            DirectVoiceLiveActivitySnapshot(
                agentName: displayAgentName,
                status: statusLabel,
                sessionState: state.rawValue,
                microphoneMuted: isMicrophoneMuted,
                speakerOutputMuted: isSpeakerOutputMuted,
                shouldBeVisible: state.mayContinueInBackground
            )
        )
    }

    func preferredVoice(for face: DirectFaceSkin) -> CodexRemoteVoiceName {
        switch face {
        case .nightblood: nightBloodVoice
        case .marshmallow: marshmallowVoice
        }
    }

    func setPreferredVoice(
        _ realtimeVoice: CodexRemoteVoiceName,
        for face: DirectFaceSkin
    ) {
        guard canChangeVoicePreferences else { return }
        switch face {
        case .nightblood: nightBloodVoice = realtimeVoice
        case .marshmallow: marshmallowVoice = realtimeVoice
        }
    }

    var canToggleMicrophoneInput: Bool {
        guard voice != nil, inputMuteOperationID == nil else { return false }
        switch state {
        case .listening, .thinking, .speaking: return true
        default: return false
        }
    }

    var canToggleSpeakerOutput: Bool {
        guard voice != nil,
              nativeMedia == nil,
              outputMuteOperationID == nil
        else { return false }
        switch state {
        case .listening, .thinking, .speaking: return true
        default: return false
        }
    }

    func install(setup: any DirectCodexVoiceTransportCreating) {
        self.setup = setup
        refreshAvailability()
    }

    func attach(
        face: any DirectFaceJavaScriptControlling,
        role: DirectFaceControllerRole
    ) {
        switch role {
        case .iPhone:
            iPhoneFace = face
        case .carPlay:
            carPlayFace = face
        }
        refreshWebReadiness()
        face.setSkin(selectedFace)
        face.gaze(latestGaze)
        refreshAvailability()
        #if DEBUG
        print(
            "NightBloodMedia attached role=\(role) "
                + "hostedCarPlay=\(isCarPlayMediaSurfaceHosted) "
                + "webReady=\(webReady)"
        )
        #endif
    }

    func attach(face: any DirectFaceJavaScriptControlling) {
        attach(face: face, role: .iPhone)
    }

    func carPlayMediaSurfaceDidAttach() {
        isCarPlayMediaSurfaceHosted = true
        refreshWebReadiness()
        refreshAvailability()
    }

    func carPlayMediaSurfaceDidDetach() {
        isCarPlayMediaSurfaceHosted = false
        refreshWebReadiness()
        refreshAvailability()
    }

    func detach(
        face: any DirectFaceJavaScriptControlling,
        role: DirectFaceControllerRole
    ) {
        switch role {
        case .iPhone:
            if iPhoneFace === face { iPhoneFace = nil }
        case .carPlay:
            if carPlayFace === face { carPlayFace = nil }
        }
        refreshWebReadiness()
        refreshAvailability()
    }

    @discardableResult
    func selectAdjacentFace(offset: Int) -> Bool {
        guard canSelectFace,
              let current = DirectFaceSkin.allCases.firstIndex(of: selectedFace)
        else { return false }
        let destination = current + offset
        guard DirectFaceSkin.allCases.indices.contains(destination) else {
            return false
        }
        selectedFace = DirectFaceSkin.allCases[destination]
        return true
    }

    /// Selects an exact character for non-swipe surfaces such as CarPlay.
    /// The same idle-only guard used by the iPhone picker remains authoritative.
    @discardableResult
    func selectFace(_ face: DirectFaceSkin) -> Bool {
        guard canSelectFace else { return false }
        guard selectedFace != face else { return true }
        selectedFace = face
        return true
    }

    func toggleSpeakerOutput() async {
        guard canToggleSpeakerOutput, let face else { return }
        let target = !isSpeakerOutputMuted
        let operationID = UUID()
        let generation = lifecycleGeneration
        outputMuteOperationID = operationID
        let confirmed = await face.setOutputMuted(target)
        guard outputMuteOperationID == operationID else { return }
        outputMuteOperationID = nil
        guard confirmed,
              generation == lifecycleGeneration,
              voice != nil
        else {
            return
        }
        isSpeakerOutputMuted = target
    }

    func toggleMicrophoneInput() async {
        guard canToggleMicrophoneInput else { return }
        let target = !isMicrophoneMuted
        let operationID = UUID()
        let generation = lifecycleGeneration
        inputMuteOperationID = operationID
        let confirmed: Bool
        if let nativeMedia {
            confirmed = nativeMedia.setInputMuted(target)
        } else if let face {
            confirmed = await face.setInputMuted(target)
        } else {
            confirmed = false
        }
        guard inputMuteOperationID == operationID else { return }
        inputMuteOperationID = nil
        guard generation == lifecycleGeneration,
              voice != nil
        else {
            return
        }
        guard confirmed else {
            // Microphone state is privacy-significant. If the trusted page
            // cannot prove the requested state, fail closed rather than show
            // a potentially false mute indicator.
            lastError = "The microphone change could not be confirmed, so the conversation is ending."
            face?.closeLocalOnly()
            nativeMedia?.close()
            stopFromUserGesture()
            return
        }
        isMicrophoneMuted = target
    }

    func startGazeTracking() {
        gazeRequested = true
        if faceVisible { gazeTracker.start() }
    }

    func pauseGazeTracking() {
        gazeRequested = false
        gazeTracker.pause()
    }

    func setFaceVisible(_ visible: Bool) {
        faceVisible = visible
        if visible && gazeRequested {
            gazeTracker.start()
        } else {
            gazeTracker.pause()
        }
    }

    /// Called while DeviceAccessGate holds a Face-ID-unlocked phone session.
    /// The WebView gets no token: it receives one invocation and must supply a
    /// valid SDP offer within the short-lived native grant.
    func authoriseAndStartFromUserGesture() {
        authoriseAndStartFromUserGesture(surface: .iPhone)
    }

    /// CarPlay itself is the foreground, user-operated surface. A tap here is
    /// allowed to create the same one-shot grant without waking or unlocking
    /// the phone screen; all persisted pairing and transport checks remain.
    func authoriseAndStartFromCarPlayUserGesture() {
        guard isCarPlayConnected else { return }
        authoriseAndStartFromUserGesture(surface: .carPlay)
    }

    private func authoriseAndStartFromUserGesture(
        surface: DirectVoiceStartSurface
    ) {
        if canRetryVoiceConnection {
            desktopPreparationFailed = false
            state = .unavailable
            lastError = nil
            refreshAvailability()
            return
        }
        guard voice == nil,
              oneShotStartGrant == nil,
              activeStartOperationID == nil,
              stopOperation == nil,
              state != .outcomeUnknown
        else {
            if state == .outcomeUnknown {
                lastError = "Review the uncertain Voice outcome before starting another session."
            }
            return
        }
        guard let setup, setup.isVoiceReady else {
            state = .unavailable
            lastError = "Finish secure Codex Remote setup before starting Voice."
            return
        }
        guard let taskID = Self.canonicalTaskID(from: taskReference) else {
            state = .failed
            lastError = "Choose a Codex task link or task ID before starting Voice."
            return
        }
        guard desktopPrepared, desktopPreparedTaskID == taskID,
              desktopTransport != nil else {
            refreshAvailability()
            return
        }
        let startFace: (any DirectFaceJavaScriptControlling)?
        switch surface {
        case .iPhone:
            guard webReady, let face else {
                state = .failed
                lastError = "The bundled NightBlood face is not ready."
                return
            }
            startFace = face
        case .carPlay:
            startFace = nil
        }
        let character = selectedFace
        let personalityPrompt: CodexRemoteVoicePrompt
        do {
            personalityPrompt = try DirectCharacterPromptStore.load(
                for: character
            )
        } catch {
            state = .failed
            lastError = error.localizedDescription
            return
        }
        do {
            // Configure only. WebKit activates and owns the session when it
            // opens the microphone, avoiding the start regression caused by
            // competing with getUserMedia for active audio ownership.
            try backgroundAudio.configureForVoice()
        } catch {
            state = .failed
            lastError = "The iPhone background voice audio could not be configured."
            return
        }
        advanceLifecycleGeneration()
        let grant = StartGrant(
            id: UUID(),
            expiresAt: Date().addingTimeInterval(Self.startGrantLifetime),
            taskID: taskID,
            character: character,
            realtimeVoice: preferredVoice(for: character),
            personalityPrompt: personalityPrompt,
            readySound: readySound,
            lifecycleGeneration: lifecycleGeneration,
            surface: surface
        )
        performanceID = grant.id
        performanceOrigin = ProcessInfo.processInfo.systemUptime
        tracePerformance("start.authorised")
        oneShotStartGrant = grant
        sessionFace = startFace
        awaitingMediaReady = true
        state = .connecting
        lastError = nil
        #if DEBUG
        let mediaOwner = startFace == nil ? "native-CarPlay" : "iPhone"
        print(
            "NightBloodMedia start surface=\(surface) "
                + "owner=\(mediaOwner)"
        )
        #endif
        // The gesture consumes the attached connection and authorises one
        // media offer. Fresh attestation can overlap microphone/ICE.
        preparedStartID = grant.id
        preparedStart = Task { @MainActor [weak self] in
            guard let self else { throw CodexRemoteVoiceError.cancelled }
            return try await self.prepareConnection(for: grant)
        }
        if let startFace {
            armOfferWatchdog(for: grant)
            startFace.start(character: character)
        } else {
            Task { @MainActor [weak self] in
                await self?.startNativeCarPlay(grant)
            }
        }
    }

    func stopFromUserGesture() {
        guard state.isActive || voice != nil else { return }
        let stoppingFace = face
        cancelStartupWatchdog()
        oneShotStartGrant = nil
        awaitingMediaReady = false
        conversationWasBackgrounded = false
        advanceLifecycleGeneration()
        state = .stopping
        nativeMedia?.close()
        if let voice {
            _ = beginStop(for: voice)
        } else {
            // No native transport exists, so cancellation is already
            // definitive. A late JavaScript stop acknowledgement may safely
            // consume this confirmation without touching a later session.
            lastStopConfirmedAt = Date()
            lastError = nil
            if activeStartOperationID == nil {
                sessionFace = nil
                state = isConfigured ? .ready : .unavailable
                refreshAvailability()
            }
        }
        // Local microphone/WebRTC closure is best-effort presentation work.
        // The native stop above owns the security boundary even if the page
        // has reloaded or JavaScript cannot answer.
        stoppingFace?.stop()
    }

    private func failPreparedStart(_ grant: StartGrant, error: String) {
        guard grant.lifecycleGeneration == lifecycleGeneration else { return }
        oneShotStartGrant = nil
        awaitingMediaReady = false
        advanceLifecycleGeneration()
        releaseSessionFace(closeLocalMedia: true)
        if let voice {
            _ = beginStop(for: voice, terminalError: error)
        } else {
            state = .failed
            lastError = error
        }
    }

    private func prepareConnection(for grant: StartGrant) async throws
        -> CodexRemoteVoiceTransport
    {
        let becameActive = await waitForInteractiveSurface(for: grant)
        guard becameActive,
              !Task.isCancelled,
              grant.lifecycleGeneration == lifecycleGeneration,
              Date() <= grant.expiresAt,
              isStartSurfaceActive(grant.surface),
              voice == nil,
              desktopPrepared,
              desktopPreparedTaskID == grant.taskID,
              let transport = desktopTransport
        else { throw CodexRemoteVoiceError.cancelled }
        desktopPreparationID = nil
        desktopPreparation?.cancel()
        desktopPreparation = nil
        desktopTransport = nil
        desktopPreparedTaskID = nil
        desktopPrepared = false
        guard !Task.isCancelled,
              grant.lifecycleGeneration == lifecycleGeneration,
              Date() <= grant.expiresAt,
              isStartSurfaceActive(grant.surface)
        else {
            await transport.close()
            throw CodexRemoteVoiceError.cancelled
        }
        voice = transport
        observe(transport)
        do {
            tracePerformance("attestation.begin")
            try await transport.prepareVoiceStart(performanceID: grant.id)
            tracePerformance("attestation.ready")
            guard !Task.isCancelled,
                  grant.lifecycleGeneration == lifecycleGeneration,
                  isStartSurfaceActive(grant.surface),
                  voice === transport
            else { throw CodexRemoteVoiceError.cancelled }
            return transport
        } catch {
            if voice === transport, stopOperationVoice !== transport {
                await transport.close()
                releaseVoice(ifIdenticalTo: transport)
            }
            if grant.lifecycleGeneration == lifecycleGeneration {
                oneShotStartGrant = nil
                awaitingMediaReady = false
                state = .failed
                lastError = error.localizedDescription
                releaseSessionFace(closeLocalMedia: true)
            }
            throw error
        }
    }

    private func startNativeCarPlay(_ grant: StartGrant) async {
        guard oneShotStartGrant?.id == grant.id else { return }
        oneShotStartGrant = nil
        guard grant.lifecycleGeneration == lifecycleGeneration,
              isStartSurfaceActive(.carPlay),
              preparedStartID == grant.id,
              let preparedStart
        else {
            settleCancelledStartWait()
            return
        }

        activeStartOperationID = grant.id
        defer { finishStartOperation(grant.id) }

        do {
            let media = try nativeMediaFactory.makeSession()
            nativeMedia = media
            // Connection preparation is already running from the gesture.
            // Await the media branch here so an offer failure cancels that
            // preparation promptly, before any realtime start is possible.
            let offer = try await media.makeOffer()
            tracePerformance("native.offer.ready")
            let transport = try await preparedStart.value
            guard grant.lifecycleGeneration == lifecycleGeneration,
                  isStartSurfaceActive(.carPlay)
            else {
                media.close()
                nativeMedia = nil
                throw CodexRemoteVoiceError.cancelled
            }

            tracePerformance("realtime.start.begin")
            let result = try await transport.start(
                threadID: grant.taskID,
                sdpOffer: offer,
                voice: grant.realtimeVoice,
                prompt: grant.personalityPrompt
            )
            guard grant.lifecycleGeneration == lifecycleGeneration,
                  isStartSurfaceActive(.carPlay),
                  voice === transport,
                  nativeMedia === media
            else {
                media.close()
                _ = beginStop(for: transport)
                throw CodexRemoteVoiceError.cancelled
            }
            try await media.acceptAnswer(result.sdpAnswer)
            await media.playReadyCue(character: grant.character, sound: grant.readySound)
            guard grant.lifecycleGeneration == lifecycleGeneration,
                  voice === transport, nativeMedia === media
            else { throw CodexRemoteVoiceError.cancelled }
            guard media.setInputMuted(isMicrophoneMuted) else {
                throw DirectNativeWebRTCError.connectionFailed
            }
            awaitingMediaReady = false
            state = .listening
            showReadyFlash()
            lastError = nil
        } catch {
            if grant.lifecycleGeneration == lifecycleGeneration {
                advanceLifecycleGeneration()
            }
            nativeMedia?.close()
            nativeMedia = nil
            awaitingMediaReady = false
            guard let transport = voice else {
                if !(error is CancellationError),
                   (error as? CodexRemoteVoiceError) != .cancelled
                {
                    state = .failed
                    lastError = error.localizedDescription
                }
                return
            }
            let snapshot = await transport.snapshot()
            apply(snapshot)
            switch snapshot.state {
            case .started:
                _ = beginStop(
                    for: transport,
                    terminalError: error.localizedDescription
                )
            case .startOutcomeUnknown, .stopping, .stopOutcomeUnknown:
                break
            default:
                await transport.close()
                releaseVoice(ifIdenticalTo: transport)
                state = .failed
                lastError = error.localizedDescription
            }
        }
    }

    /// The only mutating entry point callable from JavaScript. It consumes the
    /// native one-shot grant before its first suspension.
    func bridgeStart(sdpOffer: String) async throws
        -> CodexRemoteVoiceStartResult
    {
        guard let grant = oneShotStartGrant else {
            throw DirectVoiceSessionError.startNotAuthorised
        }
        tracePerformance("browser.offer.received")
        cancelStartupWatchdog()
        oneShotStartGrant = nil
        guard Date() <= grant.expiresAt,
              selectedFace == grant.character,
              grant.lifecycleGeneration == lifecycleGeneration
        else {
            failPreparedStart(grant, error: DirectVoiceSessionError.startGrantExpired.localizedDescription)
            throw DirectVoiceSessionError.startGrantExpired
        }
        let becameActive = await waitForInteractiveSurface(for: grant)
        guard becameActive,
              Date() <= grant.expiresAt,
              grant.lifecycleGeneration == lifecycleGeneration,
              isStartSurfaceActive(grant.surface)
        else {
            if Task.isCancelled
                || grant.lifecycleGeneration != lifecycleGeneration
                || !isStartSurfaceActive(grant.surface)
            {
                if grant.lifecycleGeneration == lifecycleGeneration {
                    stopFromUserGesture()
                }
                settleCancelledStartWait()
                throw CodexRemoteVoiceError.cancelled
            }
            let error: DirectVoiceSessionError = Date() > grant.expiresAt
                ? .startGrantExpired
                : .applicationDidNotBecomeActive
            failPreparedStart(grant, error: error.localizedDescription)
            throw error
        }
        guard preparedStartID == grant.id, let preparedStart else {
            throw DirectVoiceSessionError.sessionAlreadyOwned
        }

        activeStartOperationID = grant.id
        defer { finishStartOperation(grant.id) }

        let transport: CodexRemoteVoiceTransport
        do {
            transport = try await preparedStart.value
        } catch {
            failPreparedStart(grant, error: error.localizedDescription)
            throw error
        }
        guard grant.lifecycleGeneration == lifecycleGeneration,
              isStartSurfaceActive(grant.surface)
        else {
            await transport.close()
            awaitingMediaReady = false
            releaseSessionFace(closeLocalMedia: true)
            throw CodexRemoteVoiceError.cancelled
        }
        guard voice === transport else { throw CodexRemoteVoiceError.cancelled }
        do {
            tracePerformance("realtime.start.begin")
            let result = try await transport.start(
                threadID: grant.taskID,
                sdpOffer: sdpOffer,
                voice: grant.realtimeVoice,
                prompt: grant.personalityPrompt
            )
            // The App Server answer is necessary but not yet proof that the
            // phone's WebRTC peer and realtime event channel are live. The
            // trusted page's subsequent `session/live` event owns the visible
            // Listening transition and its one-shot ready cue.
            tracePerformance("realtime.answer.ready")
            state = .connecting
            lastError = nil
            armMediaReadyWatchdog(
                for: transport,
                lifecycleGeneration: grant.lifecycleGeneration
            )
            return result
        } catch {
            let snapshot = await transport.snapshot()
            guard voice === transport else { throw error }
            if stopOperationVoice === transport {
                // The one native stop owner controls terminal state and
                // cleanup. A suspended start must not close underneath it.
                throw error
            }
            apply(snapshot)
            switch snapshot.state {
            case .startOutcomeUnknown, .stopping, .stopOutcomeUnknown:
                break
            default:
                await transport.close()
                releaseVoice(ifIdenticalTo: transport)
            }
            throw error
        }
    }

    func bridgeStop() async throws {
        if let stopOperation {
            try await stopOperation.value
            return
        }
        if hasRecentConfirmedStop {
            return
        }
        throw DirectVoiceSessionError.noOwnedSession
    }

    func applicationDidEnterBackground() {
        appInBackground = true
        pauseGazeTracking()
        // UIKit backgrounds the phone scene independently of the foreground
        // CarPlay scene. Connection is the stable lifecycle boundary here;
        // foregroundActive briefly lags during a cold launch and previously
        // caused the controller to be torn down before CarPlay became usable.
        if isCarPlayConnected {
            return
        }
        let preservesConversation = state.mayContinueInBackground
            && voice != nil
            && oneShotStartGrant == nil
            && activeStartOperationID == nil
            && stopOperation == nil
        conversationWasBackgrounded = preservesConversation
        if preservesConversation, let voice {
            Task {
                await voice.applicationDidEnterBackground(
                    preserveActiveSession: true
                )
            }
            return
        }
        stopForLifecycleLoss(closeLocalMedia: true)
    }

    func applicationDidBecomeActive() {
        appInBackground = false
        if canRetryVoiceConnection {
            desktopPreparationFailed = false
            state = .unavailable
            lastError = nil
        }
        guard let voice else {
            conversationWasBackgrounded = false
            refreshAvailability()
            return
        }
        let shouldResumeMedia = conversationWasBackgrounded
        conversationWasBackgrounded = false
        Task { [weak self] in
            await voice.applicationDidBecomeActive()
            let snapshot = await voice.snapshot()
            guard let self, self.voice === voice else { return }
            self.apply(snapshot)
            guard shouldResumeMedia else { return }
            let resumed = await self.face?.resumeAfterBackground(
                state: self.state
            ) ?? false
            #if DEBUG
            print(
                "NightBloodBackground foreground state=\(self.state.rawValue) "
                    + "mediaResumed=\(resumed)"
            )
            #endif
        }
    }

    func carPlayDidConnect() {
        isCarPlayConnected = true
        refreshWebReadiness()
        refreshAvailability()
    }

    func carPlayDidDisconnect() {
        isCarPlayConnected = false
        refreshWebReadiness()
        guard !NightBloodVoiceSceneActivity.isIPhoneApplicationActive else {
            refreshAvailability()
            return
        }
        stopForLifecycleLoss(closeLocalMedia: true)
    }

    private func stopForLifecycleLoss(closeLocalMedia: Bool) {
        cancelDesktopPreparation()
        cancelStartupWatchdog()
        oneShotStartGrant = nil
        awaitingMediaReady = false
        conversationWasBackgrounded = false
        advanceLifecycleGeneration()
        if closeLocalMedia {
            face?.closeLocalOnly()
            nativeMedia?.close()
        }
        guard let voice else {
            sessionFace = nil
            refreshAvailability()
            return
        }
        let lease = DirectBackgroundLease {
            await voice.backgroundLeaseDidExpire()
        }
        Task { [weak self] in
            defer { lease.end() }
            await voice.applicationDidEnterBackground(
                preserveActiveSession: false
            )
            let snapshot = await voice.snapshot()
            await MainActor.run {
                guard let self, self.voice === voice else { return }
                self.apply(snapshot)
                self.releaseVoice(ifIdenticalTo: voice)
            }
        }
    }

    func handleEventMessage(_ value: Any) {
        guard let message = value as? [String: Any],
              let type = message["type"] as? String,
              Self.serialisedSize(of: message) <= 64 * 1024
        else {
            return
        }
        switch type {
        case "ready":
            return
        case "session":
            guard let eventState = message["state"] as? String else { return }
            if eventState == "live" {
                let firstReady = awaitingMediaReady
                tracePerformance("microphone.ready")
                cancelStartupWatchdog()
                awaitingMediaReady = false
                state = .listening
                if firstReady { showReadyFlash() }
                lastError = nil
            } else if eventState == "error" {
                cancelStartupWatchdog()
                let detail = (message["detail"] as? String)?.prefix(512)
                let failure = detail.map(String.init)
                    ?? "The NightBlood media connection failed."
                if voice == nil, hasRecentConfirmedStop {
                    return
                }
                oneShotStartGrant = nil
                awaitingMediaReady = false
                advanceLifecycleGeneration()
                lastError = failure
                if let voice {
                    state = .stopping
                    _ = beginStop(for: voice, terminalError: failure)
                } else {
                    releaseSessionFace(closeLocalMedia: true)
                    state = .failed
                }
            }
        case "event":
            guard let kind = message["kind"] as? String else { return }
            #if DEBUG
            if kind == "background-media-resumed"
                || kind == "background-media-resume-failed"
            {
                let detail = message["detail"] as? [String: Any] ?? [:]
                print("NightBloodBackground event=\(kind) detail=\(detail)")
            }
            #endif
            if ["speech-started", "speech-stopped", "assistant-speaking", "assistant-done"].contains(kind) {
                tracePerformance(kind)
            }
            if kind == "performance", let detail = message["detail"] as? [String: Any],
               let stage = detail["stage"] as? String,
               ["microphone.acquired", "offer.ready", "answer.ready", "microphone.ready", "output.first", "network.stats"].contains(stage)
            {
                tracePerformance("browser." + stage)
                let numeric = ["elapsedMs", "rttMs", "jitterMs", "packetsLost"]
                    .compactMap { key -> String? in
                        guard let number = detail[key] as? Double, number.isFinite,
                              number >= 0, number < 10_000_000 else { return nil }
                        return "\(key)=\(number)"
                    }.joined(separator: " ")
                Self.performanceLog.info("voice id=\(self.performanceID.uuidString, privacy: .public) metrics=\(numeric, privacy: .public)")
            }
            switch kind {
            case "speech-started":
                awaitingAssistant = false
                state = .listening
            case "speech-stopped", "delegation-started":
                awaitingAssistant = true
                state = .thinking
            case "assistant-speaking":
                awaitingAssistant = false
                state = .speaking
            case "assistant-done":
                awaitingAssistant = false
                state = backingWorkActive ? .thinking : .listening
            default: break
            }
        case "transcript":
            guard let role = message["role"] as? String,
                  let text = message["text"] as? String,
                  text.utf8.count <= 16_384,
                  let done = message["done"] as? Bool
            else {
                return
            }
            mergeTranscript(role: role, text: text, done: done)
        default:
            return
        }
    }

    func faceProcessWillReload(
        face: any DirectFaceJavaScriptControlling,
        role: DirectFaceControllerRole
    ) {
        let wasActive = self.face === face
        detach(face: face, role: role)
        pauseGazeTracking()
        if wasActive {
            stopForLifecycleLoss(closeLocalMedia: false)
        }
    }

    func refreshAvailability() {
        let taskID = Self.canonicalTaskID(from: taskReference)
        let eligible = isConfigured && (!appInBackground || isCarPlayConnected)
            // CarPlay didConnect precedes foregroundActive on a cold launch.
            // Wait for the scene callback before starting the foreground-only
            // Remote handshake. Merely being plugged in is not readiness.
            && interactiveSurfaceIsActive()
            && voice == nil && state != .outcomeUnknown
        if desktopPreparedTaskID != taskID || !eligible {
            cancelDesktopPreparation()
        }
        // `available` answers whether a new conversation may start. During an
        // owned live conversation it is necessarily false, but that must not
        // be forwarded as a disconnected face state. Foreground setup refresh
        // runs after Face ID and previously pinned the eyes offline while the
        // independent WebRTC audio path (and therefore the mouth) kept moving.
        guard !state.isActive,
              state != .outcomeUnknown,
              state != .failed
        else {
            return
        }
        if eligible, let taskID, desktopPreparationID == nil {
            beginDesktopPreparation(taskID: taskID)
        }
        let available = eligible && desktopPrepared
            && (webReady || isCarPlayConnected)
        face?.setAvailable(available)
        state = available ? .ready : .unavailable
    }

    private func cancelDesktopPreparation() {
        desktopPreparationID = nil
        desktopPreparation?.cancel()
        desktopPreparation = nil
        desktopPrepared = false
        desktopPreparedTaskID = nil
        if let transport = desktopTransport {
            desktopTransport = nil
            Task { await transport.close() }
        }
    }

    private func beginDesktopPreparation(taskID: String) {
        guard let setup else { return }
        let preparationID = UUID()
        desktopPreparationID = preparationID
        desktopPreparedTaskID = taskID
        desktopPreparation = Task { @MainActor [weak self] in
            guard let self else { return }
            var created: CodexRemoteVoiceTransport?
            do {
                let transport = try await setup.makeVoiceTransport()
                created = transport
                guard self.desktopPreparationID == preparationID, !Task.isCancelled else {
                    await transport.close()
                    return
                }
                self.desktopTransport = transport
                try await transport.connect()
                try await transport.prepareDesktopTranscript(threadID: taskID)
                guard self.desktopPreparationID == preparationID, !Task.isCancelled else {
                    await transport.close()
                    return
                }
                self.desktopPrepared = true
                self.desktopPreparationFailed = false
                self.lastError = nil
                self.refreshAvailability()
                let updates = await transport.updates()
                for await snapshot in updates {
                    guard self.desktopPreparationID == preparationID, !Task.isCancelled else { return }
                    if snapshot.transportClosed || snapshot.state == .failed {
                        throw CodexRemoteVoiceError.desktopTranscriptUnavailable
                    }
                }
            } catch {
                await created?.close()
                guard self.desktopPreparationID == preparationID, !Task.isCancelled else { return }
                self.desktopPreparationID = nil
                self.desktopTransport = nil
                self.desktopPrepared = false
                self.desktopPreparationFailed = true
                self.state = .failed
                self.face?.setAvailable(false)
                self.lastError = error.localizedDescription
            }
        }
    }

    private var isConfigured: Bool {
        setup?.isVoiceReady == true
            && Self.canonicalTaskID(from: taskReference) != nil
    }

    private func observe(_ transport: CodexRemoteVoiceTransport) {
        voiceUpdatesTask?.cancel()
        voiceUpdatesTask = Task { [weak self] in
            let updates = await transport.updates()
            for await snapshot in updates {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.voice === transport else { return }
                    self.handleObservedSnapshot(snapshot, from: transport)
                }
            }
        }
        nativeTranscriptUpdatesTask?.cancel()
        nativeTranscriptUpdatesTask = Task { [weak self] in
            let updates = await transport.transcriptUpdates()
            for await event in updates {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self,
                          self.voice === transport,
                          self.nativeMedia != nil
                    else { return }
                    self.handleNativeTranscript(event)
                }
            }
        }
    }

    private func handleNativeTranscript(
        _ event: CodexRemoteVoiceTranscriptEvent
    ) {
        mergeTranscript(
            role: event.role,
            text: event.text,
            done: event.isFinal,
            partialSemantics: .incremental
        )

        if event.role == "user" {
            awaitingAssistant = event.isFinal
            state = event.isFinal ? .thinking : .listening
        } else {
            awaitingAssistant = false
            state = event.isFinal
                ? (backingWorkActive ? .thinking : .listening)
                : .speaking
        }
    }

    private func handleObservedSnapshot(
        _ snapshot: CodexRemoteVoiceSnapshot,
        from transport: CodexRemoteVoiceTransport
    ) {
        apply(snapshot)
        guard voice === transport,
              stopOperationVoice !== transport,
              terminalCleanupVoice !== transport
        else {
            return
        }

        switch snapshot.state {
        case .closed, .failed, .startOutcomeUnknown, .stopOutcomeUnknown:
            break
        default:
            return
        }

        // Transport-driven terminal events (including the session guard) must
        // close the iPhone microphone/peer without waiting for JavaScript to
        // infer that the native WSS ended.
        face?.closeLocalOnly()
        let terminalDetail = snapshot.errorDescription
        if !snapshot.transportClosed,
           snapshot.threadID != nil,
           !snapshot.realtimeClosed,
           snapshot.state == .failed
                || snapshot.state == .startOutcomeUnknown
        {
            _ = beginStop(
                for: transport,
                terminalError: terminalDetail
                    ?? "The Codex Voice transport ended unexpectedly."
            )
            return
        }

        terminalCleanupVoice = transport
        Task { @MainActor [weak self] in
            await transport.close()
            guard let self, self.voice === transport else { return }
            self.releaseVoice(ifIdenticalTo: transport)
        }
    }

    private func apply(_ snapshot: CodexRemoteVoiceSnapshot) {
        backingWorkActive = snapshot.backingWorkActive
        face?.setWorking(snapshot.backingWorkActive)
        if let detail = snapshot.errorDescription, !detail.isEmpty {
            lastError = detail
        }
        switch snapshot.state {
        case .disconnected: break
        case .connecting, .connected, .preparing, .starting:
            state = .connecting
        case .started:
            if awaitingMediaReady && state == .connecting {
                break
            } else if snapshot.backingWorkActive {
                if state != .speaking { state = .thinking }
            } else if state == .connecting
                || (state == .thinking && !awaitingAssistant)
            {
                state = .listening
            }
        case .stopping:
            state = .stopping
        case .startOutcomeUnknown, .stopOutcomeUnknown:
            state = .outcomeUnknown
        case .failed:
            state = .failed
        case .closed:
            if state != .outcomeUnknown {
                state = stopOperation != nil || activeStartOperationID != nil
                    ? .stopping
                    : (isConfigured ? .ready : .unavailable)
            }
        }
    }

    private func releaseVoice(
        ifIdenticalTo transport: CodexRemoteVoiceTransport
    ) {
        guard voice === transport else { return }
        cancelStartupWatchdog()
        voiceUpdatesTask?.cancel()
        voiceUpdatesTask = nil
        nativeTranscriptUpdatesTask?.cancel()
        nativeTranscriptUpdatesTask = nil
        nativeMedia?.close()
        nativeMedia = nil
        voice = nil
        backingWorkActive = false
        awaitingAssistant = false
        inputMuteOperationID = nil
        isMicrophoneMuted = false
        outputMuteOperationID = nil
        isSpeakerOutputMuted = false
        awaitingMediaReady = false
        conversationWasBackgrounded = false
        sessionFace?.setWorking(false)
        sessionFace = nil
        if terminalCleanupVoice === transport {
            terminalCleanupVoice = nil
        }
        refreshAvailability()
    }

    /// Creates exactly one native stop owner for a transport. User Stop,
    /// JavaScript acknowledgement and media-failure cleanup all share it, so
    /// the possibly-executed realtime mutation is never retried.
    private func beginStop(
        for transport: CodexRemoteVoiceTransport,
        terminalError: String? = nil
    ) -> Task<Void, any Error> {
        if let stopOperation, stopOperationVoice === transport {
            return stopOperation
        }

        let operation = Task { @MainActor [weak self] () throws -> Void in
            guard let self else {
                await transport.close()
                throw CodexRemoteVoiceError.cancelled
            }
            defer {
                if self.stopOperationVoice === transport {
                    self.stopOperation = nil
                    self.stopOperationVoice = nil
                    self.refreshAvailability()
                }
            }
            self.state = .stopping
            do {
                try await transport.stop()
                await transport.close()
                guard self.voice === transport else { return }
                self.face?.closeLocalOnly()
                self.lastStopConfirmedAt = Date()
                self.releaseVoice(ifIdenticalTo: transport)
                if let terminalError {
                    self.state = .failed
                    self.lastError = terminalError
                } else if self.activeStartOperationID != nil {
                    self.state = .stopping
                    self.lastError = nil
                } else {
                    self.state = self.isConfigured ? .ready : .unavailable
                    self.lastError = nil
                }
            } catch {
                let snapshot = await transport.snapshot()
                let detail = snapshot.errorDescription
                    ?? error.localizedDescription
                await transport.close()
                if self.voice === transport {
                    self.face?.closeLocalOnly()
                    self.state = .outcomeUnknown
                    self.lastError = detail
                    self.releaseVoice(ifIdenticalTo: transport)
                }
                throw error
            }
        }
        stopOperationVoice = transport
        stopOperation = operation
        return operation
    }

    private var hasRecentConfirmedStop: Bool {
        guard let lastStopConfirmedAt else { return false }
        let elapsed = Date().timeIntervalSince(lastStopConfirmedAt)
        return elapsed >= 0 && elapsed <= 10
    }

    private func tracePerformance(_ stage: String) {
        let elapsedMs = (ProcessInfo.processInfo.systemUptime - performanceOrigin) * 1_000
        Self.performanceLog.info("voice id=\(self.performanceID.uuidString, privacy: .public) stage=\(stage, privacy: .public) elapsedMs=\(elapsedMs, privacy: .public)")
    }

    private func finishStartOperation(_ operationID: UUID) {
        guard activeStartOperationID == operationID else { return }
        activeStartOperationID = nil
        if preparedStartID == operationID {
            preparedStart = nil
            preparedStartID = nil
        }
        if state == .stopping,
           voice == nil,
           hasRecentConfirmedStop
        {
            state = isConfigured ? .ready : .unavailable
            lastError = nil
            refreshAvailability()
        }
    }

    private func showReadyFlash() {
        readyFlashTask?.cancel()
        readyFlashActive = true
        readyFlashTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(2_700))
            } catch { return }
            self?.readyFlashActive = false
            self?.readyFlashTask = nil
        }
    }

    private func advanceLifecycleGeneration() {
        readyFlashTask?.cancel()
        readyFlashTask = nil
        readyFlashActive = false
        cancelStartupWatchdog()
        preparedStart?.cancel()
        preparedStart = nil
        preparedStartID = nil
        inputMuteOperationID = nil
        outputMuteOperationID = nil
        lifecycleGeneration = lifecycleGeneration == UInt64.max
            ? 0 : lifecycleGeneration + 1
    }

    private func refreshWebReadiness() {
        // Loading the bundled page is not sufficient evidence for CarPlay:
        // its controller must also be attached to the active CPWindow. The
        // ordinary iPhone controller is already attached by UIViewRepresentable.
        webReady = isCarPlayConnected
            ? iPhoneFace != nil
                || (carPlayFace != nil && isCarPlayMediaSurfaceHosted)
            : face != nil
    }

    private func armOfferWatchdog(for grant: StartGrant) {
        cancelStartupWatchdog()
        let duration = startupWatchdogDuration
        startupWatchdog = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: duration)
            } catch {
                return
            }
            guard let self,
                  self.oneShotStartGrant?.id == grant.id,
                  self.lifecycleGeneration == grant.lifecycleGeneration,
                  self.state == .connecting
            else {
                return
            }
            self.startupWatchdog = nil
            self.oneShotStartGrant = nil
            self.awaitingMediaReady = false
            self.releaseSessionFace(closeLocalMedia: true)
            self.advanceLifecycleGeneration()
            let detail = "Voice could not open the audio connection. Try again."
            if let transport = self.voice {
                _ = self.beginStop(for: transport, terminalError: detail)
            } else {
                self.state = .failed
                self.lastError = detail
            }
        }
    }

    private func armMediaReadyWatchdog(
        for transport: CodexRemoteVoiceTransport,
        lifecycleGeneration: UInt64
    ) {
        cancelStartupWatchdog()
        let duration = startupWatchdogDuration
        startupWatchdog = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: duration)
            } catch {
                return
            }
            guard let self,
                  self.voice === transport,
                  self.lifecycleGeneration == lifecycleGeneration,
                  self.awaitingMediaReady,
                  self.state == .connecting
            else {
                return
            }
            self.startupWatchdog = nil
            self.awaitingMediaReady = false
            self.advanceLifecycleGeneration()
            self.face?.closeLocalOnly()
            _ = self.beginStop(
                for: transport,
                terminalError: "Voice connected to Codex but car audio did not become ready. Try again."
            )
        }
    }

    private func cancelStartupWatchdog() {
        startupWatchdog?.cancel()
        startupWatchdog = nil
    }

    private func releaseSessionFace(closeLocalMedia: Bool) {
        let ownedFace = sessionFace
        if closeLocalMedia { ownedFace?.closeLocalOnly() }
        sessionFace = nil
    }

    /// Consumes no capability and never extends the grant. `bridgeStart`
    /// removes the one-shot grant before entering this suspension, while this
    /// loop fails immediately if Stop/background/reload changes generation.
    private func waitForInteractiveSurface(for grant: StartGrant) async -> Bool {
        let settleDeadline = Date().addingTimeInterval(
            Self.foregroundSettleTimeout
        )
        let deadline = min(grant.expiresAt, settleDeadline)

        while Date() <= deadline {
            guard !Task.isCancelled,
                  grant.lifecycleGeneration == lifecycleGeneration,
                  Date() <= grant.expiresAt
            else {
                return false
            }
            if isStartSurfaceActive(grant.surface) {
                return true
            }
            switch grant.surface {
            case .iPhone:
                if UIApplication.shared.applicationState == .background {
                    return false
                }
            case .carPlay:
                if !isCarPlayConnected {
                    return false
                }
            }
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return false
            }
        }
        return false
    }

    private func isStartSurfaceActive(
        _ surface: DirectVoiceStartSurface
    ) -> Bool {
        switch surface {
        case .iPhone:
            NightBloodVoiceSceneActivity.isIPhoneApplicationActive
        case .carPlay:
            // The action itself came from the system-hosted CarPlay template.
            // `didConnect` is the stable lifecycle boundary; scene activation
            // can briefly lag behind the driver's first template callback.
            isCarPlayConnected
        }
    }

    private func settleCancelledStartWait() {
        guard state == .connecting,
              voice == nil,
              activeStartOperationID == nil,
              oneShotStartGrant == nil
        else {
            return
        }
        state = isConfigured && (webReady || isCarPlayConnected)
            ? .ready : .unavailable
        lastError = nil
        awaitingMediaReady = false
        releaseSessionFace(closeLocalMedia: true)
    }

    func mergeTranscript(
        role: String,
        text: String,
        done: Bool,
        partialSemantics: DirectTranscriptPartialSemantics = .cumulative
    ) {
        defer {
            if done { transcriptCompletionRevision &+= 1 }
        }
        let itemRole: DirectTranscriptItem.Role = role == "user"
            ? .user : .codex
        let finalText = text.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let partialText = String(text.drop(while: { $0.isWhitespace }))
        // The other speaker can start before this role's authoritative final
        // arrives. Reconcile by role so the live row finalises in place even
        // when it is no longer the last item in the conversation.
        if let index = transcript.lastIndex(where: {
            $0.role == itemRole
        }),
           !transcript[index].isFinal
        {
            if done {
                if !finalText.isEmpty {
                    transcript[index].text = finalText
                }
                transcript[index].isFinal = true
            } else if itemRole == .user {
                guard !partialText.isEmpty else { return }
                switch partialSemantics {
                case .cumulative:
                    // The WebRTC controller has already reconciled word
                    // overlaps and sends the entire current hypothesis. A
                    // recognition revision therefore replaces, never appends.
                    transcript[index].text = partialText
                case .incremental:
                    transcript[index].text += text
                }
            } else {
                // Assistant deltas carry their own exact separators. Trimming
                // them turns "Hello" + " there" into "Hellothere" until the
                // authoritative final transcript arrives.
                guard !text.isEmpty else { return }
                transcript[index].text += text
            }
        } else {
            let initialText = done ? finalText : partialText
            guard !initialText.isEmpty else { return }
            transcript.append(
                DirectTranscriptItem(
                    role: itemRole,
                    text: initialText,
                    isFinal: done
                )
            )
        }
        if transcript.count > 100 {
            transcript.removeFirst(transcript.count - 100)
        }
    }

    private static func canonicalTaskID(from reference: String) -> String? {
        guard !reference.isEmpty, reference.utf8.count <= 4_096 else {
            return nil
        }
        let pattern = #"(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(
                  in: reference,
                  range: NSRange(reference.startIndex..., in: reference)
              ),
              let range = Range(match.range, in: reference),
              let uuid = UUID(uuidString: String(reference[range]))
        else {
            return nil
        }
        return uuid.uuidString.lowercased()
    }

    private static func serialisedSize(of value: [String: Any]) -> Int {
        (try? JSONSerialization.data(withJSONObject: value).count) ?? Int.max
    }
}

enum DirectVoiceSessionError: LocalizedError {
    case startNotAuthorised
    case startGrantExpired
    case applicationDidNotBecomeActive
    case sessionAlreadyOwned
    case noOwnedSession

    var errorDescription: String? {
        switch self {
        case .startNotAuthorised:
            "Tap Start and complete Face ID before NightBlood can open Codex Voice."
        case .startGrantExpired:
            "The one-time Voice authorisation expired. Tap Start again."
        case .applicationDidNotBecomeActive:
            "NightBlood did not return to the foreground after Face ID. Tap Start again."
        case .sessionAlreadyOwned:
            "NightBlood already owns a Codex Voice connection."
        case .noOwnedSession:
            "NightBlood has no confirmed Voice session to stop."
        }
    }
}

@MainActor
private final class DirectBackgroundLease: @unchecked Sendable {
    private var identifier = UIBackgroundTaskIdentifier.invalid

    init(
        onExpiration: @escaping @Sendable () async -> Void
    ) {
        identifier = UIApplication.shared.beginBackgroundTask(
            withName: "Close private Codex Voice"
        ) { [weak self] in
            Task {
                await onExpiration()
                await MainActor.run { self?.end() }
            }
        }
    }

    func end() {
        let active = identifier
        guard active != .invalid else { return }
        identifier = .invalid
        UIApplication.shared.endBackgroundTask(active)
    }
}
