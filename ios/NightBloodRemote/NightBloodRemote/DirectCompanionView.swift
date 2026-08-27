import SwiftUI
import UIKit

private enum DirectCompanionPage: Hashable {
    case face
    case conversation
}

private let directVoiceControlDiameter: CGFloat = 58

struct DirectCompanionView: View {
    @Bindable var voice: DirectVoiceSessionModel
    @Bindable var setup: DirectCodexRemoteSetupModel
    @Bindable var accessGate: DeviceAccessGate

    @State private var revealProgress: CGFloat = 0
    @State private var showingSettings = false

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let width = geometry.size.width
            let faceSize = min(width * 1.06, height * 0.64)
            let compactFaceHeight = max(250, height * 0.37)
            let progress = min(1, max(0, revealProgress))
            let faceY = interpolate(
                from: height * 0.47,
                to: geometry.safeAreaInsets.top + compactFaceHeight * 0.47,
                progress: progress
            )

            ScrollViewReader { proxy in
                ZStack(alignment: .top) {
                    Color.black.ignoresSafeArea()

                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 0) {
                            Color.clear
                                .frame(height: height)
                                .contentShape(Rectangle())
                                .simultaneousGesture(
                                    faceSwipeGesture(width: width)
                                )
                                .id(DirectCompanionPage.face)

                            DirectConversationPanel(
                                voice: voice,
                                faceSpace: compactFaceHeight,
                                viewportHeight: height
                            )
                            .frame(height: height)
                            .id(DirectCompanionPage.conversation)
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.paging)
                    .onScrollGeometryChange(for: CGFloat.self) { scroll in
                        scroll.contentOffset.y + scroll.contentInsets.top
                    } action: { _, offset in
                        revealProgress = min(1, max(0, offset / max(height, 1)))
                    }
                    .allowsHitTesting(accessGate.isUnlocked)

                    DirectFaceWebView(model: voice)
                        .frame(width: faceSize, height: faceSize)
                        .scaleEffect(
                            interpolate(from: 1, to: 0.86, progress: progress)
                        )
                        .position(x: width / 2, y: faceY)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)

