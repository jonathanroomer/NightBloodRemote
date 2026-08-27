@preconcurrency import DeviceCheck
import Foundation
@preconcurrency import UIKit

struct CodexRemoteVoiceApplicationForegroundProvider:
    CodexRemoteVoiceForegroundProviding
{
    func isApplicationActive() async -> Bool {
        await MainActor.run {
            UIApplication.shared.applicationState == .active
        }
    }
}

/// Produces the opaque `v1.` DeviceCheck envelope expected by Codex App
/// Server. The Apple token and the envelope are returned once to the caller
/// and are never written to disk, preferences, logs, or Keychain.
actor CodexRemoteDeviceCheckAttestationProvider:
    CodexRemoteVoiceAttestationProviding
{
    private let appSessionID: String

    init(appSessionID: UUID = UUID()) {
        self.appSessionID = appSessionID.uuidString.lowercased()
    }

    func generateAttestation() async throws -> String {
        #if targetEnvironment(simulator)
        throw CodexRemoteVoiceError.attestationUnavailable
        #else
        let input = await MainActor.run { () -> AttestationInput? in
            guard DCDevice.current.isSupported,
                  let bundleIdentifier = Bundle.main.bundleIdentifier,
                  !bundleIdentifier.isEmpty
            else {
                return nil
            }
            guard let screen = UIApplication.shared.connectedScenes
                .compactMap({ ($0 as? UIWindowScene)?.screen })
                .first
            else {
                return nil
            }
            let languages = Array(Locale.preferredLanguages.prefix(16)).map {
                String($0.prefix(64))
            }
            let localeBase = Locale.current.identifier
                .split(separator: "@", maxSplits: 1)
                .first.map(String.init) ?? "en-GB"
            let locale = String(
                localeBase.replacingOccurrences(of: "_", with: "-").prefix(64)
            )
            let timezone = String(TimeZone.current.identifier.prefix(64))
            let pointSizeSum = max(
                0,
                Int((screen.bounds.width + screen.bounds.height).rounded())
            )
            return AttestationInput(
                bundleIdentifier: bundleIdentifier,
                languages: languages.isEmpty ? ["en-GB"] : languages,
                locale: locale.isEmpty ? "en-GB" : locale,
                timezone: timezone.isEmpty ? "unknown" : timezone,
                screenSizeSum: pointSizeSum,
                screenScale: Double(screen.scale)
            )
        }
        guard let input else {
            throw CodexRemoteVoiceError.attestationUnavailable
        }

        let clock = ContinuousClock()
        let started = clock.now
        let rawToken: Data
        do {
            rawToken = try await withCheckedThrowingContinuation { continuation in
                DCDevice.current.generateToken { data, error in
                    if let data, error == nil {
                        continuation.resume(returning: data)
                    } else {
                        continuation.resume(
                            throwing: CodexRemoteVoiceError.attestationUnavailable
                        )
                    }
                }
            }
        } catch let error as CodexRemoteVoiceError {
            throw error
        } catch {
            throw CodexRemoteVoiceError.attestationUnavailable
        }
        guard !rawToken.isEmpty, rawToken.count <= 32 * 1024 else {
            throw CodexRemoteVoiceError.invalidAttestation
        }
        let elapsed = started.duration(to: clock.now)
        let latencyMilliseconds = Double(elapsed.components.seconds) * 1_000
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
        let opaque = try CodexRemoteDeviceCheckEnvelope.encode(
            rawToken: rawToken,
            input: input,
            appSessionID: appSessionID,
            latencyMilliseconds: max(0, latencyMilliseconds)
        )
        guard opaque.utf8.count >= 128, opaque.utf8.count <= 32 * 1024 else {
            throw CodexRemoteVoiceError.invalidAttestation
        }
        return opaque
        #endif
    }
}

private struct AttestationInput: Sendable {
    let bundleIdentifier: String
    let languages: [String]
    let locale: String
    let timezone: String
    let screenSizeSum: Int
    let screenScale: Double
}

