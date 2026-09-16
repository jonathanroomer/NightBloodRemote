import XCTest
@testable import NightBlood

final class CodexRemoteHeartbeatAutomationTests: XCTestCase {
    private let threadID = "11111111-2222-3333-4444-555555555555"
    private let uuid = UUID(uuidString: "12345678-1234-1234-1234-1234567890ab")!

    func testCreatesDesktopCompatibleFiveMinuteHeartbeat() throws {
        let automation = try make()

        XCTAssertEqual(automation.id, "iphone-heartbeat-test")
        XCTAssertEqual(automation.rrule, "FREQ=MINUTELY;INTERVAL=5")
        XCTAssertTrue(automation.toml.contains("kind = \"heartbeat\""))
        XCTAssertTrue(automation.toml.contains("status = \"ACTIVE\""))
        XCTAssertTrue(
            automation.toml.contains("target_thread_id = \"\(threadID)\"")
        )
        XCTAssertEqual(
            CodexRemoteHeartbeatAutomation.activeHeartbeatTarget(
                in: automation.toml
            ),
            threadID
        )
    }

    func testSupportsThirtySecondHeartbeatButRejectsFasterSchedule() throws {
        XCTAssertEqual(
            try CodexRemoteHeartbeatAutomation.normalisedRRule(
                "FREQ=SECONDLY;INTERVAL=30"
            ),
            "FREQ=SECONDLY;INTERVAL=30"
        )
        XCTAssertThrowsError(
            try CodexRemoteHeartbeatAutomation.normalisedRRule(
                "FREQ=SECONDLY;INTERVAL=29"
            )
        )
    }

    func testRejectsSecondActiveHeartbeatForTheSameTask() throws {
        let existing = try make().toml
        XCTAssertThrowsError(
            try make(existingAutomationFiles: [existing])
        ) { error in
            XCTAssertEqual(
                error as? CodexRemoteHeartbeatAutomationError,
                .duplicateHeartbeat
            )
        }
    }

    func testUsesDesktopCollisionSuffixes() throws {
        let automation = try make(existingIDs: [
            "iphone-heartbeat-test",
            "iphone-heartbeat-test-2",
        ])
        XCTAssertEqual(automation.id, "iphone-heartbeat-test-3")
    }

    func testEscapesPromptAsTOMLBasicString() throws {
        let automation = try make(prompt: "Say \"hello\".\nThen use \\\\ safely.")
        XCTAssertTrue(
            automation.toml.contains(
                "prompt = \"Say \\\"hello\\\".\\nThen use \\\\\\\\ safely.\""
            )
        )
    }

    func testRejectsDifferentTargetTask() throws {
        var arguments = defaultArguments()
        arguments["targetThreadId"] = .string("different-task")
        XCTAssertThrowsError(
            try CodexRemoteHeartbeatAutomation.make(
                arguments: arguments,
                targetThreadID: threadID,
                existingIDs: [],
                existingAutomationFiles: [],
                createdAtMilliseconds: 1_787_566_800_000,
                fallbackUUID: uuid
            )
        )
    }

    func testFindsOwnedHeartbeatForCancellation() throws {
        let automation = try make()
        let lookup = try CodexRemoteHeartbeatAutomation.deletionLookup(
            arguments: [
                "mode": .string("delete"),
                "id": .string(automation.id),
            ],
            targetThreadID: threadID,
            existingIDs: [automation.id],
            filesByID: [automation.id: automation.toml]
        )

        XCTAssertEqual(
            lookup,
            .owned(.init(
                id: automation.id,
                name: automation.name,
                rrule: automation.rrule
            ))
        )
    }

    func testCancellationCannotDeleteAnotherTasksHeartbeat() throws {
        let automation = try make()
        XCTAssertThrowsError(
            try CodexRemoteHeartbeatAutomation.deletionLookup(
                arguments: [
                    "mode": .string("delete"),
                    "id": .string(automation.id),
                ],
                targetThreadID: "different-task",
                existingIDs: [automation.id],
                filesByID: [automation.id: automation.toml]
            )
        )
    }

    func testCancellationAcceptsVoiceAutomationIdentifier() throws {
        let automation = try make()
        let lookup = try CodexRemoteHeartbeatAutomation.deletionLookup(
            arguments: [
                "mode": .string("delete"),
                "kind": .string("heartbeat"),
                "automationId": .string(automation.id),
            ],
            targetThreadID: threadID,
            existingIDs: [automation.id],
            filesByID: [automation.id: automation.toml]
        )

        guard case .owned(let snapshot) = lookup else {
            return XCTFail("Expected an owned heartbeat")
        }
        XCTAssertEqual(snapshot.id, automation.id)
    }

    private func make(
        prompt: String = "Reply exactly: iPhone heartbeat works.",
        existingIDs: Set<String> = [],
        existingAutomationFiles: [String] = []
    ) throws -> CodexRemoteHeartbeatAutomation {
        var arguments = defaultArguments()
        arguments["prompt"] = .string(prompt)
        return try CodexRemoteHeartbeatAutomation.make(
            arguments: arguments,
            targetThreadID: threadID,
            existingIDs: existingIDs,
            existingAutomationFiles: existingAutomationFiles,
            createdAtMilliseconds: 1_787_566_800_000,
            fallbackUUID: uuid
        )
    }

    private func defaultArguments() -> [String: CodexRemoteVoiceJSON] {
        [
            "destination": .string("thread"),
            "kind": .string("heartbeat"),
            "mode": .string("create"),
            "name": .string("iPhone heartbeat test"),
            "prompt": .string("Reply exactly: iPhone heartbeat works."),
            "rrule": .string("FREQ=MINUTELY;INTERVAL=5"),
            "status": .string("ACTIVE"),
            "targetThreadId": .string(threadID),
        ]
    }
}

extension CodexRemoteHeartbeatAutomationTests {
    func testBoundedAutomationReadsWithInjectedRoundTrips() async throws {
        for count in [1, 20, 128] {
            let fixture = AutomationReadLatencyFixture()
            let names = (0..<count).map { "fixture-\($0)" }
            let files = try await CodexRemoteHeartbeatAutomation.readFiles(names: names) {
                try await fixture.read($0)
            }
            let peak = await fixture.maximumActive
            let requests = await fixture.requests
            XCTAssertEqual(files.count, count)
            XCTAssertEqual(requests, count * 2)
            XCTAssertEqual(peak, min(4, count))
        }
    }

    func testAutomationReadCancellationDoesNotLaunchMoreWork() async throws {
        let fixture = AutomationReadLatencyFixture(delay: .seconds(30))
        let reading = Task {
            try await CodexRemoteHeartbeatAutomation.readFiles(
                names: (0..<128).map { "fixture-\($0)" }
            ) { try await fixture.read($0) }
        }
        try await Task.sleep(for: .milliseconds(20))
        reading.cancel()
        do {
            _ = try await reading.value
            XCTFail("cancelled filesystem traversal returned success")
        } catch is CancellationError {
            let requests = await fixture.requests
            XCTAssertLessThanOrEqual(requests, 4)
        }
    }
}

private actor AutomationReadLatencyFixture {
    private var active = 0
    private(set) var maximumActive = 0
    private(set) var requests = 0
    private let delay: Duration

    init(delay: Duration = .milliseconds(2)) { self.delay = delay }

    func read(_ name: String) async throws -> String? {
        active += 1
        maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        requests += 1 // list directory
        try await Task.sleep(for: delay)
        requests += 1 // read bounded TOML
        try await Task.sleep(for: delay)
        return "id = \"\(name)\""
    }
}
