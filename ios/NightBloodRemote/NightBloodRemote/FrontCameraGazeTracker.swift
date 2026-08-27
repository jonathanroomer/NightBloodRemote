@preconcurrency import ARKit
import Foundation
import simd

struct GazeSample: Sendable {
    let present: Bool
    let x: Float
    let y: Float
    let distance: Float
    let yaw: Float
    let pitch: Float

    static let absent = GazeSample(
        present: false,
        x: 0,
        y: 0,
        distance: 1,
        yaw: 0,
        pitch: 0
    )

    var bridgePayload: [String: Any] {
        [
            "present": present,
            "x": x,
            "y": y,
            "distance": distance,
            "yaw": yaw,
            "pitch": pitch,
        ]
    }
}

/// Converts the front TrueDepth camera into a tiny, frame-free gaze contract.
/// ARKit processes camera frames locally; only these six numbers reach WebGL.
@MainActor
final class FrontCameraGazeTracker: NSObject, @preconcurrency ARSessionDelegate {
    var onSample: ((GazeSample) -> Void)?

    private let session = ARSession()
    private var requested = false
    private var lastFaceAt = 0.0
    private var lastPublishedAt = 0.0
    private var lastWasPresent = false
    private var staleTimer: Timer?

    override init() {
        super.init()
        session.delegate = self
        // ARSession defaults to the main queue when this is nil. State and the
        // WKWebView bridge are main-actor owned, so make that boundary explicit.
        session.delegateQueue = .main
    }

    func start() {
        requested = true
        guard ARFaceTrackingConfiguration.isSupported else {
            publish(.absent)
            return
        }
        let configuration = ARFaceTrackingConfiguration()
        configuration.maximumNumberOfTrackedFaces = 1
        configuration.isLightEstimationEnabled = false
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        installStaleTimer()
        publish(.absent)
    }

    func pause() {
        requested = false
        staleTimer?.invalidate()
        staleTimer = nil
        session.pause()
        publish(.absent)
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        consume(anchors)
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        consume(anchors)
    }

    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        if anchors.contains(where: { $0 is ARFaceAnchor }) {
            publish(.absent)
        }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        publish(.absent)
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        if requested {
            start()
        }
    }

    func session(_ session: ARSession, didFailWithError error: any Error) {
        publish(.absent)
    }

    private func consume(_ anchors: [ARAnchor]) {
        guard requested,
              let face = anchors.compactMap({ $0 as? ARFaceAnchor }).first,
              face.isTracked else {
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        lastFaceAt = now
        guard now - lastPublishedAt >= 1.0 / 24.0 else { return }
        lastPublishedAt = now
        publish(Self.sample(from: face))
    }

    private func publish(_ sample: GazeSample) {
        lastWasPresent = sample.present
        onSample?(sample)
    }

    private func installStaleTimer() {
        staleTimer?.invalidate()
        staleTimer = Timer.scheduledTimer(
            timeInterval: 0.25,
            target: self,
            selector: #selector(checkForStaleFace),
            userInfo: nil,
            repeats: true
        )
    }

    @objc private func checkForStaleFace() {
        guard lastWasPresent else { return }
        if ProcessInfo.processInfo.systemUptime - lastFaceAt > 0.65 {
            publish(.absent)
        }
    }

    private static func sample(from face: ARFaceAnchor) -> GazeSample {
        let transform = face.transform
        let translation = transform.columns.3
        let look = face.lookAtPoint
        let lookDepth = max(0.12, abs(look.z))

        // Head position provides the steady target; TrueDepth eye pose adds a
        // smaller movement when the user looks across the screen without
        // moving his whole head. The existing face director smooths this again.
        let headX = translation.x / 0.35
        let headY = translation.y / 0.42
        let eyeX = look.x / lookDepth
        let eyeY = look.y / lookDepth
        let x = clamp(headX + eyeX * 0.55, lower: -1, upper: 1)
        let y = clamp(headY + eyeY * 0.45, lower: -1, upper: 1)

        let zAxis = transform.columns.2
        var yaw = atan2(zAxis.x, zAxis.z) * 180 / .pi
        // Some ARKit coordinate orientations face down -Z. Fold that equally
        // valid representation back around zero, where facing the phone lives.
        if yaw > 90 { yaw -= 180 }
        if yaw < -90 { yaw += 180 }
        let pitch = atan2(
            -zAxis.y,
            sqrt(zAxis.x * zAxis.x + zAxis.z * zAxis.z)
        ) * 180 / .pi

        let metres = abs(translation.z)
        let distance = clamp((metres - 0.22) / 0.58, lower: 0, upper: 1)
        return GazeSample(
            present: true,
            // ARKit reports the front-camera image in camera space, while the
            // shared face director expects the viewer-facing (mirror) space
            // used by the original physical display. Flip only the iPhone
            // source so moving left or right makes NightBlood follow in the
            // same visible direction without changing the Pi face contract.
            x: -x,
            y: y,
            distance: distance,
            yaw: yaw,
            pitch: pitch
        )
    }

    private static func clamp(_ value: Float, lower: Float, upper: Float) -> Float {
        min(upper, max(lower, value))
    }
}
