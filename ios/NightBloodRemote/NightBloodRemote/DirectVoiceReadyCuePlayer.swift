@preconcurrency import AVFAudio
import Foundation

/// Plays inside the native WebRTC session's existing car-audio route.
/// It never changes or activates AVAudioSession.
@MainActor
final class DirectVoiceReadyCuePlayer: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var completion: CheckedContinuation<Void, Never>?
    private var timeout: Task<Void, Never>?

    /// Generated PCM in memory, with no recordings or sound-library assets.
    static func cueData(character: DirectFaceSkin, sound: DirectReadySound) -> Data {
        let rate = 16_000
        let count = 3_840
        let frequencies: [Double] = sound == .tone ? [440, 660]
            : character == .nightblood ? [196, 293.66] : [523.25, 659.25]
        var data = Data()
        func ascii(_ text: String) { data.append(contentsOf: text.utf8) }
        func u16(_ value: UInt16) {
            data.append(UInt8(value & 255)); data.append(UInt8(value >> 8))
        }
        func u32(_ value: UInt32) {
            u16(UInt16(value & 65535)); u16(UInt16(value >> 16))
        }
        ascii("RIFF"); u32(UInt32(36 + count * 2)); ascii("WAVEfmt ")
        u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2))
        u16(2); u16(16); ascii("data"); u32(UInt32(count * 2))
        for index in 0..<count {
            let time = Double(index) / Double(rate)
            let progress = Double(index) / Double(count - 1)
            let envelope = min(1, progress / 0.08) * min(1, (1 - progress) / 0.35) * 0.22
            let sample = frequencies.reduce(0.0) { $0 + sin(2 * .pi * $1 * time) }
                / Double(frequencies.count)
            u16(UInt16(bitPattern: Int16(sample * envelope * 32_767)))
        }
        return data
    }

    func play(character: DirectFaceSkin, sound: DirectReadySound) async {
        guard completion == nil,
              let audio = try? AVAudioPlayer(data: Self.cueData(character: character, sound: sound))
        else { return }
        audio.volume = sound == .character ? 0.72 : 1
        audio.delegate = self
        player = audio
        await withCheckedContinuation { continuation in
            completion = continuation
            // A missing or failed cue must not strand a connected session.
            timeout = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .seconds(min(5, audio.duration + 0.5)))
                } catch { return }
                self?.stop()
            }
            if !audio.play() { stop() }
        }
    }

    func stop() {
        timeout?.cancel()
        timeout = nil
        player?.stop()
        player?.delegate = nil
        player = nil
        let pending = completion
        completion = nil
        pending?.resume()
    }

    nonisolated func audioPlayerDidFinishPlaying(
        _ player: AVAudioPlayer, successfully flag: Bool
    ) {
        Task { @MainActor [weak self] in
            guard self?.player === player else { return }
            self?.stop()
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(
        _ player: AVAudioPlayer, error: (any Error)?
    ) {
        Task { @MainActor [weak self] in
            guard self?.player === player else { return }
            self?.stop()
        }
    }
}
