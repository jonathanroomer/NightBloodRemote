import XCTest
import SwiftUI
@testable import NightBlood

final class DirectVoiceLifecycleTests: XCTestCase {
    @MainActor
    func testUnavailableMacCanBeReplacedWithoutSigningInOrEnrollingAgain() async throws {
        let fixture = PairingRecoveryFixture()
        let setup = fixture.makeSetup()
        setup.refreshPersistedState()
        try await waitForSetup(setup, phase: .selectedEnvironmentUnavailable)
        XCTAssertTrue(setup.canPairAnotherMac)
        XCTAssertEqual(setup.selectedEnvironmentID, "old-mac")

        XCTAssertTrue(setup.beginPairingAnotherMac())
        XCTAssertFalse(setup.beginPairingAnotherMac(), "A rapid second tap cannot restart setup")
        try await waitForSetup(setup, phase: .manualPairingCodeRequired)
        XCTAssertNil(setup.selectedEnvironmentID)
        XCTAssertFalse(setup.isVoiceReady)
        var record = try await fixture.store.load(accountUserID: "test-user", clientID: "test-client")
        XCTAssertEqual(record?.state, .ready)

        // The explicit change survives a foreground reconciliation. It does
        // not silently restore the old Mac while entering a new pairing code.
        setup.applicationDidEnterBackground()
        setup.applicationDidBecomeActive()
        setup.refreshPersistedState()
        try await waitForSetup(setup, phase: .manualPairingCodeRequired)

        setup.submitPairingCode("ABCD-EFGH")
        try await waitForSetup(setup, phase: .pairingProvisional)
        setup.loadEnvironments()
        try await waitForSetup(setup, phase: .environmentSelectionRequired)
        XCTAssertNil(setup.selectedEnvironmentID, "Even one online Mac requires selection")
        XCTAssertFalse(setup.isVoiceReady)
        setup.selectEnvironment(id: "new-mac")
        setup.confirmSelectedEnvironment()
        try await waitForSetup(setup, phase: .ready)
        XCTAssertEqual(setup.selectedEnvironmentID, "new-mac")
        record = try await fixture.store.load(accountUserID: "test-user", clientID: "test-client")
        XCTAssertEqual(record?.confirmedEnvironmentID, "new-mac")
        let posts = await fixture.transport.pairingPosts
        let signIns = await fixture.oauth.signIns
        let enrolments = await fixture.enrolment.enrolments
        XCTAssertEqual(posts, 1)
        XCTAssertEqual(signIns, 0)
        XCTAssertEqual(enrolments, 0)
    }

    @MainActor
    func testPairAnotherMacCannotResetUncertainPairing() async throws {
        for state in [CodexRemotePairingLifecycleState.inFlight, .outcomeUnknown,
                      .responseReceivedUnverified] {
            let fixture = PairingRecoveryFixture(state: state)
            let setup = fixture.makeSetup()
            setup.refreshPersistedState()
            try await waitForSetup(setup, phase: state == .responseReceivedUnverified
                ? .pairingProvisional : .pairingOutcomeUnknown)
            XCTAssertFalse(setup.canPairAnotherMac)
            XCTAssertFalse(setup.beginPairingAnotherMac())
            // Refresh can reveal a paired list but must not erase unknown
            // state merely because the user then asks to pair another host.
            setup.loadEnvironments()
            try await waitForSetup(setup, phase: .environmentSelectionRequired)
            XCTAssertFalse(setup.canPairAnotherMac)
            XCTAssertFalse(setup.beginPairingAnotherMac())
            let record = try await fixture.store.load(accountUserID: "test-user", clientID: "test-client")
            let posts = await fixture.transport.pairingPosts
            XCTAssertEqual(record?.state, state)
            XCTAssertEqual(posts, 0)
        }
    }

    @MainActor
    func testEmptyPairedListCanReturnToCodeEntry() async throws {
        let fixture = PairingRecoveryFixture(state: .ready)
        let setup = fixture.makeSetup()
        setup.refreshPersistedState()
        try await waitForSetup(setup, phase: .manualPairingCodeRequired)
        setup.loadEnvironments()
        try await waitForSetup(setup, phase: .environmentSelectionRequired)
        XCTAssertTrue(setup.beginPairingAnotherMac())
        try await waitForSetup(setup, phase: .manualPairingCodeRequired)
        let posts = await fixture.transport.pairingPosts
        XCTAssertEqual(posts, 0)
    }

