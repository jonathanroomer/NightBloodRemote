import XCTest
@testable import NightBlood

final class DirectCharacterPromptTests: XCTestCase {
    func testBundledCharacterPromptsLoadWithinProtocolLimit() throws {
        let nightBlood = try DirectCharacterPromptStore.load(for: .nightblood)
        let marshmallow = try DirectCharacterPromptStore.load(for: .marshmallow)

        XCTAssertLessThanOrEqual(
            nightBlood.text.utf8.count,
            CodexRemoteVoiceConstants.maximumPromptBytes
        )
        XCTAssertLessThanOrEqual(
            marshmallow.text.utf8.count,
            CodexRemoteVoiceConstants.maximumPromptBytes
        )
        XCTAssertTrue(nightBlood.text.hasPrefix("# Role\n\nThe user calls you Nightblood."))
        XCTAssertTrue(marshmallow.text.hasPrefix("# Role\n\nThe user calls you Marshmallow."))
    }

    func testPromptValidationRejectsEmptyAndOversizedValues() {
        XCTAssertThrowsError(try CodexRemoteVoicePrompt(validating: "  \n"))
        XCTAssertThrowsError(
            try CodexRemoteVoicePrompt(
                validating: String(
                    repeating: "a",
                    count: CodexRemoteVoiceConstants.maximumPromptBytes + 1
                )
            )
        )
    }

    func testRealtimeStartParametersContainTheExactNativePrompt() throws {
        let prompt = try CodexRemoteVoicePrompt(validating: "A distinct voice.")
        let parameters = codexRemoteRealtimeStartParameters(
            threadID: "thread-123",
            sdpOffer: "v=0\r\n",
            voice: .sol,
            prompt: prompt,
            realtimeSessionID: UUID(
                uuidString: "11111111-2222-3333-4444-555555555555"
            )!
        )

        let object = try XCTUnwrap(parameters.objectValue)
        XCTAssertEqual(object["prompt"], .string(prompt.text))
        XCTAssertEqual(object["voice"], .string("sol"))
        XCTAssertEqual(object["threadId"], .string("thread-123"))
        XCTAssertEqual(object["version"], .string("v3"))
        XCTAssertEqual(object["includeStartupContext"], .bool(false))
        XCTAssertEqual(object["initialItems"], .array([]))
        XCTAssertEqual(
            object["transport"],
            .object(["type": .string("webrtc"), "sdp": .string("v=0\r\n")])
        )
    }
}
