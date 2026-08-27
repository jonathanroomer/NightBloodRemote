import ActivityKit
import SwiftUI
import WidgetKit

@main
struct NightBloodVoiceLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NightBloodVoiceActivityAttributes.self) {
            context in
            NightBloodLockScreenActivityView(context: context)
                .activityBackgroundTint(.black.opacity(0.94))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    NightBloodActivityMark(size: 28)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    NightBloodActivityStateIcon(
                        sessionState: context.state.sessionState
                    )
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(context.attributes.agentName.uppercased())
                            .font(.caption2.weight(.bold))
                            .tracking(1.2)
                        Text(context.state.status)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.72))
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    NightBloodActivityControls(state: context.state)
                        .padding(.top, 6)
                }
            } compactLeading: {
                NightBloodActivityMark(size: 22)
            } compactTrailing: {
                NightBloodActivityStateIcon(
                    sessionState: context.state.sessionState
                )
            } minimal: {
                NightBloodActivityMark(size: 22)
            }
            .keylineTint(NightBloodActivityStyle.blue)
        }
    }
}

private struct NightBloodLockScreenActivityView: View {
    let context: ActivityViewContext<NightBloodVoiceActivityAttributes>

    var body: some View {
        HStack(spacing: 16) {
            NightBloodActivityMark(size: 40)

            VStack(alignment: .leading, spacing: 3) {
                Text(context.attributes.agentName.uppercased())
                    .font(.caption2.weight(.bold))
                    .tracking(1.4)
                    .foregroundStyle(.white.opacity(0.64))
                Text(context.state.status)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            NightBloodActivityControls(state: context.state)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }
}

private struct NightBloodActivityControls: View {
    let state: NightBloodVoiceActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            Button(intent: NightBloodToggleMicrophoneIntent()) {
                NightBloodActivityControlIcon(
                    systemName: state.microphoneMuted
                        ? "mic.slash.fill" : "mic.fill",
                    active: state.microphoneMuted,
                    destructive: false
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                state.microphoneMuted
                    ? "Unmute microphone" : "Mute microphone"
            )

            Button(intent: NightBloodStopConversationIntent()) {
                NightBloodActivityControlIcon(
                    systemName: "stop.fill",
                    active: true,
                    destructive: true
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop conversation")

            Button(intent: NightBloodToggleSpeakerIntent()) {
                NightBloodActivityControlIcon(
                    systemName: state.speakerOutputMuted
                        ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    active: state.speakerOutputMuted,
                    destructive: false
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                state.speakerOutputMuted
                    ? "Unmute speaker output" : "Mute speaker output"
            )
        }
    }
}

private struct NightBloodActivityControlIcon: View {
    let systemName: String
    let active: Bool
    let destructive: Bool

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 38, height: 38)
            .background(
                Circle().fill(backgroundColour)
            )
            .contentShape(Circle())
    }

    private var backgroundColour: Color {
        if destructive {
            return .red.opacity(0.86)
        }
        return active
            ? NightBloodActivityStyle.blue.opacity(0.86)
            : .white.opacity(0.12)
    }
}

private struct NightBloodActivityMark: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(
                cornerRadius: size * 0.225,
                style: .continuous
            )
            .fill(.black)

            NightBloodActivityEyes()
                .fill(.white)
                .shadow(
                    color: .white.opacity(0.72),
                    radius: max(1, size * 0.055)
                )
        }
        .frame(width: size, height: size)
        .compositingGroup()
        .widgetAccentable(false)
        .accessibilityHidden(true)
    }
}

private struct NightBloodActivityEyes: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()

        addEye(to: &path, in: rect, mirrored: false)
        addEye(to: &path, in: rect, mirrored: true)

        return path
    }

    private func addEye(
        to path: inout Path,
        in rect: CGRect,
        mirrored: Bool
    ) {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            let resolvedX = mirrored ? 1 - x : x
            return CGPoint(
                x: rect.minX + resolvedX * rect.width,
                y: rect.minY + y * rect.height
            )
        }

        path.move(to: point(0.078, 0.393))
        path.addCurve(
            to: point(0.434, 0.513),
            control1: point(0.185, 0.402),
            control2: point(0.340, 0.445)
        )
        path.addCurve(
            to: point(0.304, 0.516),
            control1: point(0.390, 0.508),
            control2: point(0.348, 0.518)
        )
        path.addCurve(
            to: point(0.078, 0.393),
            control1: point(0.205, 0.518),
            control2: point(0.142, 0.468)
        )
        path.closeSubpath()
    }
}

private struct NightBloodActivityStateIcon: View {
    let sessionState: String

    var body: some View {
        Image(systemName: symbol)
            .font(.caption.weight(.bold))
            .foregroundStyle(NightBloodActivityStyle.blue)
    }

    private var symbol: String {
        switch sessionState {
        case "thinking": "ellipsis"
        case "speaking": "waveform"
        default: "ear"
        }
    }
}

private enum NightBloodActivityStyle {
    static let blue = Color(red: 0.13, green: 0.67, blue: 1.0)
}
