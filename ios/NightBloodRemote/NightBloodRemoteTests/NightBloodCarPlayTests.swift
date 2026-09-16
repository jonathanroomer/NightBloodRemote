@preconcurrency import AVFAudio
import XCTest
import CarPlay
@testable import NightBlood

final class NightBloodCarPlayTests: XCTestCase {
    @MainActor
    func testCarPlayLifecycleTraceContainsNoSetupSecrets() {
        NightBloodCarPlayDiagnostics.record(
            "test.lifecycle",
            detail: "Ready for NightBlood Voice"
        )
        let trace = NightBloodCarPlayDiagnostics.renderedTrace()

        XCTAssertTrue(trace.contains("test.lifecycle"))
        XCTAssertTrue(trace.contains("Ready for NightBlood Voice"))
        XCTAssertFalse(trace.localizedCaseInsensitiveContains("access_token"))
        XCTAssertFalse(trace.localizedCaseInsensitiveContains("pairing code"))
    }

    func testVehicleAudioRouteRecognisesCarAndHandsFreeOutputs() {
        XCTAssertTrue(
            NightBloodCarAudioRoute.usesVehicleAudio([.carAudio])
        )
        XCTAssertTrue(
            NightBloodCarAudioRoute.usesVehicleAudio([.bluetoothHFP])
        )
        XCTAssertTrue(
            NightBloodCarAudioRoute.usesVehicleAudio([.bluetoothA2DP])
        )
        XCTAssertFalse(
            NightBloodCarAudioRoute.usesVehicleAudio([.builtInSpeaker])
        )
    }

