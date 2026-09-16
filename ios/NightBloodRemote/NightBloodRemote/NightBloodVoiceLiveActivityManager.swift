import ActivityKit
import Foundation

struct DirectVoiceLiveActivitySnapshot: Equatable, Sendable {
    let agentName: String
    let status: String
    let sessionState: String
    let microphoneMuted: Bool
    let speakerOutputMuted: Bool
    let shouldBeVisible: Bool

    var contentState: NightBloodVoiceActivityAttributes.ContentState {
        NightBloodVoiceActivityAttributes.ContentState(
            status: status,
            sessionState: sessionState,
            microphoneMuted: microphoneMuted,
            speakerOutputMuted: speakerOutputMuted
        )
    }
}

@MainActor
protocol DirectVoiceLiveActivityPublishing: AnyObject {
    func publish(_ snapshot: DirectVoiceLiveActivitySnapshot)
}

@MainActor
final class NightBloodVoiceLiveActivityManager:
    DirectVoiceLiveActivityPublishing
{
    static let shared = NightBloodVoiceLiveActivityManager()

    private typealias VoiceActivity = Activity<NightBloodVoiceActivityAttributes>

    private var desiredSnapshot: DirectVoiceLiveActivitySnapshot?
    private var appliedSnapshot: DirectVoiceLiveActivitySnapshot?
    private var appliedActivityID: String?
    private var worker: Task<Void, Never>?

    private init() {}

    func publish(_ snapshot: DirectVoiceLiveActivitySnapshot) {
        desiredSnapshot = snapshot
        startWorkerIfNeeded()
    }

    private func startWorkerIfNeeded() {
        guard worker == nil else { return }
        worker = Task { @MainActor [weak self] in
            await self?.drainSnapshots()
        }
    }

    private func drainSnapshots() async {
        while let snapshot = desiredSnapshot {
            desiredSnapshot = nil
            await apply(snapshot)
        }
        worker = nil
        if desiredSnapshot != nil {
            startWorkerIfNeeded()
        }
    }

    private func apply(_ snapshot: DirectVoiceLiveActivitySnapshot) async {
        let activities = VoiceActivity.activities
        guard snapshot.shouldBeVisible else {
            for activity in activities {
                await activity.end(
                    ActivityContent(
                        state: snapshot.contentState,
                        staleDate: nil
                    ),
                    dismissalPolicy: .immediate
                )
            }
            appliedSnapshot = nil
            appliedActivityID = nil
            return
        }

        if let activity = activities.first {
            if appliedSnapshot != snapshot || appliedActivityID != activity.id
                || activity.activityState != .active {
                await activity.update(
                    ActivityContent(
                        state: snapshot.contentState,
                        staleDate: nil
                    )
                )
                appliedSnapshot = snapshot
                appliedActivityID = activity.id
            }
            for duplicate in activities.dropFirst() {
                await duplicate.end(nil, dismissalPolicy: .immediate)
            }
            return
        }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            let activity = try VoiceActivity.request(
                attributes: NightBloodVoiceActivityAttributes(
                    sessionID: UUID(),
                    agentName: snapshot.agentName
                ),
                content: ActivityContent(
                    state: snapshot.contentState,
                    staleDate: nil
                ),
                pushType: nil
            )
            appliedSnapshot = snapshot
            appliedActivityID = activity.id
        } catch {
            #if DEBUG
            print("NightBloodLiveActivity start failed: \(error.localizedDescription)")
            #endif
        }
    }
}
