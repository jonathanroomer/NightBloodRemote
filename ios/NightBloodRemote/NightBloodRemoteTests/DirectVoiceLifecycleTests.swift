import XCTest
import SwiftUI
@testable import NightBlood

final class DirectVoiceLifecycleTests: XCTestCase {
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
