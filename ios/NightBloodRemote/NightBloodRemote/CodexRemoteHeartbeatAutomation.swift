import Foundation

enum CodexRemoteHeartbeatAutomationError: Error, LocalizedError, Equatable {
    case invalidArguments(String)
    case unsupportedSchedule
    case duplicateHeartbeat
    case storeUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let detail):
            "The heartbeat request was invalid: \(detail)"
        case .unsupportedSchedule:
            "That heartbeat schedule is not supported by NightBlood yet."
        case .duplicateHeartbeat:
            "This task already has an active heartbeat. Update or delete it before creating another."
        case .storeUnavailable:
            "The Codex automation store could not be checked safely."
        }
    }
}

struct CodexRemoteHeartbeatAutomation: Equatable, Sendable {
    static let maximumAutomationEntries = 128
    static let maximumAutomationFileBytes = 64 * 1024

    let id: String
    let name: String
    let prompt: String
    let rrule: String
    let targetThreadID: String
    let notificationPolicy: String?
    let createdAtMilliseconds: Int64

    struct DeletionSnapshot: Equatable, Sendable {
        let id: String
        let name: String
        let rrule: String
    }

    enum DeletionLookup: Equatable, Sendable {
        case owned(DeletionSnapshot)
        case notFound(id: String)
    }

    var toml: String {
        var lines = [
            "version = 1",
            "id = \(Self.tomlString(id))",
            "kind = \"heartbeat\"",
            "name = \(Self.tomlString(name))",
            "prompt = \(Self.tomlString(prompt))",
            "status = \"ACTIVE\"",
            "rrule = \(Self.tomlString(rrule))",
        ]
        if let notificationPolicy {
            lines.append(
                "notification_policy = \(Self.tomlString(notificationPolicy))"
            )
        }
        lines.append("target_thread_id = \(Self.tomlString(targetThreadID))")
        lines.append("created_at = \(createdAtMilliseconds)")
        lines.append("updated_at = \(createdAtMilliseconds)")
        return lines.joined(separator: "\n") + "\n"
    }