                    if accessGate.isUnlocked {
                        controls(
                            geometry: geometry,
                            progress: progress,
                            scrollProxy: proxy
                        )
                    } else {
                        lockedCover.zIndex(10)
                    }
                }
            }
        }
        .ignoresSafeArea()
        .sheet(isPresented: $showingSettings) {
            DirectSettingsView(setup: setup, voice: voice)
        }
        .onChange(of: setup.phase) {
            voice.refreshAvailability()
        }
        .onChange(of: accessGate.isUnlocked) { _, isUnlocked in
            if !isUnlocked {
                showingSettings = false
            }
        }
        .alert(
            "Face ID required",
            isPresented: Binding(
                get: { accessGate.lastError != nil },
                set: { if !$0 { accessGate.lastError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(accessGate.lastError ?? "")
        }
    }

    @ViewBuilder
    private func controls(
        geometry: GeometryProxy,
        progress: CGFloat,
        scrollProxy: ScrollViewProxy
    ) -> some View {
        let height = geometry.size.height
        let width = geometry.size.width
        let safeTop = geometry.safeAreaInsets.top
        let sessionControlsVisible = voice.hasOwnedVoice || voice.state.isActive

        Button {
            Task {
                guard await accessGate.authoriseConnectionSettings() else {
                    return
                }
                showingSettings = true
            }
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 44, height: 44)
                .background(.black.opacity(0.46), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.13)))
        }
        .foregroundStyle(.white.opacity(0.78))
        .position(x: 34, y: safeTop + 30)
        .accessibilityLabel("Secure Codex Remote settings")

        Text(voice.statusLabel.uppercased())
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .tracking(1.6)
            .foregroundStyle(.white.opacity(0.58))
            .opacity(1 - progress)
            .position(x: width / 2, y: height - 136)

        Button {
            if voice.hasOwnedVoice || voice.state.isActive {
                voice.stopFromUserGesture()
            } else {
                Task {
                    guard await accessGate.authoriseVoiceStart() else {
                        return
                    }
                    voice.authoriseAndStartFromUserGesture()
                }
            }
        } label: {
            DirectRoundVoiceControl(
                systemName: controlIcon,
                highlighted: false
            )
        }
        .foregroundStyle(.white)
        .accessibilityLabel(controlLabel)
        .accessibilityIdentifier("voice-control")
        .position(
            x: interpolate(
                from: sessionControlsVisible ? width / 2 - 72 : width / 2,
                to: width - 58,
                progress: progress
            ),
            y: interpolate(from: height - 92, to: safeTop + 84, progress: progress)
        )
        .animation(.smooth(duration: 0.25), value: sessionControlsVisible)

        if voice.hasOwnedVoice || voice.state.isActive {
            Button {
                Task { await voice.toggleMicrophoneInput() }
            } label: {
                DirectRoundVoiceControl(
                    systemName: voice.isMicrophoneMuted
                        ? "mic.slash.fill" : "mic.fill",
                    highlighted: voice.isMicrophoneMuted
                )
            }
            .foregroundStyle(.white)
            .disabled(!voice.canToggleMicrophoneInput)
            .opacity(voice.canToggleMicrophoneInput ? 1 : 0.48)
            .position(
                x: interpolate(
                    from: width / 2,
                    to: width - 58,
                    progress: progress
                ),
                y: interpolate(
                    from: height - 92,
                    to: safeTop + 150,
                    progress: progress
                )
            )
            .accessibilityLabel(
                voice.isMicrophoneMuted
                    ? "Unmute microphone" : "Mute microphone"
            )
            .accessibilityValue(
                voice.isMicrophoneMuted ? "Muted" : "Listening"
            )
            .accessibilityHint(
                "Codex will stop hearing you while the conversation stays connected."
            )
            .accessibilityIdentifier("microphone-mute")

            Button {
                Task { await voice.toggleSpeakerOutput() }
            } label: {
                DirectRoundVoiceControl(
                    systemName: voice.isSpeakerOutputMuted
                        ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    highlighted: voice.isSpeakerOutputMuted
                )
            }
            .foregroundStyle(.white)
            .disabled(!voice.canToggleSpeakerOutput)
            .opacity(voice.canToggleSpeakerOutput ? 1 : 0.48)
            .position(
                x: interpolate(
                    from: width / 2 + 72,
                    to: width - 58,
                    progress: progress
                ),
                y: interpolate(
                    from: height - 92,
                    to: safeTop + 216,
                    progress: progress
                )
            )
            .accessibilityLabel(
                voice.isSpeakerOutputMuted
                    ? "Unmute speaker output" : "Mute speaker output"
            )
            .accessibilityValue(
                voice.isSpeakerOutputMuted ? "Muted" : "Audible"
            )
            .accessibilityHint(
                "Your microphone and Codex conversation remain active."
            )
            .accessibilityIdentifier("speaker-output-mute")
        }

        if progress < 0.08 {
            Button {
                let offset = voice.selectedFace == .nightblood ? 1 : -1
                selectFace(offset: offset)
            } label: {
                VStack(spacing: 6) {
                    Text(voice.selectedFace.displayName.uppercased())
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(1.3)
                    HStack(spacing: 7) {
                        ForEach(DirectFaceSkin.allCases, id: \.self) { skin in
                            Capsule()
                                .fill(.white.opacity(
                                    skin == voice.selectedFace ? 0.86 : 0.24
                                ))
                                .frame(
                                    width: skin == voice.selectedFace ? 18 : 7,
                                    height: 5
                                )
                        }
                    }
                }
                .frame(minWidth: 104, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.62))
            .disabled(!voice.canSelectFace)
            .opacity(voice.canSelectFace ? 1 : 0.42)
            .position(x: width / 2, y: height - 174)
            .accessibilityLabel("Appearance")
            .accessibilityValue(voice.selectedFace.displayName)
            .accessibilityHint(voice.canSelectFace
                ? "Double-tap to switch face"
                : "End the conversation to switch character")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: selectFace(offset: 1)
                case .decrement: selectFace(offset: -1)
                @unknown default: break
                }
            }
        }

        Button {
            withAnimation(.smooth(duration: 0.45)) {
                scrollProxy.scrollTo(
                    progress < 0.5
                        ? DirectCompanionPage.conversation
                        : DirectCompanionPage.face,
                    anchor: .top
                )
            }
        } label: {
            Image(systemName: progress < 0.5 ? "chevron.up" : "chevron.down")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 52, height: 34)
        }
        .foregroundStyle(.white.opacity(0.58))
        .position(
            x: width / 2,
            y: interpolate(from: height - 29, to: safeTop + 27, progress: progress)
        )
    }

    private var controlIcon: String {
        if voice.hasOwnedVoice || voice.state.isActive { return "stop.fill" }
        if accessGate.state == .unlocking { return "faceid" }
        return setup.phase == .ready ? "waveform" : "lock.fill"
    }

    private var controlLabel: String {
        if voice.hasOwnedVoice || voice.state.isActive {
            return "End conversation"
        }
        return setup.phase == .ready
            ? "Start private Codex Voice conversation"
            : "Finish secure Codex Remote setup"
    }

    private func faceSwipeGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 20)
            .onEnded { value in
                guard revealProgress < 0.08,
                      accessGate.isUnlocked,
                      !showingSettings,
                      value.startLocation.x > 24,
                      value.startLocation.x < width - 24
                else {
                    return
                }
                let horizontal = value.translation.width
                let vertical = value.translation.height
                guard abs(horizontal) >= max(72, width * 0.18),
                      abs(horizontal) > abs(vertical) * 1.35
                else {
                    return
                }
                selectFace(offset: horizontal < 0 ? 1 : -1)
            }
    }

    private func selectFace(offset: Int) {
        guard voice.selectAdjacentFace(offset: offset) else { return }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private var lockedCover: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: accessGate.state == .unlocking
                    ? "faceid" : "lock.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.82))
                Text(accessGate.state == .unlocking
                    ? "Verifying Face ID" : "NightBlood locked")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.78))
                if accessGate.state != .unlocking {
                    Button("Unlock") {
                        Task {
                            guard await accessGate.unlock() else { return }
                            setup.applicationDidBecomeActive()
                            setup.refreshPersistedState()
                            voice.startGazeTracking()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.white.opacity(0.18))
                }
            }
        }
    }

    private func interpolate(
        from: CGFloat,
        to: CGFloat,
        progress: CGFloat
    ) -> CGFloat {
        from + (to - from) * progress
    }
}

