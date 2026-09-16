import Foundation
import OSLog
import UIKit

/// A bounded, non-sensitive launch trace that survives the drive back to the
/// Mac. It records only lifecycle names, coarse UI state and timestamps—never
/// credentials, account identifiers, pairing values or transcript content.
@MainActor
enum NightBloodCarPlayDiagnostics {
    private struct Event: Codable {
        let occurredAt: Date
        let name: String
        let detail: String
        let applicationState: Int
        let sceneSummary: String
    }

    private static let logger = Logger(
        subsystem: "com.example.nightblood.remote",
        category: "CarPlayLifecycle"
    )
    private static let storageKey = "nightblood.carplay.lifecycle-events.v1"
    private static let maximumEventCount = 80

    static func record(_ name: String, detail: String = "") {
        let boundedName = String(name.prefix(80))
        let boundedDetail = String(detail.prefix(160))
        let sceneSummary = UIApplication.shared.connectedScenes
            .map { scene in
                "\(scene.session.role.rawValue):\(scene.activationState.rawValue)"
            }
            .sorted()
            .joined(separator: ",")
        let event = Event(
            occurredAt: Date(),
            name: boundedName,
            detail: boundedDetail,
            applicationState: UIApplication.shared.applicationState.rawValue,
            sceneSummary: String(sceneSummary.prefix(240))
        )
        var events = loadEvents()
        events.append(event)
        if events.count > maximumEventCount {
            events.removeFirst(events.count - maximumEventCount)
        }
        if let encoded = try? JSONEncoder().encode(events) {
            UserDefaults.standard.set(encoded, forKey: storageKey)
        }
        logger.notice(
            "event=\(boundedName, privacy: .public) detail=\(boundedDetail, privacy: .public) appState=\(event.applicationState, privacy: .public) scenes=\(event.sceneSummary, privacy: .public)"
        )
    }

    static func renderedTrace() -> String {
        let formatter = ISO8601DateFormatter()
        return loadEvents().map { event in
            let detail = event.detail.isEmpty ? "" : " \(event.detail)"
            let scenes = event.sceneSummary.isEmpty
                ? "no-scenes" : event.sceneSummary
            return "\(formatter.string(from: event.occurredAt)) "
                + "\(event.name)\(detail) app=\(event.applicationState) "
                + "scenes=\(scenes)"
        }.joined(separator: "\n")
    }

    private static func loadEvents() -> [Event] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let events = try? JSONDecoder().decode([Event].self, from: data)
        else {
            return []
        }
        return events
    }
}