private enum CodexRemoteDeviceCheckEnvelope {
    static func encode(
        rawToken: Data,
        input: AttestationInput,
        appSessionID: String,
        latencyMilliseconds: Double
    ) throws -> String {
        guard input.bundleIdentifier.utf8.count <= 256,
              input.languages.count <= 16,
              input.languages.allSatisfy({ $0.utf8.count <= 64 }),
              input.locale.utf8.count <= 64,
              input.timezone.utf8.count <= 64,
              appSessionID.utf8.count <= 128,
              input.screenSizeSum >= 0,
              input.screenScale.isFinite,
              input.screenScale >= 0,
              latencyMilliseconds.isFinite,
              latencyMilliseconds >= 0
        else {
            throw CodexRemoteVoiceError.invalidAttestation
        }

        let signals = map([
            (unsigned(0), unsigned(1)),
            (unsigned(1), array(input.languages.map(text))),
            (unsigned(2), text(input.locale)),
            (unsigned(3), text(input.timezone)),
            (unsigned(4), unsigned(UInt64(input.screenSizeSum))),
            (unsigned(5), number(input.screenScale)),
            (unsigned(6), text(appSessionID)),
        ])
        let payload = map([
            (text("token"), text(rawToken.base64EncodedString())),
            (text("bundle_id"), text(input.bundleIdentifier)),
            (text("f"), bytes(signals)),
            // voice_backend.py's cborDoublePair always encodes latency as an
            // IEEE-754 double, even when the observed value is integral.
            (text("t"), double(latencyMilliseconds)),
        ])
        guard payload.count <= 24 * 1024 else {
            throw CodexRemoteVoiceError.invalidAttestation
        }
        return "v1." + base64URL(payload)
    }

    private static func unsigned(_ value: Int) -> Data {
        guard value >= 0 else { return Data() }
        return unsigned(UInt64(value))
    }

    private static func unsigned(_ value: UInt64) -> Data {
        typeAndLength(major: 0, length: value)
    }

    private static func text(_ value: String) -> Data {
        let encoded = Data(value.utf8)
        return typeAndLength(major: 3, length: UInt64(encoded.count)) + encoded
    }

    private static func bytes(_ value: Data) -> Data {
        typeAndLength(major: 2, length: UInt64(value.count)) + value
    }

    private static func array(_ values: [Data]) -> Data {
        values.reduce(
            into: typeAndLength(major: 4, length: UInt64(values.count))
        ) { result, value in
            result.append(value)
        }
    }

    private static func map(_ entries: [(Data, Data)]) -> Data {
        entries.reduce(
            into: typeAndLength(major: 5, length: UInt64(entries.count))
        ) { result, entry in
            result.append(entry.0)
            result.append(entry.1)
        }
    }

    private static func number(_ value: Double) -> Data {
        if value >= 0,
           value <= Double(Int64.max),
           value.rounded(.towardZero) == value
        {
            return unsigned(UInt64(value))
        }
        return double(value)
    }

    private static func double(_ value: Double) -> Data {
        var bits = value.bitPattern.bigEndian
        return Data([0xFB]) + Data(
            bytes: &bits,
            count: MemoryLayout<UInt64>.size
        )
    }

    private static func typeAndLength(major: UInt8, length: UInt64) -> Data {
        let prefix = major << 5
        switch length {
        case 0..<24:
            return Data([prefix | UInt8(length)])
        case 24...UInt64(UInt8.max):
            return Data([prefix | 24, UInt8(length)])
        case (UInt64(UInt8.max) + 1)...UInt64(UInt16.max):
            var encoded = UInt16(length).bigEndian
            return Data([prefix | 25]) + Data(
                bytes: &encoded,
                count: MemoryLayout<UInt16>.size
            )
        case (UInt64(UInt16.max) + 1)...UInt64(UInt32.max):
            var encoded = UInt32(length).bigEndian
            return Data([prefix | 26]) + Data(
                bytes: &encoded,
                count: MemoryLayout<UInt32>.size
            )
        default:
            var encoded = length.bigEndian
            return Data([prefix | 27]) + Data(
                bytes: &encoded,
                count: MemoryLayout<UInt64>.size
            )
        }
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
