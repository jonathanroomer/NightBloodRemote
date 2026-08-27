import AppIntents

enum NightBloodLiveActivityAction: String, Sendable {
    case toggleMicrophone
    case stopConversation
    case toggleSpeakerOutput
}

/// `LiveActivityIntent` makes iOS execute these actions in the containing app
/// process. The shared source also compiles into the widget extension so its
/// buttons can reference the same intent types.
@MainActor
enum NightBloodLiveActivityActionBus {
    typealias Handler = @MainActor (NightBloodLiveActivityAction) async -> Void

    private static var handler: Handler?

    static func install(_ handler: @escaping Handler) {
        self.handler = handler
    }

    static func perform(_ action: NightBloodLiveActivityAction) async {
        await handler?(action)
    }
}

struct NightBloodToggleMicrophoneIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Toggle NightBlood microphone"
    static let description = IntentDescription(
        "Mute or unmute the iPhone microphone without ending the conversation."
    )
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        await NightBloodLiveActivityActionBus.perform(.toggleMicrophone)
        return .result()
    }
}

struct NightBloodStopConversationIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Stop NightBlood conversation"
    static let description = IntentDescription(
        "End the active NightBlood voice conversation."
    )
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        await NightBloodLiveActivityActionBus.perform(.stopConversation)
        return .result()
    }
}

struct NightBloodToggleSpeakerIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Toggle NightBlood speaker"
    static let description = IntentDescription(
        "Mute or unmute NightBlood's speaker output while keeping the conversation connected."
    )
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        await NightBloodLiveActivityActionBus.perform(.toggleSpeakerOutput)
        return .result()
    }
}
