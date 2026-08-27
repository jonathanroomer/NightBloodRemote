import ActivityKit
import Foundation

struct NightBloodVoiceActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        let status: String
        let sessionState: String
        let microphoneMuted: Bool
        let speakerOutputMuted: Bool
    }

    let sessionID: UUID
    let agentName: String
}
