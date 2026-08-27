import XCTest
@testable import NightBlood

final class CodexRemoteVoiceServerRequestRouteTests: XCTestCase {
    private let threadID = "11111111-2222-3333-4444-555555555555"
    private let projectID = "12345678-1234-1234-1234-1234567890ab"

    func testDeviceAttestationStaysOnTheIPhone() {
        XCTAssertEqual(
            codexRemoteVoiceServerRequestRoute(
                method: "attestation/generate",
                params: [:],
                threadID: threadID
            ),
            .deviceAttestation
        )
    }

    func testMatchingHeartbeatStaysOnTheIPhone() {
        XCTAssertEqual(
            route(tool: "automation_update", threadID: threadID),
            .heartbeatAutomation
        )
    }

    func testTaskLifecycleToolsUseTheBoundedNativeRoute() {
        XCTAssertEqual(
            route(tool: "create_thread", threadID: threadID),
            .nativeThreadCreate
        )
        XCTAssertEqual(
            route(tool: "list_projects", threadID: threadID),
            .nativeProjectList
        )
        XCTAssertEqual(
            route(tool: "read_thread", threadID: threadID),
            .nativeThreadRead
        )
        XCTAssertEqual(
            route(tool: "wait_threads", threadID: threadID),
            .nativeThreadWait
        )
    }

    func testUnsupportedVoiceToolsFailBoundedly() {
        XCTAssertEqual(
            route(tool: "set_thread_archived", threadID: threadID),
            .unsupportedVoiceDynamicTool
        )
    }

    func testHeartbeatForAnotherTaskIsLeftForDesktop() {
        XCTAssertEqual(
            route(
                tool: "automation_update",
                threadID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
            ),
            .desktopDynamicTool
        )
    }

    func testMalformedAndUnknownRequestsRemainRejected() {
        XCTAssertEqual(
            codexRemoteVoiceServerRequestRoute(
                method: "item/tool/call",
                params: ["threadId": .string(threadID)],
                threadID: threadID
            ),
            .reject
        )
        XCTAssertEqual(
            codexRemoteVoiceServerRequestRoute(
                method: "item/requestUserInput",
                params: [:],
                threadID: threadID
            ),
            .reject
        )
    }

    func testCreateThreadParserAcceptsOnlyTheCurrentLocalProject() throws {
        let request = try CodexRemoteVoiceNativeCreateThreadRequest(
            params: createThreadParams(),
            expectedThreadID: threadID,
            allowedProjectID: projectID
        )
        XCTAssertEqual(request.prompt, "Please investigate this.")
        XCTAssertEqual(request.title, "Voice task")
        XCTAssertEqual(request.model, "gpt-5.6-luna")
        XCTAssertEqual(request.thinking, "low")
    }

    func testCreateThreadParserRejectsWorktreesAndOtherProjects() {
        var worktree = createThreadParams()
        var worktreeArguments = worktree["arguments"]!.objectValue!
        var worktreeTarget = worktreeArguments["target"]!.objectValue!
        worktreeTarget["environment"] = .object([
            "type": .string("worktree"),
        ])
        worktreeArguments["target"] = .object(worktreeTarget)
        worktree["arguments"] = .object(worktreeArguments)
        XCTAssertThrowsError(
            try CodexRemoteVoiceNativeCreateThreadRequest(
                params: worktree,
                expectedThreadID: threadID,
                allowedProjectID: projectID
            )
        )

        var otherProject = createThreadParams()
        var otherArguments = otherProject["arguments"]!.objectValue!
        var otherTarget = otherArguments["target"]!.objectValue!
        otherTarget["projectId"] = .string(
            "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        )
        otherArguments["target"] = .object(otherTarget)
        otherProject["arguments"] = .object(otherArguments)
        XCTAssertThrowsError(
            try CodexRemoteVoiceNativeCreateThreadRequest(
                params: otherProject,
                expectedThreadID: threadID,
                allowedProjectID: projectID
            )
        )
    }

    func testCreateThreadFingerprintDeduplicatesEquivalentRequests() throws {
        let first = try CodexRemoteVoiceNativeCreateThreadRequest(
            params: createThreadParams(),
            expectedThreadID: threadID,
            allowedProjectID: projectID
        )
        let second = try CodexRemoteVoiceNativeCreateThreadRequest(
            params: createThreadParams(),
            expectedThreadID: threadID,
            allowedProjectID: projectID
        )
        XCTAssertEqual(first.fingerprint, second.fingerprint)
    }

    private func route(
        tool: String,
        threadID requestThreadID: String
    ) -> CodexRemoteVoiceServerRequestRoute {
        codexRemoteVoiceServerRequestRoute(
            method: "item/tool/call",
            params: [
                "threadId": .string(requestThreadID),
                "tool": .string(tool),
            ],
            threadID: threadID
        )
    }

    private func createThreadParams() -> [String: CodexRemoteVoiceJSON] {
        [
            "threadId": .string(threadID),
            "tool": .string("create_thread"),
            "arguments": .object([
                "prompt": .string("Please investigate this."),
                "title": .string("Voice task"),
                "model": .string("gpt-5.6-luna"),
                "thinking": .string("low"),
                "target": .object([
                    "type": .string("project"),
                    "projectId": .string(projectID),
                    "environment": .object([
                        "type": .string("local"),
                    ]),
                ]),
            ]),
        ]
    }
}
