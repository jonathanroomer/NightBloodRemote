@preconcurrency import AVFAudio
import Foundation
@preconcurrency import WebRTC

enum DirectNativeWebRTCError: LocalizedError {
    case peerUnavailable
    case offerFailed(String)
    case localDescriptionFailed(String)
    case iceGatheringTimedOut
    case answerFailed(String)
    case connectionTimedOut
    case connectionFailed

    var errorDescription: String? {
        switch self {
        case .peerUnavailable:
            "The native car audio connection is unavailable."
        case .offerFailed(let detail):
            "The car audio offer could not be created: \(detail)"
        case .localDescriptionFailed(let detail):
            "The car audio offer could not be prepared: \(detail)"
        case .iceGatheringTimedOut:
            "The car audio connection did not become ready in time."
        case .answerFailed(let detail):
            "The car audio answer could not be applied: \(detail)"
        case .connectionTimedOut:
            "The car audio connection did not open in time."
        case .connectionFailed:
            "The car audio connection failed."
        }
    }
}

@MainActor
protocol DirectNativeVoiceMediaControlling: AnyObject {
    func makeOffer() async throws -> String
    func acceptAnswer(_ sdp: String) async throws
    func playReadyCue(character: DirectFaceSkin, sound: DirectReadySound) async
    func setInputMuted(_ muted: Bool) -> Bool
    func close()
}

@MainActor
protocol DirectNativeVoiceMediaCreating: AnyObject {
    func makeSession() throws -> any DirectNativeVoiceMediaControlling
}

@MainActor
final class DirectNativeWebRTCSessionFactory: DirectNativeVoiceMediaCreating {
    func makeSession() throws -> any DirectNativeVoiceMediaControlling {
        try DirectNativeWebRTCSession(configuredForCarPlay: true)
    }
}

