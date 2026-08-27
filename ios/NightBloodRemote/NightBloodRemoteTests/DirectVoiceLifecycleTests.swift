import XCTest
@testable import NightBlood

final class DirectVoiceLifecycleTests: XCTestCase {
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
