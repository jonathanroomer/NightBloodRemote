import Foundation
import Observation
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

    private enum StorageKey {
        static let taskID = "nightblood.direct.codex-task-id"
        static let faceSkin = "nightblood.face.skin"
        static let nightBloodVoice = "nightblood.direct.voice.nightblood"
        static let marshmallowVoice = "nightblood.direct.voice.marshmallow"
    }

    let agentName: String
    private(set) var selectedFace: DirectFaceSkin = .nightblood {
        didSet {
            UserDefaults.standard.set(
                selectedFace.rawValue,
                forKey: StorageKey.faceSkin
            )
            face?.setSkin(selectedFace)
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
    var transcript: [DirectTranscriptItem] = []
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

    var hasOwnedVoice: Bool { voice != nil }

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
    private weak var face: (any DirectFaceJavaScriptControlling)?
    private let backgroundAudio: any DirectVoiceBackgroundAudioConfiguring
    private let liveActivityPublisher: any DirectVoiceLiveActivityPublishing
    private let gazeTracker = FrontCameraGazeTracker()
    private var latestGaze = GazeSample.absent
    private var voice: CodexRemoteVoiceTransport?
    private var voiceUpdatesTask: Task<Void, Never>?
    private var oneShotStartGrant: StartGrant?
    private var activeStartOperationID: UUID?
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
    private var conversationWasBackgrounded = false
    private var recentUserFinal: RecentTranscriptFinal?
    private var recentCodexFinal: RecentTranscriptFinal?

    private struct RecentTranscriptFinal {
        let itemID: UUID
        let text: String
        let receivedAt: Date
    }

    private struct StartGrant {
        let id: UUID
        let expiresAt: Date
        let taskID: String
        let character: DirectFaceSkin
        let realtimeVoice: CodexRemoteVoiceName
        let personalityPrompt: CodexRemoteVoicePrompt
        let lifecycleGeneration: UInt64
    }

    init(
        agentName: String = "NightBlood",
        backgroundAudio: any DirectVoiceBackgroundAudioConfiguring =
            DirectVoiceBackgroundAudioController(),
        liveActivityPublisher: any DirectVoiceLiveActivityPublishing =
            NightBloodVoiceLiveActivityManager.shared
    ) {
        self.agentName = agentName
        self.backgroundAudio = backgroundAudio
        self.liveActivityPublisher = liveActivityPublisher
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
            face?.gaze(sample)
        }
        publishLiveActivityState()
    }

    var statusLabel: String {
        state.label(agentName: displayAgentName)
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
        guard voice != nil, outputMuteOperationID == nil else { return false }
        switch state {
        case .listening, .thinking, .speaking: return true
        default: return false
        }
    }

    func install(setup: any DirectCodexVoiceTransportCreating) {
        self.setup = setup
        refreshAvailability()
    }

    func attach(face: any DirectFaceJavaScriptControlling) {
        self.face = face
        webReady = true
        face.setSkin(selectedFace)
        face.gaze(latestGaze)
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
        guard canToggleMicrophoneInput, let face else { return }
        let target = !isMicrophoneMuted
        let operationID = UUID()
        let generation = lifecycleGeneration
        inputMuteOperationID = operationID
        let confirmed = await face.setInputMuted(target)
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
            face.closeLocalOnly()
            stopFromUserGesture()
            return
        }
        isMicrophoneMuted = target
    }

    func startGazeTracking() {
        gazeTracker.start()
    }

    func pauseGazeTracking() {
        gazeTracker.pause()
    }

    /// Called only while DeviceAccessGate holds a Face-ID-unlocked foreground
    /// app session. The WebView gets no token: it receives one invocation and
    /// must supply a valid SDP offer within the short-lived native grant.
    func authoriseAndStartFromUserGesture() {
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
        guard webReady, let face else {
            state = .failed
            lastError = "The bundled NightBlood face is not ready."
            return
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
            lifecycleGeneration: lifecycleGeneration
        )
        oneShotStartGrant = grant
        awaitingMediaReady = true
        state = .connecting
        lastError = nil
        face.start(character: character)
    }

    func stopFromUserGesture() {
        guard state.isActive || voice != nil else { return }
        oneShotStartGrant = nil
        awaitingMediaReady = false
        conversationWasBackgrounded = false
        advanceLifecycleGeneration()
        state = .stopping
        if let voice {
            _ = beginStop(for: voice)
        } else {
            // No native transport exists, so cancellation is already
            // definitive. A late JavaScript stop acknowledgement may safely
            // consume this confirmation without touching a later session.
            lastStopConfirmedAt = Date()
            lastError = nil
            if activeStartOperationID == nil {
                state = isConfigured ? .ready : .unavailable
            }
        }
        // Local microphone/WebRTC closure is best-effort presentation work.
        // The native stop above owns the security boundary even if the page
        // has reloaded or JavaScript cannot answer.
        face?.stop()
    }

    /// The only mutating entry point callable from JavaScript. It consumes the
    /// native one-shot grant before its first suspension.
    func bridgeStart(sdpOffer: String) async throws
        -> CodexRemoteVoiceStartResult
    {
        guard let grant = oneShotStartGrant else {
            throw DirectVoiceSessionError.startNotAuthorised
        }
        oneShotStartGrant = nil
        guard Date() <= grant.expiresAt,
              selectedFace == grant.character,
              grant.lifecycleGeneration == lifecycleGeneration
        else {
            state = .failed
            awaitingMediaReady = false
            throw DirectVoiceSessionError.startGrantExpired
        }
        let becameActive = await waitForForeground(for: grant)
        guard becameActive,
              Date() <= grant.expiresAt,
              grant.lifecycleGeneration == lifecycleGeneration,
              UIApplication.shared.applicationState == .active
        else {
            if Task.isCancelled
                || grant.lifecycleGeneration != lifecycleGeneration
                || UIApplication.shared.applicationState == .background
            {
                settleCancelledStartWait()
                throw CodexRemoteVoiceError.cancelled
            }
            let error: DirectVoiceSessionError = Date() > grant.expiresAt
                ? .startGrantExpired
                : .applicationDidNotBecomeActive
            state = .failed
            lastError = error.localizedDescription
            throw error
        }
        guard voice == nil, let setup else {
            throw DirectVoiceSessionError.sessionAlreadyOwned
        }

        activeStartOperationID = grant.id
        defer { finishStartOperation(grant.id) }

        let transport: CodexRemoteVoiceTransport
        do {
            transport = try await setup.makeVoiceTransport()
        } catch {
            if grant.lifecycleGeneration == lifecycleGeneration {
                state = .failed
                lastError = error.localizedDescription
                awaitingMediaReady = false
            }
            throw error
        }
        guard grant.lifecycleGeneration == lifecycleGeneration,
              UIApplication.shared.applicationState == .active
        else {
            await transport.close()
            awaitingMediaReady = false
            throw CodexRemoteVoiceError.cancelled
        }
        voice = transport
        observe(transport)
        do {
            try await transport.connect()
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
            state = .connecting
            lastError = nil
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
        pauseGazeTracking()
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

    private func stopForLifecycleLoss(closeLocalMedia: Bool) {
        oneShotStartGrant = nil
        awaitingMediaReady = false
        conversationWasBackgrounded = false
        advanceLifecycleGeneration()
        if closeLocalMedia {
            face?.closeLocalOnly()
        }
        guard let voice else {
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
                guard let self else { return }
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
                awaitingMediaReady = false
                state = .listening
                lastError = nil
            } else if eventState == "error" {
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

    func faceProcessWillReload() {
        webReady = false
        face = nil
        pauseGazeTracking()
        stopForLifecycleLoss(closeLocalMedia: false)
    }

    func refreshAvailability() {
        let available = isConfigured && webReady && voice == nil
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
        face?.setAvailable(available)
        state = available ? .ready : .unavailable
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
        voiceUpdatesTask?.cancel()
        voiceUpdatesTask = nil
        voice = nil
        backingWorkActive = false
        awaitingAssistant = false
        inputMuteOperationID = nil
        isMicrophoneMuted = false
        outputMuteOperationID = nil
        isSpeakerOutputMuted = false
        awaitingMediaReady = false
        conversationWasBackgrounded = false
        face?.setWorking(false)
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

    private func finishStartOperation(_ operationID: UUID) {
        guard activeStartOperationID == operationID else { return }
        activeStartOperationID = nil
        if state == .stopping,
           voice == nil,
           hasRecentConfirmedStop
        {
            state = isConfigured ? .ready : .unavailable
            lastError = nil
        }
    }

    private func advanceLifecycleGeneration() {
        inputMuteOperationID = nil
        outputMuteOperationID = nil
        lifecycleGeneration = lifecycleGeneration == UInt64.max
            ? 0 : lifecycleGeneration + 1
    }

    /// Consumes no capability and never extends the grant. `bridgeStart`
    /// removes the one-shot grant before entering this suspension, while this
    /// loop fails immediately if Stop/background/reload changes generation.
    private func waitForForeground(for grant: StartGrant) async -> Bool {
        let settleDeadline = Date().addingTimeInterval(
            Self.foregroundSettleTimeout
        )
        let deadline = min(grant.expiresAt, settleDeadline)

        while Date() <= deadline {
            guard !Task.isCancelled,
                  grant.lifecycleGeneration == lifecycleGeneration,
                  Date() <= grant.expiresAt,
                  UIApplication.shared.applicationState != .background
            else {
                return false
            }
            if UIApplication.shared.applicationState == .active {
                return true
            }
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return false
            }
        }
        return false
    }

    private func settleCancelledStartWait() {
        guard state == .connecting,
              voice == nil,
              activeStartOperationID == nil,
              oneShotStartGrant == nil
        else {
            return
        }
        state = isConfigured && webReady ? .ready : .unavailable
        lastError = nil
        awaitingMediaReady = false
    }

    private func mergeTranscript(role: String, text: String, done: Bool) {
        let itemRole: DirectTranscriptItem.Role = role == "user"
            ? .user : .codex
        let finalText = text.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        if done,
           !finalText.isEmpty,
           let recent = recentFinal(for: itemRole),
           Date().timeIntervalSince(recent.receivedAt) <= 3,
           Self.isSameTranscriptRevision(finalText, recent.text),
           let recentIndex = transcript.firstIndex(where: {
               $0.id == recent.itemID
           })
        {
            if finalText.count >= transcript[recentIndex].text.count {
                transcript[recentIndex].text = finalText
            }
            transcript[recentIndex].isFinal = true
            rememberFinal(
                role: itemRole,
                item: transcript[recentIndex],
                receivedAt: Date()
            )
            return
        }
        if let index = transcript.indices.last,
           transcript[index].role == itemRole,
           !transcript[index].isFinal
        {
            if done {
                if !finalText.isEmpty {
                    transcript[index].text = finalText
                }
                transcript[index].isFinal = true
            } else if itemRole == .user {
                let cumulative = String(text.drop(while: { $0.isWhitespace }))
                guard !cumulative.isEmpty else { return }
                if cumulative.hasPrefix(transcript[index].text) {
                    transcript[index].text = cumulative
                } else {
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
            let initialText = done
                ? text.trimmingCharacters(in: .whitespacesAndNewlines)
                : String(text.drop(while: { $0.isWhitespace }))
            guard !initialText.isEmpty else { return }
            transcript.append(
                DirectTranscriptItem(
                    role: itemRole,
                    text: initialText,
                    isFinal: done
                )
            )
        }
        if done, let item = transcript.last, item.role == itemRole {
            rememberFinal(role: itemRole, item: item, receivedAt: Date())
        }
        if transcript.count > 100 {
            transcript.removeFirst(transcript.count - 100)
        }
    }

    private func recentFinal(
        for role: DirectTranscriptItem.Role
    ) -> RecentTranscriptFinal? {
        role == .user ? recentUserFinal : recentCodexFinal
    }

    private func rememberFinal(
        role: DirectTranscriptItem.Role,
        item: DirectTranscriptItem,
        receivedAt: Date
    ) {
        let value = RecentTranscriptFinal(
            itemID: item.id,
            text: item.text,
            receivedAt: receivedAt
        )
        if role == .user {
            recentUserFinal = value
        } else {
            recentCodexFinal = value
        }
    }

    private static func isSameTranscriptRevision(
        _ lhs: String,
        _ rhs: String
    ) -> Bool {
        let left = lhs.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        let right = rhs.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        return left == right || left.hasPrefix(right) || right.hasPrefix(left)
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