private struct DirectConversationPanel: View {
    private let transcriptBottomID = "nightblood-conversation-bottom"

    let voice: DirectVoiceSessionModel
    let faceSpace: CGFloat
    let viewportHeight: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: faceSpace)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack {
                            Text("CONVERSATION")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .tracking(2.1)
                                .foregroundStyle(.white.opacity(0.48))
                            Spacer()
                            Text(voice.statusLabel)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.36))
                        }
                        if voice.transcript.isEmpty {
                            Text("What you and \(voice.displayAgentName) say will appear here.")
                                .font(.system(size: 19, design: .rounded))
                                .foregroundStyle(.white.opacity(0.34))
                                .padding(.top, 14)
                        } else {
                            LazyVStack(spacing: 20) {
                                ForEach(voice.transcript) { item in
                                    DirectConversationMessage(
                                        item: item,
                                        agentName: voice.displayAgentName
                                    )
                                }
                            }
                        }
                        if let error = voice.lastError, !error.isEmpty {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red.opacity(0.86))
                                .padding(.top, 10)
                        }
                        Color.clear
                            .frame(height: 110)
                            .id(transcriptBottomID)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onAppear {
                    proxy.scrollTo(transcriptBottomID, anchor: .bottom)
                }
                .onChange(of: voice.transcript) {
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(transcriptBottomID, anchor: .bottom)
                    }
                }
                .background(
                    LinearGradient(
                        colors: [.black.opacity(0), .black.opacity(0.93), .black],
                        startPoint: .top,
                        endPoint: .init(x: 0.5, y: 0.18)
                    )
                )
            }
        }
        .frame(height: viewportHeight)
    }
}

private struct DirectConversationMessage: View {
    let item: DirectTranscriptItem
    let agentName: String

    private var isUser: Bool { item.role == .user }

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if isUser { Spacer(minLength: 54) }

            VStack(
                alignment: isUser ? .trailing : .leading,
                spacing: 6
            ) {
                Text(
                    isUser
                        ? "YOU"
                        : agentName.uppercased()
                )
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1.5)
                    .foregroundStyle(
                        isUser
                            ? .white.opacity(0.38)
                            : .purple.opacity(0.82)
                    )

                Text(item.text)
                    .font(.system(size: 19, design: .rounded))
                    .foregroundStyle(.white.opacity(item.isFinal ? 0.90 : 0.58))
                    .multilineTextAlignment(.leading)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)

            if !isUser { Spacer(minLength: 54) }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct DirectRoundVoiceControl: View {
    let systemName: String
    let highlighted: Bool

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 18, weight: .semibold))
            .frame(
                width: directVoiceControlDiameter,
                height: directVoiceControlDiameter
            )
            .background(
                .white.opacity(highlighted ? 0.20 : 0.10),
                in: Circle()
            )
            .overlay(Circle().stroke(.white.opacity(0.22)))
    }
}
