import Foundation

enum DirectCharacterPromptStore {
    static func load(
        for character: DirectFaceSkin,
        bundle: Bundle = .main
    ) throws -> CodexRemoteVoicePrompt {
        guard let url = bundle.url(
            forResource: character.personalityResourceName,
            withExtension: "txt"
        ),
        let data = try? Data(contentsOf: url),
        let text = String(data: data, encoding: .utf8)
        else {
            throw CodexRemoteVoiceError.invalidPrompt
        }
        return try CodexRemoteVoicePrompt(validating: text)
    }
}

private extension DirectFaceSkin {
    var personalityResourceName: String {
        switch self {
        case .nightblood: "NightBlood"
        case .marshmallow: "Marshmallow"
        }
    }
}