    static func make(
        arguments: [String: CodexRemoteVoiceJSON],
        targetThreadID: String,
        existingIDs: Set<String>,
        existingAutomationFiles: [String],
        createdAtMilliseconds: Int64,
        fallbackUUID: UUID
    ) throws -> Self {
        let allowedKeys: Set<String> = [
            "destination",
            "kind",
            "mode",
            "name",
            "notificationPolicy",
            "prompt",
            "rrule",
            "status",
            "targetThreadId",
        ]
        guard Set(arguments.keys).isSubset(of: allowedKeys) else {
            throw CodexRemoteHeartbeatAutomationError.invalidArguments(
                "unexpected fields"
            )
        }
        guard arguments["mode"]?.stringValue == "create",
              arguments["kind"]?.stringValue == "heartbeat"
        else {
            throw CodexRemoteHeartbeatAutomationError.invalidArguments(
                "only heartbeat creation is available in Voice"
            )
        }
        if let destination = arguments["destination"]?.stringValue,
           destination != "thread"
        {
            throw CodexRemoteHeartbeatAutomationError.invalidArguments(
                "the heartbeat must target this task"
            )
        }
        if let requestedTarget = arguments["targetThreadId"]?.stringValue,
           requestedTarget != targetThreadID
        {
            throw CodexRemoteHeartbeatAutomationError.invalidArguments(
                "the target task changed"
            )
        }
        if let status = arguments["status"]?.stringValue,
           status != "ACTIVE"
        {
            throw CodexRemoteHeartbeatAutomationError.invalidArguments(
                "new Voice heartbeats must start active"
            )
        }
        guard !targetThreadID.isEmpty,
              targetThreadID.utf8.count <= 1_024,
              !targetThreadID.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              })
        else {
            throw CodexRemoteHeartbeatAutomationError.invalidArguments(
                "invalid target task"
            )
        }

        let name = try boundedString(
            arguments["name"],
            field: "name",
            maximumBytes: 256
        )
        let prompt = try boundedString(
            arguments["prompt"],
            field: "prompt",
            maximumBytes: 16 * 1024
        )
        let rawRRule = try boundedString(
            arguments["rrule"],
            field: "schedule",
            maximumBytes: 512
        )
        let rrule = try normalisedRRule(rawRRule)

        let notificationPolicy: String?
        if let value = arguments["notificationPolicy"] {
            switch value {
            case .null:
                notificationPolicy = nil
            case .string("failed_runs_only"):
                notificationPolicy = "failed_runs_only"
            default:
                throw CodexRemoteHeartbeatAutomationError.invalidArguments(
                    "invalid notification policy"
                )
            }
        } else {
            notificationPolicy = nil
        }

        guard !existingAutomationFiles.contains(where: {
            activeHeartbeatTarget(in: $0) == targetThreadID
        }) else {
            throw CodexRemoteHeartbeatAutomationError.duplicateHeartbeat
        }

        return Self(
            id: availableID(
                for: name,
                existingIDs: existingIDs,
                fallbackUUID: fallbackUUID
            ),
            name: name,
            prompt: prompt,
            rrule: rrule,
            targetThreadID: targetThreadID,
            notificationPolicy: notificationPolicy,
            createdAtMilliseconds: createdAtMilliseconds
        )
    }

    static func activeHeartbeatTarget(in toml: String) -> String? {
        let values = stringValues(in: toml)
        guard values["kind"] == "heartbeat",
              values["status"] == "ACTIVE"
        else {
            return nil
        }
        return values["target_thread_id"]
    }

    static func deletionLookup(
        arguments: [String: CodexRemoteVoiceJSON],
        targetThreadID: String,
        existingIDs: Set<String>,
        filesByID: [String: String]
    ) throws -> DeletionLookup {
        let allowedKeys: Set<String> = [
            "automationId", "heartbeatId", "id", "kind", "mode", "targetId",
        ]
        let identifiers = ["id", "automationId", "heartbeatId", "targetId"]
            .compactMap { arguments[$0]?.stringValue }
        guard Set(arguments.keys).isSubset(of: allowedKeys),
              arguments["mode"]?.stringValue == "delete",
              arguments["kind"]?.stringValue == nil
                || arguments["kind"]?.stringValue == "heartbeat",
              let id = identifiers.first,
              identifiers.allSatisfy({ $0 == id }),
              validID(id)
        else {
            throw CodexRemoteHeartbeatAutomationError.invalidArguments(
                "heartbeat cancellation requires its automation id"
            )
        }
        guard existingIDs.contains(id) else { return .notFound(id: id) }
        guard let toml = filesByID[id] else {
            throw CodexRemoteHeartbeatAutomationError.storeUnavailable
        }
        let values = stringValues(in: toml)
        guard values["id"] == id,
              values["kind"] == "heartbeat",
              values["target_thread_id"] == targetThreadID,
              let name = values["name"],
              !name.isEmpty,
              name.utf8.count <= 256,
              let rrule = values["rrule"],
              !rrule.isEmpty,
              rrule.utf8.count <= 512
        else {
            throw CodexRemoteHeartbeatAutomationError.invalidArguments(
                "the heartbeat does not belong to this Voice task"
            )
        }
        return .owned(
            DeletionSnapshot(id: id, name: name, rrule: rrule)
        )
    }

    private static func stringValues(in toml: String) -> [String: String] {
        var values: [String: String] = [:]
        for rawLine in toml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty,
                  !line.hasPrefix("#"),
                  let separator = line.firstIndex(of: "=")
            else {
                continue
            }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
            guard let decoded = decodeTOMLString(value) else { continue }
            values[key] = decoded
        }
        return values
    }

    private static func validID(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 128
            && value.unicodeScalars.allSatisfy {
                ($0.value >= 97 && $0.value <= 122)
                    || ($0.value >= 48 && $0.value <= 57)
                    || $0.value == 45
            }
    }

    static func normalisedRRule(_ value: String) throws -> String {
        var fields: [String: String] = [:]
        for component in value.uppercased().split(
            separator: ";",
            omittingEmptySubsequences: false
        ) {
            let parts = component.split(
                separator: "=",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard parts.count == 2 else {
                throw CodexRemoteHeartbeatAutomationError.unsupportedSchedule
            }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let fieldValue = parts[1].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, !fieldValue.isEmpty, fields[key] == nil else {
                throw CodexRemoteHeartbeatAutomationError.unsupportedSchedule
            }
            fields[key] = fieldValue
        }

        guard let frequency = fields["FREQ"] else {
            throw CodexRemoteHeartbeatAutomationError.unsupportedSchedule
        }
        let interval = try positiveInteger(fields["INTERVAL"] ?? "1", maximum: 31_536_000)
        let allowedKeys: Set<String>
        switch frequency {
        case "SECONDLY":
            allowedKeys = ["FREQ", "INTERVAL"]
            guard interval >= 30 else {
                throw CodexRemoteHeartbeatAutomationError.unsupportedSchedule
            }
        case "MINUTELY":
            allowedKeys = ["FREQ", "INTERVAL"]
        case "HOURLY":
            allowedKeys = ["FREQ", "INTERVAL", "BYMINUTE"]
            if let minute = fields["BYMINUTE"] {
                _ = try integer(minute, range: 0...59)
            }
        case "DAILY":
            allowedKeys = ["FREQ", "INTERVAL", "BYHOUR", "BYMINUTE"]
            try validateTimeFields(fields)
        case "WEEKLY":
            allowedKeys = [
                "FREQ", "INTERVAL", "BYDAY", "BYHOUR", "BYMINUTE",
            ]
            guard let days = fields["BYDAY"] else {
                throw CodexRemoteHeartbeatAutomationError.unsupportedSchedule
            }
            let validDays: Set<String> = ["MO", "TU", "WE", "TH", "FR", "SA", "SU"]
            let requestedDays = days.split(separator: ",").map(String.init)
            guard !requestedDays.isEmpty,
                  Set(requestedDays).count == requestedDays.count,
                  requestedDays.allSatisfy(validDays.contains)
            else {
                throw CodexRemoteHeartbeatAutomationError.unsupportedSchedule
            }
            try validateTimeFields(fields)
        default:
            throw CodexRemoteHeartbeatAutomationError.unsupportedSchedule
        }
        guard Set(fields.keys).isSubset(of: allowedKeys) else {
            throw CodexRemoteHeartbeatAutomationError.unsupportedSchedule
        }

        var components = ["FREQ=\(frequency)"]
        if fields["INTERVAL"] != nil || interval != 1 {
            components.append("INTERVAL=\(interval)")
        }
        if let days = fields["BYDAY"] {
            components.append("BYDAY=\(days)")
        }
        if let hour = fields["BYHOUR"] {
            components.append("BYHOUR=\(try integer(hour, range: 0...23))")
        }
        if let minute = fields["BYMINUTE"] {
            components.append("BYMINUTE=\(try integer(minute, range: 0...59))")
        }
        return components.joined(separator: ";")
    }

    private static func boundedString(
        _ value: CodexRemoteVoiceJSON?,
        field: String,
        maximumBytes: Int
    ) throws -> String {
        guard let string = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !string.isEmpty,
              string.utf8.count <= maximumBytes,
              !string.unicodeScalars.contains(where: { $0.value == 0 })
        else {
            throw CodexRemoteHeartbeatAutomationError.invalidArguments(field)
        }
        return string
    }

    private static func validateTimeFields(_ fields: [String: String]) throws {
        let hasHour = fields["BYHOUR"] != nil
        let hasMinute = fields["BYMINUTE"] != nil
        guard hasHour == hasMinute else {
            throw CodexRemoteHeartbeatAutomationError.unsupportedSchedule
        }
        if let hour = fields["BYHOUR"] {
            _ = try integer(hour, range: 0...23)
        }
        if let minute = fields["BYMINUTE"] {
            _ = try integer(minute, range: 0...59)
        }
    }

    private static func positiveInteger(
        _ value: String,
        maximum: Int
    ) throws -> Int {
        try integer(value, range: 1...maximum)
    }

    private static func integer(
        _ value: String,
        range: ClosedRange<Int>
    ) throws -> Int {
        guard !value.isEmpty,
              value.allSatisfy(\.isNumber),
              let result = Int(value),
              range.contains(result)
        else {
            throw CodexRemoteHeartbeatAutomationError.unsupportedSchedule
        }
        return result
    }

    private static func availableID(
        for name: String,
        existingIDs: Set<String>,
        fallbackUUID: UUID
    ) -> String {
        let generatedSlug = Self.slug(name)
        let base = generatedSlug.isEmpty ? "automation" : generatedSlug
        if !existingIDs.contains(base) { return base }
        for suffix in 2...20 {
            let candidate = "\(base)-\(suffix)"
            if !existingIDs.contains(candidate) { return candidate }
        }
        return "\(base)-\(fallbackUUID.uuidString.lowercased().prefix(8))"
    }

    private static func slug(_ value: String) -> String {
        let lowercased = value.lowercased()
        var output = ""
        var needsDash = false
        for scalar in lowercased.unicodeScalars {
            if (scalar.value >= 97 && scalar.value <= 122)
                || (scalar.value >= 48 && scalar.value <= 57)
            {
                if needsDash, !output.isEmpty { output.append("-") }
                output.unicodeScalars.append(scalar)
                needsDash = false
            } else if !output.isEmpty {
                needsDash = true
            }
        }
        return String(output.prefix(96)).trimmingCharacters(
            in: CharacterSet(charactersIn: "-")
        )
    }

    private static func tomlString(_ value: String) -> String {
        var output = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x08: output += "\\b"
            case 0x09: output += "\\t"
            case 0x0A: output += "\\n"
            case 0x0C: output += "\\f"
            case 0x0D: output += "\\r"
            case 0x22: output += "\\\""
            case 0x5C: output += "\\\\"
            case 0x00...0x1F, 0x7F:
                output += String(format: "\\u%04X", scalar.value)
            default:
                output.unicodeScalars.append(scalar)
            }
        }
        output += "\""
        return output
    }

    private static func decodeTOMLString(_ value: String) -> String? {
        guard value.hasPrefix("\""), value.hasSuffix("\"") else { return nil }
        return try? JSONDecoder().decode(String.self, from: Data(value.utf8))
    }
}