    @MainActor
    private func waitForSetup(_ setup: DirectCodexRemoteSetupModel,
                              phase: DirectCodexRemoteSetupModel.Phase) async throws {
        for _ in 0..<200 {
            if setup.phase == phase && !setup.isBusy { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(setup.phase, phase)
    }

    @MainActor
    func testOpeningSettingsDoesNotRestartSetupReconciliation() async throws {
        let oauth = SettingsOAuthSpy()
        let setup = DirectCodexRemoteSetupModel(
            oauth: oauth,
            observeBackground: false,
            initiallyActive: true
        )
        let voice = DirectVoiceSessionModel(
            liveActivityPublisher: RecordingLiveActivityPublisher()
        )
        // Launch owns reconciliation. Merely showing Settings must not read
        // credentials again or push setup through checking/loading phases.
        setup.refreshPersistedState()
        for _ in 0..<100 {
            if setup.phase == .signedOut { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(setup.phase, .signedOut)
        let initialReads = await oauth.storedTokenReads
        XCTAssertEqual(initialReads, 1)

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; window.rootViewController = nil }
        for presentation in 0..<2 {
            let appeared = expectation(description: "Settings appeared \(presentation)")
            window.rootViewController = UIHostingController(
                rootView: DirectSettingsView(setup: setup, voice: voice)
                    .onAppear { appeared.fulfill() }
            )
            window.isHidden = false
            await fulfillment(of: [appeared], timeout: 3)
            // Allow the actual sheet's SwiftUI .task to run after appearance.
            try await Task.sleep(for: .milliseconds(100))
            let reads = await oauth.storedTokenReads
            XCTAssertEqual(reads, 1, "Opening Settings must not restart setup")
            XCTAssertEqual(setup.phase, .signedOut)
            window.isHidden = true
            window.rootViewController = nil
        }

        // An explicit recovery refresh remains available.
        setup.refreshPersistedState()
        for _ in 0..<100 {
            if setup.phase == .signedOut { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let refreshedReads = await oauth.storedTokenReads
        XCTAssertEqual(refreshedReads, 2)
    }

    func testTranscriptDiagnosticsNeverEchoUnknownHelperReasons() {
        let reason = CodexRemoteDesktopTranscriptFailure.helperReason("private-path-and-account")
        XCTAssertEqual(reason, .desktopUnavailable)
        let message = CodexRemoteVoiceError.desktopTranscriptSetupFailed(reason).localizedDescription
        XCTAssertFalse(message.contains("private-path-and-account"))
        XCTAssertEqual(CodexRemoteDesktopTranscriptFailure.helperReason("desktop_handshake_failed"), .handshakeFailed)
        XCTAssertEqual(CodexRemoteDesktopTranscriptFailure.helperReason("helper_command_failed"), .desktopUnavailable)
    }

    @MainActor
    func testVoiceIsUnavailableBeforeDesktopAcknowledgement() {
        let model = DirectVoiceSessionModel(
            liveActivityPublisher: RecordingLiveActivityPublisher()
        )
        model.state = .ready
        // A presentation state alone cannot grant microphone/voice access.
        XCTAssertFalse(model.canStartVoice)
        XCTAssertFalse(model.hasOwnedVoice)
    }

    @MainActor
    func testKnownFailureOffersConnectionRetryButUnknownDoesNot() {
        let model = DirectVoiceSessionModel(
            liveActivityPublisher: RecordingLiveActivityPublisher()
        )
        model.state = .failed
        XCTAssertTrue(model.canRetryVoiceConnection)
        model.authoriseAndStartFromUserGesture()
        XCTAssertFalse(model.hasOwnedVoice)
        XCTAssertFalse(model.canStartVoice)
        model.state = .outcomeUnknown
        XCTAssertFalse(model.canRetryVoiceConnection)
        model.authoriseAndStartFromUserGesture()
        XCTAssertEqual(model.state, .outcomeUnknown)
    }

    @MainActor

    func testOnlyEstablishedInteractiveStatesContinueInBackground() {
        XCTAssertTrue(DirectVoiceSessionState.listening.mayContinueInBackground)
        XCTAssertTrue(DirectVoiceSessionState.thinking.mayContinueInBackground)
        XCTAssertTrue(DirectVoiceSessionState.speaking.mayContinueInBackground)

        XCTAssertFalse(DirectVoiceSessionState.unavailable.mayContinueInBackground)
        XCTAssertFalse(DirectVoiceSessionState.ready.mayContinueInBackground)
        XCTAssertFalse(DirectVoiceSessionState.connecting.mayContinueInBackground)
        XCTAssertFalse(DirectVoiceSessionState.stopping.mayContinueInBackground)
        XCTAssertFalse(DirectVoiceSessionState.outcomeUnknown.mayContinueInBackground)
        XCTAssertFalse(DirectVoiceSessionState.failed.mayContinueInBackground)
    }

    func testAppDeclaresAudioBackgroundMode() {
        let modes = Bundle.main.object(
            forInfoDictionaryKey: "UIBackgroundModes"
        ) as? [String]
        XCTAssertEqual(modes, ["audio"])
    }

    func testAppDeclaresLiveActivitySupport() {
        let supported = Bundle.main.object(
            forInfoDictionaryKey: "NSSupportsLiveActivities"
        ) as? Bool
        XCTAssertEqual(supported, true)
    }

    @MainActor
    func testInteractiveVoiceStatePublishesLiveActivity() {
        let publisher = RecordingLiveActivityPublisher()
        let model = DirectVoiceSessionModel(
            liveActivityPublisher: publisher
        )

        model.state = .listening

        XCTAssertEqual(publisher.snapshots.last?.status, "Listening")
        XCTAssertEqual(publisher.snapshots.last?.sessionState, "listening")
        XCTAssertEqual(publisher.snapshots.last?.shouldBeVisible, true)

        model.state = .ready

        XCTAssertEqual(publisher.snapshots.last?.shouldBeVisible, false)
    }

    @MainActor
    func testLiveActivityActionBusPreservesThreeControlSemantics() async {
        var received: [NightBloodLiveActivityAction] = []
        NightBloodLiveActivityActionBus.install { action in
            received.append(action)
        }

        await NightBloodLiveActivityActionBus.perform(.toggleMicrophone)
        await NightBloodLiveActivityActionBus.perform(.stopConversation)
        await NightBloodLiveActivityActionBus.perform(.toggleSpeakerOutput)

        XCTAssertEqual(
            received,
            [.toggleMicrophone, .stopConversation, .toggleSpeakerOutput]
        )
    }

    @MainActor
    func testAvailabilityRefreshDoesNotDisconnectAnActiveFace() {
        let model = DirectVoiceSessionModel(
            liveActivityPublisher: RecordingLiveActivityPublisher()
        )
        let face = AvailabilityRecordingFace()
        model.attach(face: face)
        XCTAssertEqual(face.availability, [false])

        model.state = .listening
        model.refreshAvailability()

        XCTAssertEqual(face.availability, [false])
        XCTAssertEqual(model.state, .listening)
    }

    @MainActor
    func testCumulativeUserTranscriptRevisionReplacesInsteadOfAppending() {
        let model = DirectVoiceSessionModel(
            liveActivityPublisher: RecordingLiveActivityPublisher()
        )

        model.mergeTranscript(role: "user", text: "Can you hear", done: false)
        model.mergeTranscript(
            role: "user",
            text: "Can you clearly hear me",
            done: false
        )
        model.mergeTranscript(
            role: "user",
            text: "Can you clearly hear me?",
            done: true
        )

        XCTAssertEqual(model.transcript.count, 1)
        XCTAssertEqual(model.transcript[0].text, "Can you clearly hear me?")
        XCTAssertTrue(model.transcript[0].isFinal)
    }

    @MainActor
    func testNativeIncrementalUserTranscriptStaysInOneMessage() {
        let model = DirectVoiceSessionModel(
            liveActivityPublisher: RecordingLiveActivityPublisher()
        )

        model.mergeTranscript(
            role: "user",
            text: "Carry",
            done: false,
            partialSemantics: .incremental
        )
        model.mergeTranscript(
            role: "user",
            text: " on",
            done: false,
            partialSemantics: .incremental
        )
        model.mergeTranscript(role: "user", text: "Carry on", done: true)

        XCTAssertEqual(model.transcript.count, 1)
        XCTAssertEqual(model.transcript[0].text, "Carry on")
        XCTAssertTrue(model.transcript[0].isFinal)
    }

    @MainActor
    func testUserFinalReconcilesAfterAssistantStartsResponding() {
        let model = DirectVoiceSessionModel(
            liveActivityPublisher: RecordingLiveActivityPublisher()
        )

        model.mergeTranscript(
            role: "user",
            text: "Can you hear",
            done: false
        )
        let liveTranscriptID = model.transcript[0].id
        model.mergeTranscript(
            role: "assistant",
            text: "Yes",
            done: false
        )
        model.mergeTranscript(
            role: "user",
            text: "Can you hear me?",
            done: true
        )

        XCTAssertEqual(model.transcript.count, 2)
        XCTAssertEqual(model.transcript[0].id, liveTranscriptID)
        XCTAssertEqual(model.transcript[0].text, "Can you hear me?")
        XCTAssertTrue(model.transcript[0].isFinal)
        XCTAssertEqual(model.transcript[1].role, .codex)
        XCTAssertFalse(model.transcript[1].isFinal)
    }

    @MainActor
    func testAssistantFinalReconcilesAfterUserStartsSpeaking() {
        let model = DirectVoiceSessionModel(
            liveActivityPublisher: RecordingLiveActivityPublisher()
        )

        model.mergeTranscript(
            role: "assistant",
            text: "The answer is",
            done: false
        )
        let liveTranscriptID = model.transcript[0].id
        model.mergeTranscript(role: "user", text: "Wait", done: false)
        model.mergeTranscript(
            role: "assistant",
            text: "The answer is forty-two.",
            done: true
        )

        XCTAssertEqual(model.transcript.count, 2)
        XCTAssertEqual(model.transcript[0].id, liveTranscriptID)
        XCTAssertEqual(
            model.transcript[0].text,
            "The answer is forty-two."
        )
        XCTAssertTrue(model.transcript[0].isFinal)
        XCTAssertEqual(model.transcript[1].role, .user)
        XCTAssertFalse(model.transcript[1].isFinal)
    }

    @MainActor
    func testRepeatedCompletedPhraseRemainsASeparateUserTurn() {
        let model = DirectVoiceSessionModel(
            liveActivityPublisher: RecordingLiveActivityPublisher()
        )
        for _ in 0..<3 {
            model.mergeTranscript(role: "user", text: "Carry on", done: true)
        }
        XCTAssertEqual(model.transcript.count, 3)
        XCTAssertEqual(Set(model.transcript.map(\.id)).count, 3)
        XCTAssertTrue(model.transcript.allSatisfy {
            $0.text == "Carry on" && $0.isFinal
        })
    }

    @MainActor
    func testNewUtteranceSharingPrefixIsNotCollapsed() {
        let model = DirectVoiceSessionModel(
            liveActivityPublisher: RecordingLiveActivityPublisher()
        )
        model.mergeTranscript(role: "user", text: "Carry on", done: true)
        model.mergeTranscript(role: "user", text: "Carry on please", done: true)
        XCTAssertEqual(model.transcript.map(\.text), ["Carry on", "Carry on please"])
    }

}

@MainActor
private final class RecordingLiveActivityPublisher:
    DirectVoiceLiveActivityPublishing
{
    private(set) var snapshots: [DirectVoiceLiveActivitySnapshot] = []

    func publish(_ snapshot: DirectVoiceLiveActivitySnapshot) {
        snapshots.append(snapshot)
    }
}

@MainActor
private final class AvailabilityRecordingFace: DirectFaceJavaScriptControlling {
    private(set) var availability: [Bool] = []

    func setAvailable(_ available: Bool) {
        availability.append(available)
    }

    func setWorking(_ active: Bool) {}
    func setInputMuted(_ muted: Bool) async -> Bool { muted }
    func setOutputMuted(_ muted: Bool) async -> Bool { muted }
    func resumeAfterBackground(state: DirectVoiceSessionState) async -> Bool { true }
    func setSkin(_ skin: DirectFaceSkin) {}
    func start(character: DirectFaceSkin) {}
    func stop() {}
    func closeLocalOnly() {}
    func gaze(_ sample: GazeSample) {}
}

private actor SettingsOAuthSpy: DirectCodexPlanOAuthServing {
    private(set) var storedTokenReads = 0

    func storedTokens() async throws -> CodexPlanTokens? {
        storedTokenReads += 1
        return nil
    }

    func signIn(
        timeout: Duration,
        presentSafari: CodexOAuthSafariPresentation
    ) async throws -> CodexPlanTokens {
        throw CancellationError()
    }

    func refreshStoredTokens() async throws -> CodexPlanTokens {
        throw CancellationError()
    }

    func cancel() async {}
}

private struct PairingRecoveryFixture {
    let oauth = RecoveryOAuth()
    let enrolment = RecoveryEnrolment()
    let transport = RecoveryTransport()
    let store: RecoveryPairingStore

    init(state: CodexRemotePairingLifecycleState = .confirmed) {
        store = RecoveryPairingStore(state: state)
    }

    @MainActor
    func makeSetup() -> DirectCodexRemoteSetupModel {
        DirectCodexRemoteSetupModel(oauth: oauth, enrolment: enrolment,
            transport: transport, lifecycleStore: store,
            observeBackground: false, initiallyActive: true)
    }
}

private actor RecoveryOAuth: DirectCodexPlanOAuthServing {
    private(set) var signIns = 0
    func storedTokens() async throws -> CodexPlanTokens? {
        let payload = Data(#"{"exp":4000000000,"https://api.openai.com/auth":{"chatgpt_account_id":"test-account","chatgpt_account_user_id":"test-user"}}"#.utf8)
            .base64EncodedString().replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        return .init(accessToken: "e30.\(payload).test", refreshToken: "test", idToken: "test")
    }
    func signIn(timeout: Duration, presentSafari: CodexOAuthSafariPresentation) async throws -> CodexPlanTokens {
        signIns += 1
        throw CancellationError()
    }
    func refreshStoredTokens() async throws -> CodexPlanTokens { throw CancellationError() }
    func cancel() async {}
}

private actor RecoveryEnrolment: DirectCodexRemoteEnrolling {
    private(set) var enrolments = 0
    func storedMetadata() async throws -> CodexRemoteEnrolmentMetadata? {
        .init(accountUserID: "test-user", clientID: "test-client",
              identity: .init(algorithm: "ES256", keyID: "test-key",
                              protectionClass: "test", publicKeySPKIDERBase64: "test"),
              state: .enrolled)
    }
    func enrol(ordinaryAccessToken: String, stepUpTimeout: Duration,
               presentSafari: CodexOAuthSafariPresentation) async throws -> CodexRemoteEnrolmentMetadata {
        enrolments += 1
        throw CancellationError()
    }
    func cancel() async {}
}

private actor RecoveryTransport: CodexRemoteHTTPTransport {
    private(set) var pairingPosts = 0
    func send(_ request: CodexRemoteHTTPRequest) async throws -> CodexRemoteHTTPResponse {
        if request.method == .post {
            pairingPosts += 1
            return .init(statusCode: 200, body: Data(#"{"client_id":"test-client","env_id":"new-mac"}"#.utf8))
        }
        let json = pairingPosts == 0
            ? #"{"items":[{"env_id":"old-mac","online":false}]}"#
            : #"{"items":[{"env_id":"old-mac","online":false},{"env_id":"new-mac","online":true}]}"#
        return .init(statusCode: 200, body: Data(json.utf8))
    }
}

private actor RecoveryPairingStore: CodexRemotePairingLifecycleStoring {
    private var record: CodexRemotePairingLifecycleRecord
    init(state: CodexRemotePairingLifecycleState) {
        record = .init(accountUserID: "test-user", clientID: "test-client",
                       state: state, confirmedEnvironmentID: state == .confirmed ? "old-mac" : nil)
    }
    func prepare(accountUserID: String, clientID: String) async throws -> CodexRemotePairingLifecycleRecord { record }
    func load(accountUserID: String, clientID: String) async throws -> CodexRemotePairingLifecycleRecord? { record }
    func transition(accountUserID: String, clientID: String,
                    from expectedStates: Set<CodexRemotePairingLifecycleState>,
                    to state: CodexRemotePairingLifecycleState) async throws -> CodexRemotePairingLifecycleRecord {
        guard expectedStates.contains(record.state) else {
            throw CodexRemoteControllerError.pairingAttemptAlreadyConsumed
        }
        record = .init(accountUserID: accountUserID, clientID: clientID,
                       state: state, confirmedEnvironmentID: nil)
        return record
    }
    func confirmAfterEnvironmentVerification(_ binding: CodexRemoteVerifiedEnvironmentBinding) async throws -> CodexRemotePairingLifecycleRecord {
        record = .init(accountUserID: binding.accountUserID, clientID: binding.clientID,
                       state: .confirmed, confirmedEnvironmentID: binding.environmentID)
        return record
    }
}
