@preconcurrency import AVFAudio
import Foundation

@MainActor
protocol DirectVoiceBackgroundAudioConfiguring: AnyObject {
    func configureForVoice() throws
}

/// Declares the app's full-duplex background-audio intent without activating
/// or owning the audio session. WebKit remains the sole media owner and
/// activates this configuration when its user-authorised getUserMedia call
/// starts the established WebRTC conversation.
@MainActor
final class DirectVoiceBackgroundAudioController:
    DirectVoiceBackgroundAudioConfiguring
{
    func configureForVoice() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetoothHFP]
        )
        #if DEBUG
        print(
            "NightBloodAudio configured category=\(session.category.rawValue) "
                + "mode=\(session.mode.rawValue) activeOwner=WebKit"
        )
        #endif
    }
}