    func testAppRegistersACarPlayTemplateScene() throws {
        let manifest = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "UIApplicationSceneManifest")
                as? [String: Any]
        )
        let configurations = try XCTUnwrap(
            manifest["UISceneConfigurations"] as? [String: Any]
        )
        let scenes = try XCTUnwrap(
            configurations["CPTemplateApplicationSceneSessionRoleApplication"]
                as? [[String: Any]]
        )

        XCTAssertEqual(scenes.count, 1)
        XCTAssertEqual(
            scenes.first?["UISceneClassName"] as? String,
            "CPTemplateApplicationScene"
        )
        XCTAssertTrue(
            (scenes.first?["UISceneDelegateClassName"] as? String)?
                .hasSuffix("NightBloodCarPlaySceneDelegate") == true
        )
    }

    @MainActor
    @available(iOS 26.4, *)
    func testCodexIntroYieldsImmediatelyToTalkAndKeepsRealStatus() {
        for state in NightBloodCarPlayVisualState.allCases {
            XCTAssertEqual(NightBloodCarPlayPresenter.stateIdentifier(
                visual: state, hasRequestedTalk: false, hasConversation: false
            ), "codex-intro-" + state.rawValue)
            XCTAssertEqual(NightBloodCarPlayPresenter.stateIdentifier(
                visual: state, hasRequestedTalk: true, hasConversation: false
            ), state.rawValue)
            XCTAssertEqual(NightBloodCarPlayPresenter.stateIdentifier(
                visual: state, hasRequestedTalk: false, hasConversation: true
            ), state.rawValue)
        }
        let logo = NightBloodCarPlayArtwork.codexIntro(traits: UITraitCollection(displayScale: 3))
        XCTAssertEqual(logo.size, CGSize(width: 150, height: 150))
        XCTAssertEqual(logo.cgImage?.width, 450)
    }

    @MainActor
    @available(iOS 26.4, *)
    func testEveryVisualFitsInsideTheActualCarPlayTemplateLimit() {
        for current in NightBloodCarPlayVisualState.allCases {
            for intro in [true, false] {
                let states = NightBloodCarPlayPresenter.templateStates(current: current).map { visual in
                    CPVoiceControlState(
                        identifier: (intro ? "codex-intro-" : "") + visual.rawValue,
                        titleVariants: [visual.label], image: nil, repeats: false
                    )
                }
                XCTAssertLessThanOrEqual(states.count, 5)
                let template = CPVoiceControlTemplate(voiceControlStates: states)
                let identifier = (intro ? "codex-intro-" : "") + current.rawValue
                XCTAssertEqual(template.voiceControlStates.first?.identifier, identifier)
                XCTAssertTrue(template.voiceControlStates.contains { $0.identifier == identifier })
                XCTAssertEqual(template.voiceControlStates.count, states.count)
            }
        }
    }

    func testCarPlayVisualStatesCoverTheVoiceLifecycle() {
        XCTAssertEqual(
            NightBloodCarPlayVisualState.allCases,
            [.ready, .welcoming, .unavailable, .listening, .working, .speaking,
             .connecting, .stopping, .failed, .needsReview, .setupRequired]
        )
        XCTAssertEqual(NightBloodCarPlayVisualState(.ready), .ready)
        XCTAssertEqual(NightBloodCarPlayVisualState(.connecting), .connecting)
        XCTAssertEqual(NightBloodCarPlayVisualState(.thinking), .working)
        XCTAssertEqual(NightBloodCarPlayVisualState(.listening), .listening)
        XCTAssertEqual(NightBloodCarPlayVisualState(.speaking), .speaking)
        XCTAssertEqual(NightBloodCarPlayVisualState(.failed), .failed)
    }

    func testCarPlayStatusLabelsStayGlanceableAndTruthful() {
        let expected: [(NightBloodCarPlayVisualState, String)] = [
            (.ready, "Ready"),
            (.welcoming, "Ready"),
            (.unavailable, "Disconnected"),
            (.listening, "Listening"),
            (.working, "Working"),
            (.speaking, "Talking"),
            (.connecting, "Connecting"),
            (.stopping, "Stopping"),
            (.failed, "Connection error"),
            (.needsReview, "Check iPhone"),
            (.setupRequired, "Setup required"),
        ]

        XCTAssertEqual(NightBloodCarPlayVisualState.allCases.count, 11)
        for (state, label) in expected {
            XCTAssertEqual(state.label, label)
            XCTAssertLessThanOrEqual(
                state.label.split(separator: " ").count,
                2
            )
        }
    }

    func testStartupSetupFailureAndUnknownAreDistinct() {
        XCTAssertEqual(NightBloodCarPlayVisualState(.unavailable, setupPhase: .checking), .connecting)
        XCTAssertEqual(NightBloodCarPlayVisualState(.unavailable, preparing: true), .connecting)
        XCTAssertEqual(NightBloodCarPlayVisualState(.unavailable), .unavailable)
        XCTAssertEqual(NightBloodCarPlayVisualState(.unavailable, setupPhase: .failed), .failed)
        XCTAssertEqual(NightBloodCarPlayVisualState(.unavailable, setupPhase: .signedOut), .setupRequired)
        XCTAssertEqual(NightBloodCarPlayVisualState(.outcomeUnknown), .needsReview)
        XCTAssertEqual(NightBloodCarPlayVisualState(.unavailable, setupPhase: .pairingOutcomeUnknown), .needsReview)
        XCTAssertEqual(NightBloodCarPlayVisualState(.listening, setupPhase: .checking), .listening)
    }

    @MainActor
    func testReconnectCannotClearUnknownOrInterruptActiveVoice() {
        let model = DirectVoiceSessionModel(
            liveActivityPublisher: CarPlayNullLiveActivityPublisher(),
            interactiveSurfaceIsActive: { true }
        )
        model.carPlayDidConnect()
        for state: DirectVoiceSessionState in [.outcomeUnknown, .connecting, .listening, .stopping] {
            model.state = state
            model.lastError = "Retain this outcome"
            XCTAssertFalse(model.resetCarPlayConnectionPreparation())
            XCTAssertEqual(model.state, state)
            XCTAssertEqual(model.lastError, "Retain this outcome")
        }
    }

    @MainActor
    func testFullFaceRetainsMouthSmokeAndTransparentEdgesAtCarDisplayScale() throws {
        XCTAssertEqual(NightBloodCarPlayArtwork.character, .nightblood)
        let atlas = try XCTUnwrap(NightBloodCarPlayArtwork.sourceAtlas(for: .speaking))
        XCTAssertEqual(atlas.width, 2700)
        XCTAssertEqual(atlas.height, 2250)
        for scale: CGFloat in [1, 2, 3] {
            let first = NightBloodCarPlayArtwork.faceFrame(
                atlas: atlas, index: 0, traits: UITraitCollection(displayScale: scale)
            )
            XCTAssertEqual(first.size, CGSize(width: 150, height: 150))
            XCTAssertEqual(first.cgImage?.width, Int(150 * scale))
            let pixels = try rgbaPixels(of: first)
            // Eyes and speaking mouth both survive; the old eye crop lost the latter.
            XCTAssertGreaterThan(pixels.brightPixelCount(in: 0.3..<0.55), 30)
            XCTAssertGreaterThan(pixels.brightPixelCount(in: 0.7..<0.85), 5)
            XCTAssertEqual(pixels.alpha(at: CGPoint(x: 0, y: 0)), 0)
            XCTAssertEqual(pixels.alpha(at: CGPoint(x: 0.99, y: 0.99)), 0)
            let smoke = pixels.alpha(at: CGPoint(x: 0.5, y: 0.32))
            XCTAssertGreaterThan(smoke, 0)
            XCTAssertLessThan(smoke, 150)
        }
    }

    @MainActor
    func testNativeLoopsKeepEveryStateAnimatedWithinApplesDurationLimit() throws {
        let traits = UITraitCollection(displayScale: 2)
        for state in NightBloodCarPlayVisualState.allCases where state != .welcoming {
            let animated = NightBloodCarPlayArtwork.animatedFace(visualState: state, traits: traits)
            let frames = try XCTUnwrap(animated.images)
            XCTAssertEqual(frames.count, 58)
            XCTAssertEqual(animated.duration, 58.0 / 24.0, accuracy: 0.001)
            XCTAssertGreaterThanOrEqual(animated.duration, 0.3)
            XCTAssertLessThanOrEqual(animated.duration, 5)
            XCTAssertNotEqual(frames[0].pngData(), frames[15].pngData())
            // The last frame is source frame 1; wrapping to frame 0 advances
            // only one source frame, instead of jumping across the whole clip.
            XCTAssertEqual(frames.last?.pngData(), frames[1].pngData())
        }
    }

    func testReadyFlashOnlyOverridesListening() {
        XCTAssertEqual(
            NightBloodCarPlayVisualState(.listening, readyFlashActive: true), .welcoming
        )
        for state: DirectVoiceSessionState in [.connecting, .thinking, .speaking, .failed, .ready] {
            XCTAssertEqual(
                NightBloodCarPlayVisualState(state, readyFlashActive: true),
                NightBloodCarPlayVisualState(state)
            )
        }
    }

    @MainActor
    func testReadyFlashUsesGreenArrivalAndFadesToOrdinaryEyes() throws {
        let atlas = try XCTUnwrap(NightBloodCarPlayArtwork.sourceAtlas(for: .welcoming))
        let traits = UITraitCollection(displayScale: 2)
        func colour(_ index: Int) throws -> [UInt8] {
            try rgbaPixels(of: NightBloodCarPlayArtwork.faceFrame(
                atlas: atlas, index: index, traits: traits
            )).brightestRGB()
        }
        let green = try colour(3)
        XCTAssertGreaterThan(Int(green[1]), Int(green[0]) + 80)
        let final = try colour(29)
        XCTAssertGreaterThan(Int(final[0]), 100)
        let animation = NightBloodCarPlayArtwork.animatedFace(visualState: .welcoming, traits: traits)
        XCTAssertEqual(animation.images?.count, 30)
        XCTAssertEqual(animation.duration, 2.7, accuracy: 0.001)
    }

    @MainActor
    func testCarPlayWelcomeUsesProceduralAudioWithoutRecordings() throws {
        for character in DirectFaceSkin.allCases {
            for sound: DirectReadySound in [.character, .tone] {
                let data = DirectVoiceReadyCuePlayer.cueData(character: character, sound: sound)
                let audio = try AVAudioPlayer(data: data)
                XCTAssertEqual(audio.duration, 0.24, accuracy: 0.001)
            }
        }
    }

    @MainActor
    func testWorkingMatchesTheIPhonesPurpleAndMouthIsOnlyPresentWhileSpeaking() throws {
        let traits = UITraitCollection(displayScale: 2)
        func pixels(_ state: NightBloodCarPlayVisualState) throws -> CarPlayRGBAPixels {
            let atlas = try XCTUnwrap(NightBloodCarPlayArtwork.sourceAtlas(for: state))
            return try rgbaPixels(of: NightBloodCarPlayArtwork.faceFrame(
                atlas: atlas, index: 0, traits: traits
            ))
        }
        let working = try pixels(.working).brightestRGB()
        let speaking = try pixels(.speaking).brightestRGB()
        XCTAssertGreaterThan(Int(working[0]), 100) // Blue's nearly zero red failed this.
        XCTAssertGreaterThan(Int(working[2]), 150)
        XCTAssertLessThan(Int(working[1]), 60)
        XCTAssertGreaterThanOrEqual(speaking[0], speaking[2])
        for state: NightBloodCarPlayVisualState in [.ready, .unavailable, .listening, .working] {
            XCTAssertEqual(try pixels(state).brightPixelCount(in: 0.7..<0.85), 0)
        }
    }

    @MainActor
    func testColdCarPlayWaitsForActiveSceneBeforePreparingDesktop() async {
        var interactive = false
        let setup = CarPlayReadyVoiceSetup(suspendPreparation: true)
        let media = CarPlayNativeMediaSpy()
        let model = DirectVoiceSessionModel(
            backgroundAudio: CarPlayNullBackgroundAudio(),
            nativeMediaFactory: CarPlayNativeMediaFactory(media: media),
            liveActivityPublisher: CarPlayNullLiveActivityPublisher(),
            interactiveSurfaceIsActive: { interactive }
        )
        model.taskReference = "11111111-1111-4111-8111-111111111111"
        model.install(setup: setup)
        model.applicationDidEnterBackground()
        model.carPlayDidConnect()
        await Task.yield()
        XCTAssertEqual(setup.preparationCalls, 0)
        XCTAssertEqual(model.state, .unavailable)
        XCTAssertFalse(model.canStartVoice)

        // Runtime calls this again from sceneDidBecomeActive, with no phone UI.
        interactive = true
        model.carPlayDidConnect()
        for _ in 0..<100 {
            if setup.preparationCalls == 1 { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(setup.preparationCalls, 1)
        XCTAssertFalse(model.webReady)
        XCTAssertFalse(model.canStartVoice)
        XCTAssertEqual(media.makeOfferCalls, 0)
        interactive = false
        model.carPlayDidDisconnect()
        model.applicationDidEnterBackground()
    }

    @MainActor
    func testCarPlayNeverStartsEitherMediaOwnerBeforeDesktopAcknowledgement() async {
        let media = CarPlayNativeMediaSpy()
        let setup = CarPlayReadyVoiceSetup(suspendPreparation: true)
        let model = DirectVoiceSessionModel(
            backgroundAudio: CarPlayNullBackgroundAudio(),
            nativeMediaFactory: CarPlayNativeMediaFactory(media: media),
            liveActivityPublisher: CarPlayNullLiveActivityPublisher(),
            interactiveSurfaceIsActive: { true }
        )
        let iPhoneFace = CarPlayFaceSpy()
        model.taskReference = "11111111-1111-4111-8111-111111111111"
        model.install(setup: setup)
        model.carPlayDidConnect()
        model.attach(face: iPhoneFace, role: .iPhone)
        model.authoriseAndStartFromCarPlayUserGesture()
        for _ in 0..<100 {
            if setup.preparationCalls == 1 { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(setup.preparationCalls, 1)
        XCTAssertEqual(media.makeOfferCalls, 0)
        XCTAssertNil(iPhoneFace.startedFace)
        XCTAssertFalse(model.hasOwnedVoice)
        XCTAssertFalse(model.canStartVoice)
        model.carPlayDidDisconnect()
        model.applicationDidEnterBackground()
    }

    @MainActor
    func testCarPlayConnectionFailureCanReconnectWithoutForceQuit() async {
        let setup = CarPlayReadyVoiceSetup()
        let model = DirectVoiceSessionModel(
            liveActivityPublisher: CarPlayNullLiveActivityPublisher(),
            interactiveSurfaceIsActive: { true }
        )
        model.taskReference = "11111111-1111-4111-8111-111111111111"
        model.install(setup: setup)
        model.carPlayDidConnect()
        for _ in 0..<100 {
            if model.state == .failed { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(model.state, .failed)
        XCTAssertTrue(model.canRetryVoiceConnection)
        XCTAssertFalse(model.hasOwnedVoice)
        XCTAssertEqual(setup.preparationCalls, 1)
        XCTAssertTrue(model.resetCarPlayConnectionPreparation())
        model.refreshAvailability()
        for _ in 0..<100 {
            if setup.preparationCalls == 2 { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(setup.preparationCalls, 2)
        XCTAssertFalse(model.hasOwnedVoice)
        model.carPlayDidDisconnect()
        model.applicationDidEnterBackground()
    }

    @MainActor
    func testPhoneBackgroundKeepsCarPlayPreparationAndDisconnectCancelsIt() async {
        var interactive = true
        let setup = CarPlayReadyVoiceSetup(suspendPreparation: true)
        let model = DirectVoiceSessionModel(
            liveActivityPublisher: CarPlayNullLiveActivityPublisher(),
            interactiveSurfaceIsActive: { interactive }
        )
        model.taskReference = "11111111-1111-4111-8111-111111111111"
        model.install(setup: setup)
        model.carPlayDidConnect()
        for _ in 0..<100 {
            if setup.preparationCalls == 1 { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        model.applicationDidEnterBackground()
        model.carPlayDidConnect()
        model.refreshAvailability()
        await Task.yield()
        XCTAssertEqual(setup.preparationCalls, 1)
        XCTAssertFalse(setup.preparationCancelled)
        XCTAssertFalse(model.canStartVoice)
        interactive = false
        model.carPlayDidDisconnect()
        // The XCTest host phone can remain foreground; explicitly deliver
        // its background callback too to model a locked phone in the car.
        model.applicationDidEnterBackground()
        for _ in 0..<100 {
            if setup.preparationCancelled { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(setup.preparationCancelled)
        XCTAssertFalse(model.canStartVoice)
        XCTAssertEqual(model.state, .unavailable)
    }

    @MainActor
    func testColdCarPlayConnectionKeepsSetupActiveWhilePhoneBackgrounds() {
        let setup = DirectCodexRemoteSetupModel(
            observeBackground: false,
            initiallyActive: false
        )

        setup.carPlayDidConnect()
        setup.applicationDidEnterBackground()

        XCTAssertTrue(setup.isCarPlayConnected)
        XCTAssertEqual(setup.phase, .checking)

        setup.carPlayDidDisconnect()
        setup.applicationDidEnterBackground()

        XCTAssertFalse(setup.isCarPlayConnected)
        XCTAssertEqual(setup.phase, .inactive)
    }
}

private struct CarPlayRGBAPixels {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    func rgb(at point: CGPoint) -> [UInt8] {
        let x = min(width - 1, max(0, Int(point.x * CGFloat(width))))
        let y = min(height - 1, max(0, Int(point.y * CGFloat(height))))
        let offset = (y * width + x) * 4
        return Array(bytes[offset..<(offset + 3)])
    }

    func alpha(at point: CGPoint) -> UInt8 {
        let x = min(width - 1, max(0, Int(point.x * CGFloat(width))))
        let y = min(height - 1, max(0, Int(point.y * CGFloat(height))))
        return bytes[(y * width + x) * 4 + 3]
    }

    func brightPixelCount(in verticalRange: Range<CGFloat>) -> Int {
        let firstRow = max(0, Int(verticalRange.lowerBound * CGFloat(height)))
        let lastRow = min(height, Int(verticalRange.upperBound * CGFloat(height)))
        var count = 0
        for y in firstRow..<lastRow {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                if bytes[offset] > 150
                    || bytes[offset + 1] > 150
                    || bytes[offset + 2] > 150
                {
                    count += 1
                }
            }
        }
        return count
    }

    func brightestRGB() -> [UInt8] {
        var brightest = [UInt8](repeating: 0, count: 3)
        var greatestValue = 0
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            let value = Int(bytes[offset])
                + Int(bytes[offset + 1])
                + Int(bytes[offset + 2])
            if value > greatestValue {
                greatestValue = value
                brightest = Array(bytes[offset..<(offset + 3)])
            }
        }
        return brightest
    }
}

private func rgbaPixels(of image: UIImage) throws -> CarPlayRGBAPixels {
    let source = try XCTUnwrap(image.cgImage)
    let width = source.width
    let height = source.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let rendered = bytes.withUnsafeMutableBytes { storage -> Bool in
        guard let context = CGContext(
            data: storage.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return false
        }
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    XCTAssertTrue(rendered)
    return CarPlayRGBAPixels(width: width, height: height, bytes: bytes)
}

@MainActor
private final class CarPlayNullLiveActivityPublisher:
    DirectVoiceLiveActivityPublishing
{
    func publish(_ snapshot: DirectVoiceLiveActivitySnapshot) {}
}

@MainActor
private final class CarPlayNullBackgroundAudio:
    DirectVoiceBackgroundAudioConfiguring
{
    func configureForVoice() throws {}
}

@MainActor
private final class CarPlayNativeMediaFactory: DirectNativeVoiceMediaCreating {
    private let media: CarPlayNativeMediaSpy

    init(media: CarPlayNativeMediaSpy) {
        self.media = media
    }

    func makeSession() throws -> any DirectNativeVoiceMediaControlling {
        media
    }
}

@MainActor
private final class CarPlayNativeMediaSpy: DirectNativeVoiceMediaControlling {
    private let offerError: (any Error)?
    private let suspendOffer: Bool
    private(set) var makeOfferCalls = 0
    private(set) var wasClosed = false
    private(set) var inputMuted = false

    init(offerError: (any Error)? = nil, suspendOffer: Bool = false) {
        self.offerError = offerError
        self.suspendOffer = suspendOffer
    }

    func makeOffer() async throws -> String {
        makeOfferCalls += 1
        while suspendOffer && !wasClosed {
            try await Task.sleep(for: .milliseconds(5))
        }
        if wasClosed { throw CodexRemoteVoiceError.cancelled }
        if let offerError { throw offerError }
        return "v=0\r\n"
    }

    func acceptAnswer(_ sdp: String) async throws {}
    func playReadyCue(character: DirectFaceSkin, sound: DirectReadySound) async {}

    func setInputMuted(_ muted: Bool) -> Bool {
        inputMuted = muted
        return true
    }

    func close() {
        wasClosed = true
    }
}

@MainActor
private final class CarPlayReadyVoiceSetup: DirectCodexVoiceTransportCreating {
    let isVoiceReady = true
    let suspendPreparation: Bool
    private(set) var preparationCalls = 0
    private(set) var preparationCancelled = false

    init(suspendPreparation: Bool = false) {
        self.suspendPreparation = suspendPreparation
    }

    func makeVoiceTransport() async throws -> CodexRemoteVoiceTransport {
        preparationCalls += 1
        if suspendPreparation {
            do { try await Task.sleep(for: .seconds(30)) }
            catch {
                preparationCancelled = true
                throw error
            }
        }
        throw DirectVoiceSessionError.noOwnedSession
    }
}

@MainActor
private final class CarPlayFaceSpy: DirectFaceJavaScriptControlling {
    private(set) var startedFace: DirectFaceSkin?
    private(set) var closedLocally = false
    private(set) var wasStopped = false

    func setAvailable(_ available: Bool) {}
    func setWorking(_ active: Bool) {}
    func setInputMuted(_ muted: Bool) async -> Bool { true }
    func setOutputMuted(_ muted: Bool) async -> Bool { true }
    func resumeAfterBackground(state: DirectVoiceSessionState) async -> Bool {
        true
    }
    func setSkin(_ skin: DirectFaceSkin) {}
    func start(character: DirectFaceSkin) { startedFace = character }
    func stop() { wasStopped = true }
    func closeLocalOnly() { closedLocally = true }
    func gaze(_ sample: GazeSample) {}
}