/// An audio-only WebRTC peer for the system-hosted CarPlay scene. The App
/// Server still owns authentication, thread selection and the remote answer;
/// this object owns only the car microphone, car playout and SDP peer state.
@MainActor
final class DirectNativeWebRTCSession: NSObject,
    DirectNativeVoiceMediaControlling,
    RTCPeerConnectionDelegate,
    RTCDataChannelDelegate
{
    private static var didInitialiseSSL = false

    private let factory: RTCPeerConnectionFactory
    private let peer: RTCPeerConnection
    private let audioTrack: RTCAudioTrack
    private var eventChannel: RTCDataChannel?
    private var iceContinuation: CheckedContinuation<Void, any Error>?
    private var iceTimeout: Task<Void, Never>?
    private var connectionContinuation: CheckedContinuation<Void, any Error>?
    private var connectionTimeout: Task<Void, Never>?
    private var closed = false
    private let readyCue = DirectVoiceReadyCuePlayer()
    private var didPlayReadyCue = false

    init(configuredForCarPlay: Bool) throws {
        if !Self.didInitialiseSSL {
            RTCInitializeSSL()
            Self.didInitialiseSSL = true
        }

        let webRTCAudio = RTCAudioSessionConfiguration.webRTC()
        webRTCAudio.category = AVAudioSession.Category.playAndRecord.rawValue
        webRTCAudio.mode = AVAudioSession.Mode.default.rawValue
        webRTCAudio.categoryOptions = [.allowBluetoothHFP]
        RTCAudioSessionConfiguration.setWebRTC(webRTCAudio)

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.allowBluetoothHFP]
        )

        let factory = RTCPeerConnectionFactory()
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: ["DtlsSrtpKeyAgreement": "true"]
        )
        guard let peer = factory.peerConnection(
            with: configuration,
            constraints: constraints,
            delegate: nil
        ) else {
            throw DirectNativeWebRTCError.peerUnavailable
        }

        let audioSource = factory.audioSource(
            with: RTCMediaConstraints(
                mandatoryConstraints: nil,
                optionalConstraints: nil
            )
        )
        let audioTrack = factory.audioTrack(
            with: audioSource,
            trackId: "nightblood-carplay-audio"
        )
        // The welcome must not echo into the user's first turn. The model
        // enables this track only after connection and the one-shot cue.
        audioTrack.isEnabled = false
        peer.add(audioTrack, streamIds: ["nightblood-carplay"])

        self.factory = factory
        self.peer = peer
        self.audioTrack = audioTrack
        super.init()
        peer.delegate = self

        let channelConfiguration = RTCDataChannelConfiguration()
        channelConfiguration.isOrdered = true
        eventChannel = peer.dataChannel(
            forLabel: "oai-events",
            configuration: channelConfiguration
        )
        eventChannel?.delegate = self
    }

    func makeOffer() async throws -> String {
        guard !closed else { throw DirectNativeWebRTCError.peerUnavailable }
        try AVAudioSession.sharedInstance().setActive(true)

        let offer = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<RTCSessionDescription, any Error>) in
            peer.offer(
                for: RTCMediaConstraints(
                    mandatoryConstraints: [
                        "OfferToReceiveAudio": "true",
                        "OfferToReceiveVideo": "false",
                    ],
                    optionalConstraints: nil
                )
            ) { description, error in
                if let description {
                    continuation.resume(returning: description)
                } else {
                    continuation.resume(
                        throwing: DirectNativeWebRTCError.offerFailed(
                            error?.localizedDescription ?? "No SDP offer was returned"
                        )
                    )
                }
            }
        }
        try await setLocalDescription(offer)
        try await waitForIceGathering()
        guard let local = peer.localDescription else {
            throw DirectNativeWebRTCError.peerUnavailable
        }
        return local.sdp
    }

    func acceptAnswer(_ sdp: String) async throws {
        guard !closed else { throw DirectNativeWebRTCError.peerUnavailable }
        let answer = RTCSessionDescription(type: .answer, sdp: sdp)
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            peer.setRemoteDescription(answer) { error in
                if let error {
                    continuation.resume(
                        throwing: DirectNativeWebRTCError.answerFailed(
                            error.localizedDescription
                        )
                    )
                } else {
                    continuation.resume()
                }
            }
        }
        try await waitForConnection()
    }

    func playReadyCue(character: DirectFaceSkin, sound: DirectReadySound) async {
        guard !closed, !didPlayReadyCue else { return }
        didPlayReadyCue = true
        await readyCue.play(character: character, sound: sound)
    }

    func setInputMuted(_ muted: Bool) -> Bool {
        guard !closed else { return false }
        audioTrack.isEnabled = !muted
        return audioTrack.isEnabled == !muted
    }

    func close() {
        guard !closed else { return }
        closed = true
        readyCue.stop()
        iceTimeout?.cancel()
        iceTimeout = nil
        if let iceContinuation {
            self.iceContinuation = nil
            iceContinuation.resume(throwing: CancellationError())
        }
        connectionTimeout?.cancel()
        connectionTimeout = nil
        if let connectionContinuation {
            self.connectionContinuation = nil
            connectionContinuation.resume(throwing: CancellationError())
        }
        eventChannel?.delegate = nil
        eventChannel?.close()
        eventChannel = nil
        peer.close()
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    private func setLocalDescription(
        _ description: RTCSessionDescription
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            peer.setLocalDescription(description) { error in
                if let error {
                    continuation.resume(
                        throwing: DirectNativeWebRTCError.localDescriptionFailed(
                            error.localizedDescription
                        )
                    )
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func waitForIceGathering() async throws {
        if peer.iceGatheringState == .complete { return }
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            iceContinuation = continuation
            iceTimeout = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .seconds(10))
                } catch {
                    return
                }
                guard let self, let continuation = self.iceContinuation else {
                    return
                }
                self.iceContinuation = nil
                continuation.resume(
                    throwing: DirectNativeWebRTCError.iceGatheringTimedOut
                )
            }
        }
    }

    private func waitForConnection() async throws {
        if peer.connectionState == .connected { return }
        guard peer.connectionState != .failed,
              peer.connectionState != .closed
        else {
            throw DirectNativeWebRTCError.connectionFailed
        }
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, any Error>) in
            connectionContinuation = continuation
            connectionTimeout = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .seconds(15))
                } catch {
                    return
                }
                guard let self,
                      let continuation = self.connectionContinuation
                else { return }
                self.connectionContinuation = nil
                continuation.resume(
                    throwing: DirectNativeWebRTCError.connectionTimedOut
                )
            }
        }
    }

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange newState: RTCIceGatheringState
    ) {
        guard newState == .complete else { return }
        Task { @MainActor [weak self] in
            guard let self, let continuation = self.iceContinuation else {
                return
            }
            self.iceContinuation = nil
            self.iceTimeout?.cancel()
            self.iceTimeout = nil
            continuation.resume()
        }
    }

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange stateChanged: RTCSignalingState
    ) {}

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didAdd stream: RTCMediaStream
    ) {}

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didRemove stream: RTCMediaStream
    ) {}

    nonisolated func peerConnectionShouldNegotiate(
        _ peerConnection: RTCPeerConnection
    ) {}

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange newState: RTCIceConnectionState
    ) {}

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange newState: RTCPeerConnectionState
    ) {
        Task { @MainActor [weak self] in
            guard let self, let continuation = self.connectionContinuation else {
                return
            }
            switch newState {
            case .connected:
                self.connectionContinuation = nil
                self.connectionTimeout?.cancel()
                self.connectionTimeout = nil
                continuation.resume()
            case .failed, .closed:
                self.connectionContinuation = nil
                self.connectionTimeout?.cancel()
                self.connectionTimeout = nil
                continuation.resume(
                    throwing: DirectNativeWebRTCError.connectionFailed
                )
            default:
                break
            }
        }
    }

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didGenerate candidate: RTCIceCandidate
    ) {}

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didRemove candidates: [RTCIceCandidate]
    ) {}

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didOpen dataChannel: RTCDataChannel
    ) {
        Task { @MainActor [weak self] in
            self?.eventChannel = dataChannel
            self?.eventChannel?.delegate = self
        }
    }

    nonisolated func dataChannelDidChangeState(
        _ dataChannel: RTCDataChannel
    ) {}

    nonisolated func dataChannel(
        _ dataChannel: RTCDataChannel,
        didReceiveMessageWith buffer: RTCDataBuffer
    ) {}
}
