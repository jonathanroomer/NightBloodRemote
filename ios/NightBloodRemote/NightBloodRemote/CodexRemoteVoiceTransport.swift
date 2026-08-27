import Foundation

private enum CodexRemoteVoiceAppServerMethod: String, Sendable {
    case initialize
    case initialized
    case fsCreateDirectory = "fs/createDirectory"
    case fsReadDirectory = "fs/readDirectory"
    case fsReadFile = "fs/readFile"
    case fsRemove = "fs/remove"
    case fsWriteFile = "fs/writeFile"
    case resume = "thread/resume"
    case threadRead = "thread/read"
    case threadStart = "thread/start"
    case threadSetName = "thread/name/set"
    case turnStart = "turn/start"
    case realtimeStart = "thread/realtime/start"
    case realtimeStop = "thread/realtime/stop"

    static let allowed: Set<String> = [
        "initialize",
        "initialized",
        "fs/createDirectory",
        "fs/readDirectory",
        "fs/readFile",
        "fs/remove",
        "fs/writeFile",
        "thread/resume",
        "thread/read",
        "thread/start",
        "thread/name/set",
        "turn/start",
        "thread/realtime/start",
        "thread/realtime/stop",
    ]
}

private struct CodexRemoteVoiceChunkAssembly: Sendable {
    let segmentCount: Int
    let messageSizeBytes: Int
    var chunks: [Data?]
    var receivedBytes: Int
}

enum CodexRemoteVoiceServerRequestRoute: Equatable, Sendable {
    case deviceAttestation
    case heartbeatAutomation
    case nativeProjectList
    case nativeThreadCreate
    case nativeThreadRead
    case nativeThreadWait
    case unsupportedVoiceDynamicTool
    case desktopDynamicTool
    case reject
}

func codexRemoteVoiceServerRequestRoute(
    method: String,
    params: [String: CodexRemoteVoiceJSON],
    threadID: String?
) -> CodexRemoteVoiceServerRequestRoute {
    if method == "attestation/generate" {
        return .deviceAttestation
    }
    guard method == "item/tool/call",
          let tool = params["tool"]?.stringValue,
          !tool.isEmpty
    else {
        return .reject
    }
    guard params["threadId"]?.stringValue == threadID else {
        // App Server can broadcast requests for another Desktop task over the
        // same controller channel. Those remain owned by Codex Desktop.
        return .desktopDynamicTool
    }
    if tool == "automation_update" {
        return .heartbeatAutomation
    }
    if tool == "list_projects" {
        return .nativeProjectList
    }
    if tool == "create_thread" {
        return .nativeThreadCreate
    }
    if tool == "read_thread" {
        return .nativeThreadRead
    }
    if tool == "wait_threads" {
        return .nativeThreadWait
    }
    return .unsupportedVoiceDynamicTool
}

func codexRemoteRealtimeStartParameters(
    threadID: String,
    sdpOffer: String,
    voice: CodexRemoteVoiceName,
    prompt: CodexRemoteVoicePrompt,
    realtimeSessionID: UUID
) -> CodexRemoteVoiceJSON {
    .object([
        "threadId": .string(threadID),
        "outputModality": .string(CodexRemoteVoiceConstants.outputModality),
        "version": .string(CodexRemoteVoiceConstants.version),
        "model": .string(CodexRemoteVoiceConstants.model),
        "realtimeSessionId": .string(
            realtimeSessionID.uuidString.lowercased()
        ),
        "voice": .string(voice.rawValue),
        "prompt": .string(prompt.text),
        // A fresh WebRTC conversation must begin by listening. The backing
        // Codex task remains persistent for tools and delegated work, but its
        // previous turn must never be injected as something for the live
        // voice to continue or answer on connection.
        "includeStartupContext": .bool(false),
        // App Server already persists the live v3 transcript. Flushing its
        // cumulative tail at stop writes the same conversation into the Codex
        // task a second time and adds a synthetic handoff acknowledgement.
        "flushTranscriptTailOnSessionEnd": .bool(false),
        "initialItems": .array([]),
        "transport": .object([
            "type": .string("webrtc"),
            "sdp": .string(sdpOffer),
        ]),
    ])
}

private struct CodexRemoteVoiceSourceContext: Sendable {
    let cwd: String
    let runtimeWorkspaceRoots: [String]
    let approvalPolicy: CodexRemoteVoiceJSON
    let approvalsReviewer: CodexRemoteVoiceJSON
    let permissionProfileID: String?
    let sandboxMode: String?
    let serviceTier: String?

    init(resumeResponse: CodexRemoteVoiceJSON) throws {
        guard let object = resumeResponse.objectValue,
              let cwd = object["cwd"]?.stringValue,
              Self.isSafeAbsolutePath(cwd),
              let approvalPolicy = object["approvalPolicy"],
              let approvalsReviewer = object["approvalsReviewer"]
        else {
            throw CodexRemoteVoiceError.malformedRemoteMessage
        }
        let roots = object["runtimeWorkspaceRoots"]?.arrayValue ?? []
        guard roots.count <= 64 else {
            throw CodexRemoteVoiceError.malformedRemoteMessage
        }
        let rootPaths = try roots.map { value in
            guard let path = value.stringValue,
                  Self.isSafeAbsolutePath(path)
            else {
                throw CodexRemoteVoiceError.malformedRemoteMessage
            }
            return path
        }
        let profileID = object["activePermissionProfile"]?.objectValue?["id"]?
            .stringValue
        if let profileID,
           profileID.isEmpty || profileID.utf8.count > 256
        {
            throw CodexRemoteVoiceError.malformedRemoteMessage
        }
        let sandboxType = object["sandbox"]?.objectValue?["type"]?.stringValue
        let sandboxMode: String?
        switch sandboxType {
        case "readOnly": sandboxMode = "read-only"
        case "workspaceWrite": sandboxMode = "workspace-write"
        case "dangerFullAccess": sandboxMode = "danger-full-access"
        case "externalSandbox": sandboxMode = nil
        case nil: sandboxMode = nil
        default: throw CodexRemoteVoiceError.malformedRemoteMessage
        }
        let serviceTier = object["serviceTier"]?.stringValue
        if let serviceTier,
           serviceTier.isEmpty || serviceTier.utf8.count > 128
        {
            throw CodexRemoteVoiceError.malformedRemoteMessage
        }
        self.cwd = cwd
        self.runtimeWorkspaceRoots = rootPaths
        self.approvalPolicy = approvalPolicy
        self.approvalsReviewer = approvalsReviewer
        self.permissionProfileID = profileID
        self.sandboxMode = sandboxMode
        self.serviceTier = serviceTier
    }

    private static func isSafeAbsolutePath(_ value: String) -> Bool {
        value.hasPrefix("/")
            && value.utf8.count <= 4_096
            && !value.unicodeScalars.contains(where: { $0.value == 0 })
    }
}

struct CodexRemoteVoiceNativeCreateThreadRequest: Equatable, Sendable {
    static var configuredProjectID: String {
        guard let raw = Bundle.main.object(
            forInfoDictionaryKey: "CodexProjectID"
        ) as? String else {
            return ""
        }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.hasPrefix("$(") else { return "" }
        return value
    }
    static let allowedThinking: Set<String> = [
        "none", "minimal", "low", "medium", "high", "xhigh", "max",
        "ultra",
    ]

    let prompt: String
    let title: String?
    let model: String?
    let thinking: String?

    init(
        params: [String: CodexRemoteVoiceJSON],
        expectedThreadID: String,
        allowedProjectID: String = Self.configuredProjectID
    ) throws {
        guard !allowedProjectID.isEmpty,
              params["threadId"]?.stringValue == expectedThreadID,
              let arguments = params["arguments"]?.objectValue,
              Set(arguments.keys).isSubset(of: [
                  "prompt", "title", "target", "model", "thinking",
              ]),
              let prompt = arguments["prompt"]?.stringValue,
              !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              prompt.utf8.count <= 32 * 1_024,
              let target = arguments["target"]?.objectValue,
              Set(target.keys) == ["type", "projectId", "environment"],
              target["type"]?.stringValue == "project",
              target["projectId"]?.stringValue == allowedProjectID,
              let environment = target["environment"]?.objectValue,
              Set(environment.keys) == ["type"],
              environment["type"]?.stringValue == "local"
        else {
            throw CodexRemoteVoiceError.appServerRejected(
                "NightBlood Voice can currently create only a local task in the NightBlood project."
            )
        }

        let title = arguments["title"]?.stringValue
        if let title,
           title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || title.utf8.count > 512
        {
            throw CodexRemoteVoiceError.appServerRejected(
                "The requested task title is invalid."
            )
        }
        let model = arguments["model"]?.stringValue
        if let model,
           model.isEmpty || model.utf8.count > 128
        {
            throw CodexRemoteVoiceError.appServerRejected(
                "The requested Codex model is invalid."
            )
        }
        let thinking = arguments["thinking"]?.stringValue
        if let thinking,
           !Self.allowedThinking.contains(thinking)
        {
            throw CodexRemoteVoiceError.appServerRejected(
                "The requested Codex reasoning effort is invalid."
            )
        }
        self.prompt = prompt
        self.title = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model
        self.thinking = thinking
    }

    var fingerprint: String {
        [prompt, title ?? "", model ?? "", thinking ?? ""]
            .map { "\($0.utf8.count):\($0)" }
            .joined(separator: "|")
    }
}

private struct CodexRemoteVoiceNativeThreadReadRequest: Sendable {
    let threadID: String
    let turnLimit: Int
    let timeoutSeconds: TimeInterval

    init(
        params: [String: CodexRemoteVoiceJSON],
        expectedThreadID: String,
        waitsForCompletion: Bool
    ) throws {
        guard params["threadId"]?.stringValue == expectedThreadID,
              let arguments = params["arguments"]?.objectValue
        else {
            throw CodexRemoteVoiceError.malformedRemoteMessage
        }

        if waitsForCompletion {
            guard Set(arguments.keys).isSubset(of: ["targets", "timeoutMs"]),
                  let targets = arguments["targets"]?.arrayValue,
                  targets.count == 1,
                  let target = targets.first?.objectValue,
                  Set(target.keys).isSubset(of: [
                      "threadId", "hostId", "afterCursor",
                  ]),
                  target["hostId"]?.stringValue == "local",
                  let rawThreadID = target["threadId"]?.stringValue,
                  Self.isCanonicalThreadID(rawThreadID)
            else {
                throw CodexRemoteVoiceError.appServerRejected(
                    "NightBlood Voice can wait only for the local task it just created."
                )
            }
            let timeoutMs = arguments["timeoutMs"]?.integerValue ?? 10_000
            guard timeoutMs >= 0, timeoutMs <= 30_000 else {
                throw CodexRemoteVoiceError.appServerRejected(
                    "The requested task wait is outside NightBlood Voice's bounded limit."
                )
            }
            threadID = rawThreadID.lowercased()
            turnLimit = 3
            timeoutSeconds = TimeInterval(timeoutMs) / 1_000
        } else {
            guard Set(arguments.keys).isSubset(of: [
                "threadId", "hostId", "turnLimit", "includeOutputs",
            ]),
                  arguments["hostId"]?.stringValue == "local",
                  let rawThreadID = arguments["threadId"]?.stringValue,
                  Self.isCanonicalThreadID(rawThreadID)
            else {
                throw CodexRemoteVoiceError.appServerRejected(
                    "NightBlood Voice can read only the local task it just created."
                )
            }
            let requestedLimit = arguments["turnLimit"]?.integerValue ?? 3
            guard requestedLimit > 0, requestedLimit <= 20 else {
                throw CodexRemoteVoiceError.appServerRejected(
                    "The requested task history is outside NightBlood Voice's bounded limit."
                )
            }
            if let includeOutputs = arguments["includeOutputs"],
               includeOutputs.boolValue == nil
            {
                throw CodexRemoteVoiceError.malformedRemoteMessage
            }
            threadID = rawThreadID.lowercased()
            turnLimit = Int(requestedLimit)
            timeoutSeconds = 0
        }
    }

    private static func isCanonicalThreadID(_ value: String) -> Bool {
        value.utf8.count == 36 && UUID(uuidString: value) != nil
    }
}

private struct CodexRemoteVoiceNativeThreadResult: Sendable {
    let first: CodexRemoteVoiceJSON
    let duplicate: CodexRemoteVoiceJSON
}

private actor CodexRemoteVoiceOneShot<Value: Sendable> {
    private var result: Result<Value, CodexRemoteVoiceError>?
    private var waiters: [
        UUID: CheckedContinuation<Value, any Error>
    ] = [:]

    func wait() async throws -> Value {
        if Task.isCancelled {
            throw CodexRemoteVoiceError.cancelled
        }
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if let result {
                    switch result {
                    case .success(let value):
                        continuation.resume(returning: value)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                } else {
                    waiters[waiterID] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel(waiterID) }
        }
    }

    func resolve(_ result: Result<Value, CodexRemoteVoiceError>) {
        guard self.result == nil else { return }
        self.result = result
        let continuations = waiters.values
        waiters.removeAll(keepingCapacity: false)
        for continuation in continuations {
            switch result {
            case .success(let value):
                continuation.resume(returning: value)
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }
    }

    private func cancel(_ waiterID: UUID) {
        waiters.removeValue(forKey: waiterID)?.resume(
            throwing: CodexRemoteVoiceError.cancelled
        )
    }
}

private func codexRemoteVoiceWithTimeout<Value: Sendable>(
    seconds: TimeInterval,
    timeoutError: CodexRemoteVoiceError,
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    guard seconds > 0, seconds.isFinite else {
        throw timeoutError
    }
    return try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask(operation: operation)
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw timeoutError
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else {
            throw timeoutError
        }
        return result
    }
}

/// A single, one-shot, foreground Codex Remote voice connection. Its public
/// surface is intentionally smaller than App Server: callers can connect,
/// start the fixed built-in Voice session for one exact task, stop it once,
/// observe bounded lifecycle state, and close it. There is no raw method or
/// payload API, and no credential is returned to a caller.
actor CodexRemoteVoiceTransport {
    private var account: CodexRemoteAccountContext?
    private let metadata: CodexRemoteEnrolmentMetadata
    private var environmentProvider: (any CodexRemoteVoiceEnvironmentProviding)?
    private var sessionProvider: (any CodexRemoteVoiceControllerSessionProviding)?
    private let webSocketTransport: any CodexRemoteWebSocketTransport
    private var identityProvider: (any CodexRemoteDeviceIdentityProviding)?
    private let attestationProvider: any CodexRemoteVoiceAttestationProviding
    private let foregroundProvider: any CodexRemoteVoiceForegroundProviding
    private let now: @Sendable () -> Date
    private let makeUUID: @Sendable () -> UUID

    private var connection: (any CodexRemoteWebSocketConnection)?
    private var controllerSession: CodexRemoteControllerSession?
    private var environmentID: String?
    private var streamID: String?
    private var codexHome: String?
    private var nextClientSequence: Int64 = 1
    private var nextRequestID: Int64 = 0
    private var lastServerSequence: Int64 = 0
    private var lastPongAt: Date?
    private var pending: [
        String: CodexRemoteVoiceOneShot<CodexRemoteVoiceJSON>
    ] = [:]
    private var chunks: [Int64: CodexRemoteVoiceChunkAssembly] = [:]
    private var attestations: [String] = []
    private var sourceContext: CodexRemoteVoiceSourceContext?

    private var state: CodexRemoteVoiceState = .disconnected
    private var threadID: String?
    private var requestedVoice: CodexRemoteVoiceName?
    private var backingTurnID: String?
    private var sdpAnswer: String?
    private var serverStarted = false
    private var realtimeClosed = false
    private var transportClosed = false
    private var guardTriggered = false
    private var errorDescription: String?
    private var revision: UInt64 = 0
    private var lifecycleGeneration: UInt64 = 0
    private var applicationForeground = true
    private var backgroundSessionContinuation = false
    private var closing = false
    private var startAttempted = false
    private var realtimeStartRequestBegan = false
    private var stopAttempted = false

    private var readiness: CodexRemoteVoiceOneShot<
        CodexRemoteVoiceStartResult
    >?
    private var closedSignal: CodexRemoteVoiceOneShot<Void>?
    private var readerTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var guardTask: Task<Void, Never>?
    private var heartbeatToolTasks: [String: Task<Void, Never>] = [:]
    private var nativeToolTasks: [String: Task<Void, Never>] = [:]
    private var nativeThreadResults: [
        String: CodexRemoteVoiceOneShot<CodexRemoteVoiceNativeThreadResult>
    ] = [:]
    private var nativeCreatedThreadIDs: Set<String> = []
    private var observers: [
        UUID: AsyncStream<CodexRemoteVoiceSnapshot>.Continuation
    ] = [:]

    init(
        account: CodexRemoteAccountContext,
        metadata: CodexRemoteEnrolmentMetadata,
        environmentProvider: any CodexRemoteVoiceEnvironmentProviding,
        sessionProvider: any CodexRemoteVoiceControllerSessionProviding,
        webSocketTransport: any CodexRemoteWebSocketTransport,
        identityProvider: any CodexRemoteDeviceIdentityProviding,
        attestationProvider: any CodexRemoteVoiceAttestationProviding,
        foregroundProvider: any CodexRemoteVoiceForegroundProviding =
            CodexRemoteVoiceApplicationForegroundProvider(),
        now: @escaping @Sendable () -> Date = Date.init,
        makeUUID: @escaping @Sendable () -> UUID = UUID.init
    ) {
        self.account = account
        self.metadata = metadata
        self.environmentProvider = environmentProvider
        self.sessionProvider = sessionProvider
        self.webSocketTransport = webSocketTransport
        self.identityProvider = identityProvider
        self.attestationProvider = attestationProvider
        self.foregroundProvider = foregroundProvider
        self.now = now
        self.makeUUID = makeUUID
    }

    func snapshot() -> CodexRemoteVoiceSnapshot {
        CodexRemoteVoiceSnapshot(
            state: state,
            threadID: threadID,
            backingWorkActive: backingTurnID != nil,
            serverStarted: serverStarted,
            realtimeClosed: realtimeClosed,
            transportClosed: transportClosed,
            guardTriggered: guardTriggered,
            errorDescription: errorDescription,
            revision: revision
        )
    }

    func updates() -> AsyncStream<CodexRemoteVoiceSnapshot> {
        let observerID = makeUUID()
        let pair = AsyncStream<CodexRemoteVoiceSnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(8)
        )
        observers[observerID] = pair.continuation
        pair.continuation.yield(snapshot())
        pair.continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.removeObserver(observerID) }
        }
        return pair.stream
    }

    func connect() async throws {
        guard state == .disconnected, !closing, !transportClosed else {
            throw CodexRemoteVoiceError.alreadyConnected
        }
        let operationGeneration = lifecycleGeneration
        guard applicationForeground else {
            throw CodexRemoteVoiceError.applicationNotActive
        }
        let isActive = await foregroundProvider.isApplicationActive()
        guard isActive else {
            throw CodexRemoteVoiceError.applicationNotActive
        }
        try ensureForegroundOperation(operationGeneration)

        state = .connecting
        errorDescription = nil
        publish()
        var openedConnection: (any CodexRemoteWebSocketConnection)?
        do {
            guard let account,
                  let sessionProvider,
                  let environmentProvider,
                  let identityProvider
            else {
                throw CodexRemoteVoiceError.transportClosed
            }
            let session = try await sessionProvider.controllerSessionForVoice()
            try ensureForegroundOperation(operationGeneration)
            // The environment comes only from the native, durable confirmed
            // pairing record and is re-listed as the final network operation
            // immediately before this socket is constructed.
            let environment = try await environmentProvider
                .confirmedEnvironmentForVoice()
            try ensureForegroundOperation(operationGeneration)
            guard let selectedEnvironmentID = environment.environmentID,
                  !selectedEnvironmentID.isEmpty,
                  selectedEnvironmentID.utf8.count <= 1_024,
                  environment.online == true
            else {
                throw CodexRemoteVoiceError.invalidEnvironment
            }
            let webSocketRequest = try CodexRemoteWebSocketRequestFactory.make(
                account: account,
                metadata: metadata,
                session: session,
                now: now()
            )
            let socket = try await webSocketTransport.open(webSocketRequest)
            openedConnection = socket
            do {
                try ensureForegroundOperation(operationGeneration)
            } catch {
                await socket.close()
                throw error
            }
            let challengeData = try await codexRemoteVoiceWithTimeout(
                seconds: 30,
                timeoutError: .connectionFailed
            ) {
                try await socket.receive()
            }
            try ensureForegroundOperation(operationGeneration)
            guard challengeData.count <= CodexRemoteVoiceConstants
                .maximumWebSocketFrameBytes
            else {
                throw CodexRemoteVoiceError.oversizedWebSocketFrame
            }
            let challenge = try CodexRemoteRelayChallengeSigner.decode(
                challengeData
            )
            let proof = try await CodexRemoteRelayChallengeSigner.sign(
                challenge: challenge,
                account: account,
                metadata: metadata,
                session: session,
                identityProvider: identityProvider,
                authenticationReason:
                    "Use Face ID to open this private NightBlood Voice connection.",
                now: now()
            )
            try ensureForegroundOperation(operationGeneration)
            let proofData = try CodexRemoteRelayChallengeSigner.encode(proof)
            guard proofData.count <= CodexRemoteVoiceConstants
                .maximumWebSocketFrameBytes
            else {
                throw CodexRemoteVoiceError.oversizedWebSocketFrame
            }
            try await socket.send(proofData)
            try ensureForegroundOperation(operationGeneration)

            connection = socket
            controllerSession = session
            environmentID = selectedEnvironmentID
            streamID = makeUUID().uuidString.lowercased()
            lastPongAt = now()
            startReader(using: socket)

            let initializeResponse = try await request(
                .initialize,
                params: .object([
                    "clientInfo": .object([
                        "name": .string("nightblood_remote"),
                        "title": .string("NightBlood Remote"),
                        "version": .string("0.1.0"),
                    ]),
                    "capabilities": .object([
                        "experimentalApi": .bool(true),
                        "requestAttestation": .bool(true),
                    ]),
                ]),
                timeout: 10
            )
            guard let initializeObject = initializeResponse.objectValue,
                  let resolvedCodexHome = initializeObject["codexHome"]?.stringValue,
                  initializeObject["platformFamily"]?.stringValue == "unix",
                  initializeObject["platformOs"]?.stringValue == "macos",
                  resolvedCodexHome.hasPrefix("/"),
                  resolvedCodexHome.utf8.count <= 4_096,
                  !resolvedCodexHome.unicodeScalars.contains(where: {
                      $0.value == 0
                  })
            else {
                throw CodexRemoteVoiceError.malformedRemoteMessage
            }
            codexHome = resolvedCodexHome.hasSuffix("/")
                ? String(resolvedCodexHome.dropLast())
                : resolvedCodexHome
            try ensureForegroundOperation(operationGeneration)
            try await notifyInitialized()
            try ensureForegroundOperation(operationGeneration)
            // OAuth/session-provisioning inputs are no longer needed after the
            // authenticated relay and App Server handshake. Release every
            // transport-owned reference that can retain an ordinary bearer or
            // a signing provider; the short-lived controller token remains
            // only until close/background/failure below.
            self.account = nil
            self.environmentProvider = nil
            self.sessionProvider = nil
            self.identityProvider = nil
            state = .connected
            publish()
            startHeartbeat()
        } catch {
            let voiceError = Self.voiceError(error)
            let invalidated = !isForegroundOperationAuthorised(
                operationGeneration
            )
            if !invalidated {
                state = .failed
                errorDescription = voiceError.localizedDescription
                publish()
            }
            await discardConnectAttempt(openedConnection)
            account = nil
            environmentProvider = nil
            sessionProvider = nil
            identityProvider = nil
            if invalidated {
                throw CodexRemoteVoiceError.applicationNotActive
            }
            throw error
        }
    }

    func start(
        threadID proposedThreadID: String,
        sdpOffer: String,
        voice: CodexRemoteVoiceName,
        prompt: CodexRemoteVoicePrompt,
        timeout: TimeInterval = 60
    ) async throws -> CodexRemoteVoiceStartResult {
        guard state == .connected,
              connection != nil,
              !transportClosed,
              !closing
        else {
            throw CodexRemoteVoiceError.notConnected
        }
        let operationGeneration = lifecycleGeneration
        guard applicationForeground else {
            throw CodexRemoteVoiceError.applicationNotActive
        }
        let isActive = await foregroundProvider.isApplicationActive()
        guard isActive else {
            throw CodexRemoteVoiceError.applicationNotActive
        }
        try ensureForegroundOperation(operationGeneration)
        guard !startAttempted else {
            throw CodexRemoteVoiceError.startAlreadyAttempted
        }
        let canonicalThreadID = try Self.canonicalThreadID(proposedThreadID)
        try Self.validateSDP(sdpOffer)
        guard timeout > 0, timeout.isFinite else {
            throw CodexRemoteVoiceError.invalidSDPOffer
        }

        startAttempted = true
        threadID = canonicalThreadID
        requestedVoice = voice
        state = .preparing
        errorDescription = nil
        sdpAnswer = nil
        serverStarted = false
        realtimeClosed = false
        readiness = CodexRemoteVoiceOneShot<CodexRemoteVoiceStartResult>()
        closedSignal = CodexRemoteVoiceOneShot<Void>()
        publish()

        do {
            try await prepareAttestations(
                operationGeneration: operationGeneration
            )
            try ensureForegroundOperation(operationGeneration)
            state = .starting
            publish()
            let resumeResponse = try await request(
                .resume,
                params: .object([
                    "threadId": .string(canonicalThreadID),
                    "excludeTurns": .bool(true),
                ]),
                timeout: min(timeout, 30)
            )
            sourceContext = try CodexRemoteVoiceSourceContext(
                resumeResponse: resumeResponse
            )
            // Resume can claim the selected task's writer. Never progress from
            // that yield into realtime mutation after a background/close.
            try ensureForegroundOperation(operationGeneration)

            realtimeStartRequestBegan = true
            armSessionGuard()
            _ = try await request(
                .realtimeStart,
                params: codexRemoteRealtimeStartParameters(
                    threadID: canonicalThreadID,
                    sdpOffer: sdpOffer,
                    voice: voice,
                    prompt: prompt,
                    realtimeSessionID: makeUUID()
                ),
                timeout: timeout
            )
            try ensureForegroundOperation(operationGeneration)
            guard let readiness else {
                throw CodexRemoteVoiceError.operationOutcomeUnknown(
                    "Starting Codex Voice"
                )
            }
            let result = try await codexRemoteVoiceWithTimeout(
                seconds: timeout,
                timeoutError: .operationOutcomeUnknown(
                    "Starting Codex Voice"
                )
            ) {
                try await readiness.wait()
            }
            try ensureForegroundOperation(operationGeneration)
            state = .started
            errorDescription = nil
            publish()
            return result
        } catch {
            let voiceError = Self.voiceError(error)
            let invalidated = !isForegroundOperationAuthorised(
                operationGeneration
            )
            if stopAttempted {
                await readiness?.resolve(.failure(.cancelled))
                // The one native stop owner controls the terminal state. A
                // suspended start must never overwrite its stopping, closed,
                // or stop-unknown evidence after actor re-entrancy.
                throw CodexRemoteVoiceError.cancelled
            }
            if !invalidated,
               let confirmed = confirmedStartResult()
            {
                state = .started
                errorDescription = nil
                publish()
                return confirmed
            }
            await readiness?.resolve(.failure(voiceError))
            if invalidated,
               !realtimeStartRequestBegan,
               !voiceError.isOutcomeUnknown
            {
                // No realtime mutation crossed the boundary. Preserve the
                // background/close state instead of resurrecting this actor as
                // a failed active transport.
                throw CodexRemoteVoiceError.applicationNotActive
            }
            if voiceError.isOutcomeUnknown
                || (realtimeStartRequestBegan
                    && (Self.isAmbiguousTransportError(voiceError)
                        || invalidated))
            {
                state = .startOutcomeUnknown
            } else {
                state = .failed
                guardTask?.cancel()
                guardTask = nil
            }
            errorDescription = voiceError.localizedDescription
            publish()
            throw voiceError
        }
    }

    func stop(timeout: TimeInterval = 15) async throws {
        // Stop is also the bounded cancellation operation while connect/start
        // is suspended. Invalidate that operation before the first await so it
        // cannot resume into a later realtime mutation.
        guard !stopAttempted else {
            throw CodexRemoteVoiceError.stopAlreadyAttempted
        }
        stopAttempted = true
        invalidateLifecycleGeneration()
        if !startAttempted || !realtimeStartRequestBegan {
            state = .closed
            errorDescription = nil
            publish()
            await closeTransport(preserveState: true)
            return
        }
        guard let threadID else {
            throw CodexRemoteVoiceError.voiceNotStarted
        }
        if realtimeClosed { return }
        guard connection != nil, !transportClosed, !closing else {
            throw CodexRemoteVoiceError.operationOutcomeUnknown(
                "Stopping Codex Voice"
            )
        }
        guard timeout > 0, timeout.isFinite else {
            throw CodexRemoteVoiceError.operationOutcomeUnknown(
                "Stopping Codex Voice"
            )
        }

        state = .stopping
        publish()
        do {
            guard let closedSignal else {
                throw CodexRemoteVoiceError.operationOutcomeUnknown(
                    "Stopping Codex Voice"
                )
            }
            // One deadline covers the send, response and closed event. It is
            // especially important in the background, where two sequential
            // timeout windows could outlive iOS's execution lease.
            try await codexRemoteVoiceWithTimeout(
                seconds: timeout,
                timeoutError: .operationOutcomeUnknown(
                    "Stopping Codex Voice"
                )
            ) {
                _ = try await self.request(
                    .realtimeStop,
                    params: .object(["threadId": .string(threadID)]),
                    timeout: timeout
                )
                _ = try await closedSignal.wait()
                return ()
            }
            state = .closed
            errorDescription = nil
            publish()
        } catch {
            if realtimeClosed {
                state = .closed
                errorDescription = nil
                publish()
                return
            }
            let voiceError = Self.voiceError(error)
            state = voiceError.isOutcomeUnknown
                || Self.isAmbiguousTransportError(voiceError)
                ? .stopOutcomeUnknown : .failed
            errorDescription = voiceError.localizedDescription
            publish()
            throw voiceError
        }
    }

    /// An already-started audio conversation may keep its authenticated relay
    /// open under iOS's Audio background mode. Every earlier state remains
    /// foreground-only and follows the original bounded stop-and-close path.
    func applicationDidEnterBackground(
        preserveActiveSession: Bool = false
    ) async {
        applicationForeground = false
        if preserveActiveSession,
           state == .started,
           serverStarted,
           !realtimeClosed,
           connection != nil,
           !transportClosed,
           !closing
        {
            backgroundSessionContinuation = true
            return
        }
        backgroundSessionContinuation = false
        invalidateLifecycleGeneration()
        guard !transportClosed else {
            account = nil
            environmentProvider = nil
            sessionProvider = nil
            identityProvider = nil
            controllerSession = nil
            attestations.removeAll(keepingCapacity: false)
            return
        }
        heartbeatTask?.cancel()
        heartbeatTask = nil
        guardTask?.cancel()
        guardTask = nil
        if realtimeStartRequestBegan, !realtimeClosed, !stopAttempted {
            do {
                try await stop(timeout: 6)
            } catch {
                // The state already distinguishes a definite failure from an
                // unknown stop. Backgrounding never retries it.
            }
        }
        await closeTransport(preserveState: state == .failed
            || state == .startOutcomeUnknown
            || state == .stopOutcomeUnknown,
            sendClientClosed: false)
    }

    func applicationDidBecomeActive() {
        guard !transportClosed, !closing else { return }
        applicationForeground = true
        backgroundSessionContinuation = false
    }

    /// The UIKit background lease is expiring. Skip all protocol niceties and
    /// cancel the WSS immediately; a possibly-executed stop remains unknown
    /// and is never retried.
    func backgroundLeaseDidExpire() async {
        applicationForeground = false
        backgroundSessionContinuation = false
        invalidateLifecycleGeneration()
        await closeTransport(preserveState: state == .failed
            || state == .startOutcomeUnknown
            || state == .stopOutcomeUnknown,
            sendClientClosed: false)
    }

    func close() async {
        await closeTransport(preserveState: state == .failed
            || state == .startOutcomeUnknown
            || state == .stopOutcomeUnknown)
    }

    private func startReader(
        using socket: any CodexRemoteWebSocketConnection
    ) {
        readerTask = Task { [weak self] in
            await self?.readerLoop(using: socket)
        }
    }

    private func readerLoop(
        using socket: any CodexRemoteWebSocketConnection
    ) async {
        do {
            while !Task.isCancelled {
                let frame = try await socket.receive()
                try await handleRelayFrame(frame)
            }
        } catch {
            if !closing, !transportClosed {
                await readerFailed(Self.voiceError(error), socket: socket)
            }
        }
    }

    private func readerFailed(
        _ error: CodexRemoteVoiceError,
        socket: any CodexRemoteWebSocketConnection
    ) async {
        readerTask = nil
        connection = nil
        controllerSession = nil
        account = nil
        environmentProvider = nil
        sessionProvider = nil
        identityProvider = nil
        attestations.removeAll(keepingCapacity: false)
        heartbeatTask?.cancel()
        heartbeatTask = nil
        guardTask?.cancel()
        guardTask = nil
        invalidateLifecycleGeneration()
        backgroundSessionContinuation = false
        transportClosed = true
        closing = true
        cancelHeartbeatToolTasks()
        cancelNativeToolTasks()
        codexHome = nil
        sourceContext = nil
        backingTurnID = nil

        let failure: CodexRemoteVoiceError
        if stopAttempted, !realtimeClosed {
            state = .stopOutcomeUnknown
            failure = .operationOutcomeUnknown("Stopping Codex Voice")
        } else if realtimeStartRequestBegan, !realtimeClosed {
            state = .startOutcomeUnknown
            failure = .operationOutcomeUnknown("Starting Codex Voice")
        } else {
            state = .failed
            failure = error
        }
        errorDescription = failure.localizedDescription
        await failAllWaiters(with: failure)
        publish()
        finishObservers()
        await socket.close()
    }

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            await self?.heartbeatLoop()
        }
    }

    private func heartbeatLoop() async {
        do {
            while !Task.isCancelled {
                try await Task.sleep(
                    for: .seconds(
                        CodexRemoteVoiceConstants.heartbeatSeconds
                    )
                )
                if applicationForeground,
                   !(await foregroundProvider.isApplicationActive())
                {
                    await applicationDidEnterBackground(
                        preserveActiveSession: true
                    )
                    if transportClosed {
                        heartbeatTask = nil
                        return
                    }
                }
                guard applicationForeground || backgroundSessionContinuation
                else {
                    heartbeatTask = nil
                    await applicationDidEnterBackground(
                        preserveActiveSession: false
                    )
                    return
                }
                guard let lastPongAt,
                      now().timeIntervalSince(lastPongAt)
                        < CodexRemoteVoiceConstants.pongTimeoutSeconds
                else {
                    throw CodexRemoteVoiceError.connectionFailed
                }
                try await sendPing()
            }
        } catch is CancellationError {
            return
        } catch {
            heartbeatTask = nil
            let voiceError = Self.voiceError(error)
            if stopAttempted, !realtimeClosed {
                state = .stopOutcomeUnknown
                errorDescription = CodexRemoteVoiceError
                    .operationOutcomeUnknown("Stopping Codex Voice")
                    .localizedDescription
            } else if realtimeStartRequestBegan, !realtimeClosed {
                state = .startOutcomeUnknown
                errorDescription = CodexRemoteVoiceError
                    .operationOutcomeUnknown("Starting Codex Voice")
                    .localizedDescription
            } else {
                state = .failed
                errorDescription = voiceError.localizedDescription
            }
            publish()
            await closeTransport(preserveState: true)
        }
    }

    private func armSessionGuard() {
        guardTask?.cancel()
        guardTask = Task { [weak self] in
            do {
                try await Task.sleep(
                    for: .seconds(
                        CodexRemoteVoiceConstants.sessionGuardSeconds
                    )
                )
            } catch {
                return
            }
            await self?.sessionGuardElapsed()
        }
    }

    private func sessionGuardElapsed() async {
        guardTask = nil
        guard !realtimeClosed, !transportClosed else { return }
        guardTriggered = true
        publish()
        if !stopAttempted {
            do {
                try await stop(timeout: 12)
            } catch {
                // One guard means one stop request. Unknown is terminal.
            }
        }
        await closeTransport(preserveState: state == .failed
            || state == .startOutcomeUnknown
            || state == .stopOutcomeUnknown)
    }

    private func prepareAttestations(
        operationGeneration: UInt64
    ) async throws {
        var prepared: [String] = []
        prepared.reserveCapacity(
            CodexRemoteVoiceConstants.preparedAttestationCount
        )
        for _ in 0..<CodexRemoteVoiceConstants.preparedAttestationCount {
            let token = try await attestationProvider.generateAttestation()
            try ensureForegroundOperation(operationGeneration)
            guard token.utf8.count >= 128, token.utf8.count <= 32 * 1024 else {
                throw CodexRemoteVoiceError.invalidAttestation
            }
            prepared.append(token)
        }
        try ensureForegroundOperation(operationGeneration)
        attestations = prepared
    }

    private func request(
        _ method: CodexRemoteVoiceAppServerMethod,
        params: CodexRemoteVoiceJSON,
        timeout: TimeInterval
    ) async throws -> CodexRemoteVoiceJSON {
        guard method != .initialized else {
            throw CodexRemoteVoiceError.unsupportedAppServerMethod(
                method.rawValue
            )
        }
        let requestID = try takeRequestID()
        let id = CodexRemoteVoiceJSON.integer(requestID)
        let response = CodexRemoteVoiceOneShot<CodexRemoteVoiceJSON>()
        let key = Self.messageIDKey(id)!
        let message: CodexRemoteVoiceJSON = .object([
            "id": id,
            "method": .string(method.rawValue),
            "params": params,
        ])
        let frame = try prepareClientMessageFrame(message)
        pending[key] = response
        defer { pending.removeValue(forKey: key) }
        do {
            try await sendPreparedFrame(frame)
            return try await codexRemoteVoiceWithTimeout(
                seconds: timeout,
                timeoutError: .operationOutcomeUnknown(method.rawValue)
            ) {
                try await response.wait()
            }
        } catch let error as CodexRemoteVoiceError {
            if case .appServerRejected = error {
                throw error
            }
            if error.isOutcomeUnknown {
                throw error
            }
            throw CodexRemoteVoiceError.operationOutcomeUnknown(
                method.rawValue
            )
        } catch {
            throw CodexRemoteVoiceError.operationOutcomeUnknown(
                method.rawValue
            )
        }
    }

    private func notifyInitialized() async throws {
        let message: CodexRemoteVoiceJSON = .object([
            "method": .string(
                CodexRemoteVoiceAppServerMethod.initialized.rawValue
            ),
        ])
        let frame = try prepareClientMessageFrame(message)
        try await sendPreparedFrame(frame)
    }

    private func sendPing() async throws {
        guard let clientID = controllerSession?.clientID,
              let environmentID,
              let streamID
        else {
            throw CodexRemoteVoiceError.notConnected
        }
        let frame: CodexRemoteVoiceJSON = .object([
            "type": .string("ping"),
            "client_id": .string(clientID),
            "seq_id": .integer(try takeClientSequence()),
            "stream_id": .string(streamID),
            "env_id": .string(environmentID),
            "state": .string("foreground"),
            "skip_history": .bool(true),
        ])
        try await sendPreparedFrame(try encodeFrame(frame))
    }

    private func prepareClientMessageFrame(
        _ message: CodexRemoteVoiceJSON
    ) throws -> Data {
        guard let object = message.objectValue else {
            throw CodexRemoteVoiceError.malformedRemoteMessage
        }
        if let methodValue = object["method"] {
            guard let method = methodValue.stringValue,
                  CodexRemoteVoiceAppServerMethod.allowed.contains(method)
            else {
                throw CodexRemoteVoiceError.unsupportedAppServerMethod(
                    methodValue.stringValue ?? "invalid"
                )
            }
        } else {
            guard object["id"] != nil,
                  (object["result"] != nil) != (object["error"] != nil)
            else {
                throw CodexRemoteVoiceError.malformedRemoteMessage
            }
        }
        guard let clientID = controllerSession?.clientID,
              let environmentID,
              let streamID
        else {
            throw CodexRemoteVoiceError.notConnected
        }
        return try encodeFrame(.object([
            "type": .string("client_message"),
            "client_id": .string(clientID),
            "seq_id": .integer(try takeClientSequence()),
            "stream_id": .string(streamID),
            "env_id": .string(environmentID),
            "skip_history": .bool(false),
            "message": message,
        ]))
    }

    private func encodeFrame(_ value: CodexRemoteVoiceJSON) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(value)
        } catch {
            throw CodexRemoteVoiceError.malformedRemoteMessage
        }
        guard data.count <= CodexRemoteVoiceConstants.maximumWebSocketFrameBytes
        else {
            throw CodexRemoteVoiceError.oversizedWebSocketFrame
        }
        return data
    }

    private func sendPreparedFrame(_ frame: Data) async throws {
        guard let connection, !transportClosed, !closing else {
            throw CodexRemoteVoiceError.transportClosed
        }
        try await connection.send(frame)
    }

    private func handleRelayFrame(_ data: Data) async throws {
        guard data.count <= CodexRemoteVoiceConstants.maximumWebSocketFrameBytes
        else {
            throw CodexRemoteVoiceError.oversizedWebSocketFrame
        }
        let envelope: CodexRemoteVoiceJSON
        do {
            envelope = try JSONDecoder().decode(
                CodexRemoteVoiceJSON.self,
                from: data
            )
        } catch {
            throw CodexRemoteVoiceError.malformedRemoteMessage
        }
        guard let object = envelope.objectValue,
              let type = object["type"]?.stringValue
        else {
            throw CodexRemoteVoiceError.malformedRemoteMessage
        }
        guard type == "ack"
            || type == "pong"
            || type == "server_message"
            || type == "server_message_chunk"
        else {
            throw CodexRemoteVoiceError.malformedRemoteMessage
        }
        // One authenticated controller channel can carry more than one
        // logical App Server stream, including a closing predecessor. Route by
        // the opaque environment + stream identity exactly as the Codex Remote
        // client does. Unrelated envelopes are never accepted by this actor,
        // but they are not evidence that its own stream has failed either.
        guard try envelopeBelongsToCurrentStream(object) else { return }
        switch type {
        case "ack":
            guard try requiredInteger(object, "seq_id") > 0 else {
                throw CodexRemoteVoiceError.invalidSequence
            }
        case "pong":
            let sequence = try requiredInteger(object, "seq_id")
            guard try serverSequenceIsCurrent(sequence, complete: true) else {
                return
            }
            guard let status = object["status"]?.stringValue,
                  status == "active" || status == "unknown"
            else {
                throw CodexRemoteVoiceError.malformedRemoteMessage
            }
            guard status == "active" else {
                throw CodexRemoteVoiceError.connectionFailed
            }
            lastPongAt = now()
        case "server_message":
            let sequence = try requiredInteger(object, "seq_id")
            guard try serverSequenceIsCurrent(sequence, complete: true) else {
                return
            }
            guard let message = object["message"]?.objectValue else {
                throw CodexRemoteVoiceError.malformedRemoteMessage
            }
            try await handleAppServerMessage(message)
        case "server_message_chunk":
            let sequence = try requiredInteger(object, "seq_id")
            guard try serverSequenceIsCurrent(sequence, complete: false) else {
                return
            }
            if let message = try observeChunk(object, sequence: sequence) {
                lastServerSequence = sequence
                try await handleAppServerMessage(message)
            }
        default:
            throw CodexRemoteVoiceError.malformedRemoteMessage
        }
    }

    private func envelopeBelongsToCurrentStream(
        _ envelope: [String: CodexRemoteVoiceJSON]
    ) throws -> Bool {
        guard let clientID = controllerSession?.clientID,
              let environmentID,
              let streamID
        else {
            throw CodexRemoteVoiceError.notConnected
        }
        guard let receivedClientID = envelope["client_id"]?.stringValue,
              let receivedEnvironmentID = envelope["env_id"]?.stringValue,
              let receivedStreamID = envelope["stream_id"]?.stringValue
        else {
            throw CodexRemoteVoiceError.malformedRemoteMessage
        }
        // A controller mismatch means the authenticated channel itself is not
        // the one this transport opened, so retain the fail-closed behaviour.
        guard receivedClientID == clientID else {
            throw CodexRemoteVoiceError.streamIdentityMismatch(
                field: "controller ID"
            )
        }
        return receivedEnvironmentID == environmentID
            && receivedStreamID == streamID
    }

    private func serverSequenceIsCurrent(
        _ sequence: Int64,
        complete: Bool
    ) throws -> Bool {
        guard sequence > 0 else {
            throw CodexRemoteVoiceError.invalidSequence
        }
        if sequence <= lastServerSequence { return false }
        guard lastServerSequence < Int64.max,
              sequence == lastServerSequence + 1
        else {
            throw CodexRemoteVoiceError.invalidSequence
        }
        if complete { lastServerSequence = sequence }
        return true
    }

    private func observeChunk(
        _ envelope: [String: CodexRemoteVoiceJSON],
        sequence: Int64
    ) throws -> [String: CodexRemoteVoiceJSON]? {
        let segmentIDValue = try requiredInteger(envelope, "segment_id")
        let segmentCountValue = try requiredInteger(envelope, "segment_count")
        let messageSizeValue = try requiredInteger(
            envelope,
            "message_size_bytes"
        )
        guard segmentIDValue >= 0,
              segmentCountValue > 1,
              segmentCountValue <= Int64(
                  CodexRemoteVoiceConstants.maximumChunkSegments
              ),
              segmentIDValue < segmentCountValue,
              messageSizeValue > 0,
              messageSizeValue <= Int64(
                  CodexRemoteVoiceConstants.maximumAppServerMessageBytes
              ),
              let encoded = envelope["message_chunk_base64"]?.stringValue,
              encoded.utf8.count <= CodexRemoteVoiceConstants
                .maximumWebSocketFrameBytes,
              let chunk = Data(base64Encoded: encoded),
              chunk.count <= CodexRemoteVoiceConstants
                .maximumWebSocketFrameBytes
        else {
            chunks.removeValue(forKey: sequence)
            throw CodexRemoteVoiceError.invalidChunk
        }
        let segmentID = Int(segmentIDValue)
        let segmentCount = Int(segmentCountValue)
        let messageSize = Int(messageSizeValue)
        var assembly = chunks[sequence] ?? CodexRemoteVoiceChunkAssembly(
            segmentCount: segmentCount,
            messageSizeBytes: messageSize,
            chunks: [Data?](repeating: nil, count: segmentCount),
            receivedBytes: 0
        )
        guard assembly.segmentCount == segmentCount,
              assembly.messageSizeBytes == messageSize
        else {
            chunks.removeValue(forKey: sequence)
            throw CodexRemoteVoiceError.invalidChunk
        }
        if let existing = assembly.chunks[segmentID] {
            guard existing == chunk else {
                chunks.removeValue(forKey: sequence)
                throw CodexRemoteVoiceError.invalidChunk
            }
        } else {
            assembly.chunks[segmentID] = chunk
            assembly.receivedBytes += chunk.count
        }
        guard assembly.receivedBytes <= messageSize else {
            chunks.removeValue(forKey: sequence)
            throw CodexRemoteVoiceError.invalidChunk
        }
        guard assembly.chunks.allSatisfy({ $0 != nil }) else {
            chunks[sequence] = assembly
            guard chunks.count == 1 else {
                chunks.removeAll(keepingCapacity: false)
                throw CodexRemoteVoiceError.invalidChunk
            }
            return nil
        }

        chunks.removeValue(forKey: sequence)
        var messageData = Data()
        messageData.reserveCapacity(messageSize)
        for value in assembly.chunks {
            guard let value else {
                throw CodexRemoteVoiceError.invalidChunk
            }
            messageData.append(value)
        }
        guard messageData.count == messageSize else {
            throw CodexRemoteVoiceError.invalidChunk
        }
        let value: CodexRemoteVoiceJSON
        do {
            value = try JSONDecoder().decode(
                CodexRemoteVoiceJSON.self,
                from: messageData
            )
        } catch {
            throw CodexRemoteVoiceError.invalidChunk
        }
        guard let object = value.objectValue else {
            throw CodexRemoteVoiceError.invalidChunk
        }
        return object
    }

    private func handleAppServerMessage(
        _ message: [String: CodexRemoteVoiceJSON]
    ) async throws {
        let method = message["method"]?.stringValue
        if let id = message["id"], let method {
            try await handleServerRequest(
                id: id,
                method: method,
                params: message["params"]?.objectValue ?? [:]
            )
            return
        }
        if let id = message["id"] {
            try await handleResponse(id: id, message: message)
            return
        }
        if let method {
            try await handleNotification(
                method: method,
                params: message["params"]?.objectValue ?? [:]
            )
            return
        }
        if message["type"]?.stringValue == "error" {
            throw CodexRemoteVoiceError.realtimeFailed(
                Self.safeDetail(
                    message["message"]?.stringValue,
                    fallback: "Desktop App Server returned an error"
                )
            )
        }
        throw CodexRemoteVoiceError.malformedRemoteMessage
    }

    private func handleServerRequest(
        id: CodexRemoteVoiceJSON,
        method: String,
        params: [String: CodexRemoteVoiceJSON]
    ) async throws {
        guard Self.messageIDKey(id) != nil else {
            throw CodexRemoteVoiceError.malformedRemoteMessage
        }
        switch codexRemoteVoiceServerRequestRoute(
            method: method,
            params: params,
            threadID: threadID
        ) {
        case .deviceAttestation:
            if attestations.isEmpty {
                try await sendServerError(
                    id: id,
                    code: -32_000,
                    message: "Codex attestation was not prepared"
                )
            } else {
                let token = attestations.removeFirst()
                try await sendServerResult(
                    id: id,
                    result: .object(["token": .string(token)])
                )
            }
            return
        case .heartbeatAutomation:
            let key = Self.messageIDKey(id)!
            guard heartbeatToolTasks[key] == nil else {
                try await sendServerError(
                    id: id,
                    code: -32_600,
                    message: "Heartbeat request is already being handled"
                )
                return
            }
            // The reader must remain free to receive the bounded filesystem
            // responses used below. A child task performs this one typed
            // automation operation; no raw App Server or filesystem surface
            // is exposed to the rest of the app.
            heartbeatToolTasks[key] = Task { [weak self] in
                await self?.handleHeartbeatToolCall(
                    id: id,
                    key: key,
                    params: params
                )
            }
            return
        case .nativeProjectList:
            guard let threadID,
                  params["threadId"]?.stringValue == threadID,
                  let sourceContext
            else {
                try await sendServerResult(
                    id: id,
                    result: Self.nativeToolFailure(
                        "The NightBlood Voice workspace is unavailable."
                    )
                )
                return
            }
            try await sendServerResult(
                id: id,
                result: Self.nativeProjectListResult(
                    cwd: sourceContext.cwd
                )
            )
            return
        case .nativeThreadCreate:
            let key = Self.messageIDKey(id)!
            guard nativeToolTasks[key] == nil else {
                try await sendServerResult(
                    id: id,
                    result: Self.nativeToolFailure(
                        "This task-creation request is already being handled."
                    )
                )
                return
            }
            // Keep the socket reader free while the typed App Server sequence
            // creates the task. The semantic result cache below also makes a
            // repeated realtime delegation return the original receipt rather
            // than creating a second task.
            nativeToolTasks[key] = Task { [weak self] in
                await self?.handleNativeThreadCreate(
                    id: id,
                    key: key,
                    params: params
                )
            }
            return
        case .nativeThreadRead, .nativeThreadWait:
            let key = Self.messageIDKey(id)!
            guard nativeToolTasks[key] == nil else {
                try await sendServerResult(
                    id: id,
                    result: Self.nativeToolFailure(
                        "This task-reading request is already being handled."
                    )
                )
                return
            }
            let waitsForCompletion = codexRemoteVoiceServerRequestRoute(
                method: method,
                params: params,
                threadID: threadID
            ) == .nativeThreadWait
            nativeToolTasks[key] = Task { [weak self] in
                await self?.handleNativeThreadRead(
                    id: id,
                    key: key,
                    params: params,
                    waitsForCompletion: waitsForCompletion
                )
            }
            return
        case .unsupportedVoiceDynamicTool:
            try await sendServerResult(
                id: id,
                result: Self.nativeToolFailure(
                    "This Codex app tool is not yet available through NightBlood Voice. The request was stopped cleanly instead of being left running."
                )
            )
            return
        case .desktopDynamicTool:
            // App Server broadcasts native Codex app-tool requests to its
            // registered clients. The iPhone neither executes nor rejects an
            // unowned tool: a negative response here can win the race against
            // Codex Desktop's native renderer and cancel a valid operation.
            // Leaving it unanswered lets Desktop keep the normal built-in tool
            // route, permissions and result handling.
            return
        case .reject:
            // Approvals, user input, raw MCP, malformed tool calls, and future
            // server requests remain explicitly unsupported by this bounded
            // controller.
            try await sendServerError(
                id: id,
                code: -32_601,
                message: "App Server request is not supported by Remote voice"
            )
        }
    }

    private func handleNativeThreadCreate(
        id: CodexRemoteVoiceJSON,
        key: String,
        params: [String: CodexRemoteVoiceJSON]
    ) async {
        defer { nativeToolTasks.removeValue(forKey: key) }
        do {
            guard !closing, !transportClosed,
                  let threadID,
                  let sourceContext
            else {
                throw CodexRemoteVoiceError.transportClosed
            }
            let creation = try CodexRemoteVoiceNativeCreateThreadRequest(
                params: params,
                expectedThreadID: threadID
            )
            let shared: CodexRemoteVoiceOneShot<
                CodexRemoteVoiceNativeThreadResult
            >
            let isFirst: Bool
            if let existing = nativeThreadResults[creation.fingerprint] {
                shared = existing
                isFirst = false
            } else {
                guard nativeThreadResults.count < 32 else {
                    throw CodexRemoteVoiceError.appServerRejected(
                        "NightBlood Voice has reached its task-creation limit for this session."
                    )
                }
                let created = CodexRemoteVoiceOneShot<
                    CodexRemoteVoiceNativeThreadResult
                >()
                nativeThreadResults[creation.fingerprint] = created
                shared = created
                isFirst = true
            }

            if isFirst {
                let result = await performNativeThreadCreate(
                    creation,
                    sourceContext: sourceContext
                )
                await shared.resolve(.success(result))
            }
            let result = try await shared.wait()
            try await sendServerResult(
                id: id,
                result: isFirst ? result.first : result.duplicate
            )
        } catch {
            guard !closing, !transportClosed else { return }
            try? await sendServerResult(
                id: id,
                result: Self.nativeToolFailure(error)
            )
        }
    }

    private func handleNativeThreadRead(
        id: CodexRemoteVoiceJSON,
        key: String,
        params: [String: CodexRemoteVoiceJSON],
        waitsForCompletion: Bool
    ) async {
        defer { nativeToolTasks.removeValue(forKey: key) }
        do {
            guard !closing, !transportClosed, let threadID else {
                throw CodexRemoteVoiceError.transportClosed
            }
            let reading = try CodexRemoteVoiceNativeThreadReadRequest(
                params: params,
                expectedThreadID: threadID,
                waitsForCompletion: waitsForCompletion
            )
            guard nativeCreatedThreadIDs.contains(reading.threadID) else {
                throw CodexRemoteVoiceError.appServerRejected(
                    "NightBlood Voice can read only a task created during this conversation."
                )
            }

            let deadline = Date().addingTimeInterval(reading.timeoutSeconds)
            var readResponse: CodexRemoteVoiceJSON
            var settled: Bool
            repeat {
                readResponse = try await request(
                    .threadRead,
                    params: .object([
                        "threadId": .string(reading.threadID),
                        "includeTurns": .bool(true),
                    ]),
                    timeout: 5
                )
                settled = Self.nativeThreadIsSettled(readResponse)
                if settled || !waitsForCompletion || Date() >= deadline {
                    break
                }
                try await Task.sleep(for: .milliseconds(200))
            } while !Task.isCancelled

            try await sendServerResult(
                id: id,
                result: try Self.nativeThreadReadSuccess(
                    response: readResponse,
                    request: reading,
                    waited: waitsForCompletion,
                    settled: settled
                )
            )
        } catch {
            guard !closing, !transportClosed else { return }
            try? await sendServerResult(
                id: id,
                result: Self.nativeToolFailure(error)
            )
        }
    }

    private func performNativeThreadCreate(
        _ creation: CodexRemoteVoiceNativeCreateThreadRequest,
        sourceContext: CodexRemoteVoiceSourceContext
    ) async -> CodexRemoteVoiceNativeThreadResult {
        do {
            var startParams: [String: CodexRemoteVoiceJSON] = [
                "cwd": .string(sourceContext.cwd),
                "runtimeWorkspaceRoots": .array(
                    sourceContext.runtimeWorkspaceRoots.map {
                        .string($0)
                    }
                ),
                "approvalPolicy": sourceContext.approvalPolicy,
                "approvalsReviewer": sourceContext.approvalsReviewer,
                "ephemeral": .bool(false),
                "historyMode": .string("paginated"),
                "threadSource": .string("user"),
            ]
            if let profileID = sourceContext.permissionProfileID {
                startParams["permissions"] = .string(profileID)
            } else if let sandboxMode = sourceContext.sandboxMode {
                startParams["sandbox"] = .string(sandboxMode)
            }
            if let serviceTier = sourceContext.serviceTier {
                startParams["serviceTier"] = .string(serviceTier)
            }
            if let model = creation.model {
                startParams["model"] = .string(model)
            }

            let startResponse = try await request(
                .threadStart,
                params: .object(startParams),
                timeout: 8
            )
            guard let rawThreadID = startResponse.objectValue?["thread"]?
                    .objectValue?["id"]?.stringValue
            else {
                throw CodexRemoteVoiceError.operationOutcomeUnknown(
                    "Creating the Codex task"
                )
            }
            let createdThreadID = try Self.canonicalThreadID(rawThreadID)
            nativeCreatedThreadIDs.insert(createdThreadID)

            var turnParams: [String: CodexRemoteVoiceJSON] = [
                "threadId": .string(createdThreadID),
                "input": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string(creation.prompt),
                    ]),
                ]),
            ]
            if let model = creation.model {
                turnParams["model"] = .string(model)
            }
            if let thinking = creation.thinking {
                turnParams["effort"] = .string(thinking)
            }

            var warnings: [String] = []
            do {
                _ = try await request(
                    .turnStart,
                    params: .object(turnParams),
                    timeout: 8
                )
            } catch {
                warnings.append(
                    "The task exists, but its opening prompt could not be confirmed. Do not create it again."
                )
            }
            if let title = creation.title {
                do {
                    _ = try await request(
                        .threadSetName,
                        params: .object([
                            "threadId": .string(createdThreadID),
                            "name": .string(title),
                        ]),
                        timeout: 5
                    )
                } catch {
                    warnings.append(
                        "The task exists, but its requested title could not be confirmed."
                    )
                }
            }

            let first = Self.nativeThreadCreateSuccess(
                threadID: createdThreadID,
                warnings: warnings,
                duplicate: false
            )
            let duplicate = Self.nativeThreadCreateSuccess(
                threadID: createdThreadID,
                warnings: [
                    "This was a duplicate realtime delegation. The task was already created; do not create or announce it again.",
                ],
                duplicate: true
            )
            return CodexRemoteVoiceNativeThreadResult(
                first: first,
                duplicate: duplicate
            )
        } catch {
            let failure = Self.nativeToolFailure(error)
            return CodexRemoteVoiceNativeThreadResult(
                first: failure,
                duplicate: Self.nativeToolFailure(
                    "This repeated task request shares an earlier unconfirmed result. Do not retry it automatically."
                )
            )
        }
    }

    private func handleHeartbeatToolCall(
        id: CodexRemoteVoiceJSON,
        key: String,
        params: [String: CodexRemoteVoiceJSON]
    ) async {
        defer { heartbeatToolTasks.removeValue(forKey: key) }
        do {
            guard !closing, !transportClosed,
                  let threadID,
                  params["threadId"]?.stringValue == threadID,
                  let arguments = params["arguments"]?.objectValue,
                  let codexHome
            else {
                throw CodexRemoteHeartbeatAutomationError.invalidArguments(
                    "the Voice task is no longer available"
                )
            }

            let root = codexHome + "/automations"
            _ = try await request(
                .fsCreateDirectory,
                params: .object([
                    "path": .string(root),
                    "recursive": .bool(true),
                ]),
                timeout: 8
            )
            let store = try await readHeartbeatAutomationStore(root: root)
            let result: CodexRemoteVoiceJSON
            switch arguments["mode"]?.stringValue {
            case "create":
                result = try await createHeartbeat(
                    arguments: arguments,
                    targetThreadID: threadID,
                    root: root,
                    store: store
                )
            case "delete":
                result = try await deleteHeartbeat(
                    arguments: arguments,
                    targetThreadID: threadID,
                    root: root,
                    store: store
                )
            default:
                throw CodexRemoteHeartbeatAutomationError.invalidArguments(
                    "Voice supports heartbeat creation and cancellation"
                )
            }
            try await sendServerResult(id: id, result: result)
        } catch {
            guard !closing, !transportClosed else { return }
            try? await sendServerResult(
                id: id,
                result: Self.heartbeatToolFailure(error)
            )
        }
    }

    private func createHeartbeat(
        arguments: [String: CodexRemoteVoiceJSON],
        targetThreadID: String,
        root: String,
        store: (
            ids: Set<String>,
            files: [String],
            filesByID: [String: String]
        )
    ) async throws -> CodexRemoteVoiceJSON {
            let timestamp = now().timeIntervalSince1970 * 1_000
            guard timestamp.isFinite,
                  timestamp >= 0,
                  timestamp <= Double(Int64.max)
            else {
                throw CodexRemoteHeartbeatAutomationError.storeUnavailable
            }
            let automation = try CodexRemoteHeartbeatAutomation.make(
                arguments: arguments,
                targetThreadID: targetThreadID,
                existingIDs: store.ids,
                existingAutomationFiles: store.files,
                createdAtMilliseconds: Int64(timestamp.rounded(.down)),
                fallbackUUID: makeUUID()
            )
            let directory = root + "/" + automation.id
            let path = directory + "/automation.toml"
            _ = try await request(
                .fsCreateDirectory,
                params: .object([
                    "path": .string(directory),
                    "recursive": .bool(false),
                ]),
                timeout: 8
            )
            let encoded = Data(automation.toml.utf8).base64EncodedString()
            do {
                _ = try await request(
                    .fsWriteFile,
                    params: .object([
                        "path": .string(path),
                        "dataBase64": .string(encoded),
                    ]),
                    timeout: 8
                )
            } catch {
                throw CodexRemoteVoiceError.operationOutcomeUnknown(
                    "Creating the heartbeat"
                )
            }

            // A successful write response is necessary but not sufficient:
            // read the new file back byte-for-byte before reporting success.
            let verification = try await request(
                .fsReadFile,
                params: .object(["path": .string(path)]),
                timeout: 8
            )
            guard verification.objectValue?["dataBase64"]?.stringValue == encoded
            else {
                throw CodexRemoteVoiceError.operationOutcomeUnknown(
                    "Creating the heartbeat"
                )
            }
            return Self.heartbeatToolSuccess(id: automation.id)
    }

    private func deleteHeartbeat(
        arguments: [String: CodexRemoteVoiceJSON],
        targetThreadID: String,
        root: String,
        store: (
            ids: Set<String>,
            files: [String],
            filesByID: [String: String]
        )
    ) async throws -> CodexRemoteVoiceJSON {
        let lookup = try CodexRemoteHeartbeatAutomation.deletionLookup(
            arguments: arguments,
            targetThreadID: targetThreadID,
            existingIDs: store.ids,
            filesByID: store.filesByID
        )
        switch lookup {
        case .notFound(let id):
            return Self.heartbeatToolDeletionSuccess(
                id: id,
                status: "not_found",
                snapshot: nil
            )
        case .owned(let snapshot):
            let directory = root + "/" + snapshot.id
            do {
                _ = try await request(
                    .fsRemove,
                    params: .object([
                        "path": .string(directory),
                        "recursive": .bool(true),
                        "force": .bool(false),
                    ]),
                    timeout: 8
                )
            } catch {
                throw CodexRemoteVoiceError.operationOutcomeUnknown(
                    "Cancelling the heartbeat"
                )
            }
            do {
                let verification = try await request(
                    .fsReadDirectory,
                    params: .object(["path": .string(root)]),
                    timeout: 8
                )
                guard let entries = verification.objectValue?["entries"]?
                    .arrayValue,
                    !entries.contains(where: {
                        $0.objectValue?["fileName"]?.stringValue == snapshot.id
                    })
                else {
                    throw CodexRemoteVoiceError.operationOutcomeUnknown(
                        "Cancelling the heartbeat"
                    )
                }
            } catch {
                throw CodexRemoteVoiceError.operationOutcomeUnknown(
                    "Cancelling the heartbeat"
                )
            }
            return Self.heartbeatToolDeletionSuccess(
                id: snapshot.id,
                status: "deleted",
                snapshot: snapshot
            )
        }
    }

    private func readHeartbeatAutomationStore(
        root: String
    ) async throws -> (
        ids: Set<String>,
        files: [String],
        filesByID: [String: String]
    ) {
        let result = try await request(
            .fsReadDirectory,
            params: .object(["path": .string(root)]),
            timeout: 8
        )
        guard let entries = result.objectValue?["entries"]?.arrayValue,
              entries.count <= CodexRemoteHeartbeatAutomation
                .maximumAutomationEntries
        else {
            throw CodexRemoteHeartbeatAutomationError.storeUnavailable
        }

        var ids: Set<String> = []
        var files: [String] = []
        var filesByID: [String: String] = [:]
        for value in entries {
            guard let entry = value.objectValue,
                  entry["isDirectory"]?.boolValue == true,
                  let name = entry["fileName"]?.stringValue,
                  Self.validAutomationID(name)
            else {
                continue
            }
            ids.insert(name)
            let directory = root + "/" + name
            let directoryResult = try await request(
                .fsReadDirectory,
                params: .object(["path": .string(directory)]),
                timeout: 8
            )
            guard let children = directoryResult.objectValue?["entries"]?
                .arrayValue,
                children.count <= 32
            else {
                throw CodexRemoteHeartbeatAutomationError.storeUnavailable
            }
            let hasAutomationFile = children.contains { child in
                guard let object = child.objectValue else { return false }
                return object["fileName"]?.stringValue == "automation.toml"
                    && object["isFile"]?.boolValue == true
            }
            // Codex Desktop tolerates stale or partially-created automation
            // directories. Keep their ids reserved, but do not try to read a
            // file that is not present.
            guard hasAutomationFile else { continue }
            let read = try await request(
                .fsReadFile,
                params: .object([
                    "path": .string(directory + "/automation.toml"),
                ]),
                timeout: 8
            )
            guard let encoded = read.objectValue?["dataBase64"]?.stringValue,
                  encoded.utf8.count <= CodexRemoteHeartbeatAutomation
                    .maximumAutomationFileBytes * 2,
                  let data = Data(base64Encoded: encoded),
                  data.count <= CodexRemoteHeartbeatAutomation
                    .maximumAutomationFileBytes,
                  let text = String(data: data, encoding: .utf8)
            else {
                throw CodexRemoteHeartbeatAutomationError.storeUnavailable
            }
            files.append(text)
            filesByID[name] = text
        }
        return (ids, files, filesByID)
    }

    private static func validAutomationID(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && value.utf8.count <= 128
            && !value.contains("/")
            && !value.contains("\\")
            && value.unicodeScalars.allSatisfy {
                ($0.value >= 97 && $0.value <= 122)
                    || ($0.value >= 48 && $0.value <= 57)
                    || $0.value == 45
            }
    }

    private static func heartbeatToolSuccess(
        id: String
    ) -> CodexRemoteVoiceJSON {
        .object([
            "contentItems": .array([
                .object([
                    "type": .string("inputText"),
                    "text": .string("Created automation in the app."),
                ]),
                .object([
                    "type": .string("inputText"),
                    "text": .string(
                        "{\"automationId\":\"\(id)\",\"mode\":\"create\"}"
                    ),
                ]),
            ]),
            "success": .bool(true),
        ])
    }

    private static func heartbeatToolDeletionSuccess(
        id: String,
        status: String,
        snapshot: CodexRemoteHeartbeatAutomation.DeletionSnapshot?
    ) -> CodexRemoteVoiceJSON {
        var receipt: [String: CodexRemoteVoiceJSON] = [
            "automationId": .string(id),
            "mode": .string("delete"),
            "deleteStatus": .string(status),
        ]
        if let snapshot {
            receipt["snapshot"] = .object([
                "kind": .string("heartbeat"),
                "name": .string(snapshot.name),
                "rrule": .string(snapshot.rrule),
            ])
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let receiptText = (try? encoder.encode(
            CodexRemoteVoiceJSON.object(receipt)
        )).flatMap { String(data: $0, encoding: .utf8) }
            ?? "{\"automationId\":\"\(id)\",\"mode\":\"delete\"}"
        return .object([
            "contentItems": .array([
                .object([
                    "type": .string("inputText"),
                    "text": .string(
                        status == "deleted"
                            ? "Deleted automation in the app."
                            : "Automation was already absent from the app."
                    ),
                ]),
                .object([
                    "type": .string("inputText"),
                    "text": .string(receiptText),
                ]),
            ]),
            "success": .bool(true),
        ])
    }

    private static func heartbeatToolFailure(
        _ error: any Error
    ) -> CodexRemoteVoiceJSON {
        let message: String
        if let voiceError = error as? CodexRemoteVoiceError,
           voiceError.isOutcomeUnknown
        {
            message = voiceError.errorDescription
                ?? "The heartbeat operation could not be confirmed. Do not retry automatically; check Automations first."
        } else if let localised = error as? any LocalizedError,
                  let detail = localised.errorDescription,
                  !detail.isEmpty
        {
            message = detail
        } else {
            message = "The heartbeat request failed before it could be confirmed."
        }
        return .object([
            "contentItems": .array([
                .object([
                    "type": .string("inputText"),
                    "text": .string(message),
                ]),
            ]),
            "success": .bool(false),
        ])
    }

    private static func nativeThreadIsSettled(
        _ response: CodexRemoteVoiceJSON
    ) -> Bool {
        guard let thread = response.objectValue?["thread"]?.objectValue else {
            return false
        }
        if let lastTurn = thread["turns"]?.arrayValue?.last?.objectValue,
           let turnStatus = lastTurn["status"]?.stringValue
        {
            return turnStatus != "inProgress"
        }
        let status = thread["status"]?.objectValue?["type"]?.stringValue
        return status == "idle" || status == "systemError"
    }

    private static func nativeThreadReadSuccess(
        response: CodexRemoteVoiceJSON,
        request: CodexRemoteVoiceNativeThreadReadRequest,
        waited: Bool,
        settled: Bool
    ) throws -> CodexRemoteVoiceJSON {
        guard let thread = response.objectValue?["thread"]?.objectValue,
              thread["id"]?.stringValue?.lowercased() == request.threadID,
              let turns = thread["turns"]?.arrayValue
        else {
            throw CodexRemoteVoiceError.malformedRemoteMessage
        }

        var messages: [CodexRemoteVoiceJSON] = []
        for turnValue in turns.suffix(request.turnLimit) {
            guard let turn = turnValue.objectValue,
                  let turnID = turn["id"]?.stringValue,
                  let items = turn["items"]?.arrayValue
            else { continue }
            for itemValue in items {
                guard let item = itemValue.objectValue,
                      let type = item["type"]?.stringValue
                else { continue }
                if type == "userMessage" {
                    let text = (item["content"]?.arrayValue ?? [])
                        .compactMap { content -> String? in
                            guard let value = content.objectValue,
                                  value["type"]?.stringValue == "text"
                            else { return nil }
                            return value["text"]?.stringValue
                        }
                        .joined(separator: "\n")
                    guard !text.isEmpty else { continue }
                    messages.append(.object([
                        "role": .string("user"),
                        "text": .string(String(text.prefix(16_384))),
                        "turnId": .string(turnID),
                    ]))
                } else if type == "agentMessage",
                          let text = item["text"]?.stringValue,
                          !text.isEmpty
                {
                    var message: [String: CodexRemoteVoiceJSON] = [
                        "role": .string("assistant"),
                        "text": .string(String(text.prefix(16_384))),
                        "turnId": .string(turnID),
                    ]
                    if let phase = item["phase"]?.stringValue {
                        message["phase"] = .string(phase)
                    }
                    messages.append(.object(message))
                }
            }
        }

        var snapshot: [String: CodexRemoteVoiceJSON] = [
            "threadId": .string(request.threadID),
            "hostId": .string("local"),
            "status": .string(
                thread["status"]?.objectValue?["type"]?.stringValue
                    ?? "unknown"
            ),
            "settled": .bool(settled),
            "messages": .array(messages),
        ]
        if let name = thread["name"]?.stringValue {
            snapshot["title"] = .string(name)
        }
        if let updatedAt = thread["updatedAt"]?.integerValue {
            snapshot["cursor"] = .string(String(updatedAt))
        }

        let payload: CodexRemoteVoiceJSON = waited
            ? .object([
                "targets": .array([.object(snapshot)]),
                "timedOut": .bool(!settled),
            ])
            : .object(snapshot)
        return nativeToolSuccess(text: encodeToolPayload(payload))
    }

    private static func nativeProjectListResult(
        cwd: String
    ) -> CodexRemoteVoiceJSON {
        let label = URL(fileURLWithPath: cwd).lastPathComponent
        let configuredProjectID =
            CodexRemoteVoiceNativeCreateThreadRequest.configuredProjectID
        let projects: [CodexRemoteVoiceJSON]
        if configuredProjectID.isEmpty {
            projects = []
        } else {
            projects = [
                .object([
                    "projectId": .string(configuredProjectID),
                    "projectKind": .string("local"),
                    "label": .string(label.isEmpty ? "Current project" : label),
                    "path": .string(cwd),
                    "hostId": .string("local"),
                    "hostDisplayName": .null,
                    // This bounded fallback advertises only the current
                    // workspace as local. It never chooses a worktree.
                    "isGitRepository": .bool(false),
                ]),
            ]
        }
        let payload: CodexRemoteVoiceJSON = .object([
            "schemaVersion": .integer(2),
            "projects": .array(projects),
        ])
        return nativeToolSuccess(text: encodeToolPayload(payload))
    }

    private static func nativeThreadCreateSuccess(
        threadID: String,
        warnings: [String],
        duplicate: Bool
    ) -> CodexRemoteVoiceJSON {
        var payload: [String: CodexRemoteVoiceJSON] = [
            "threadId": .string(threadID),
            "hostId": .string("local"),
        ]
        if duplicate {
            payload["duplicate"] = .bool(true)
        }
        if !warnings.isEmpty {
            payload["warnings"] = .array(warnings.map { .string($0) })
        }
        var content: [CodexRemoteVoiceJSON] = [
            .object([
                "type": .string("inputText"),
                "text": .string(encodeToolPayload(.object(payload))),
            ]),
        ]
        if !warnings.isEmpty {
            content.append(
                .object([
                    "type": .string("inputText"),
                    "text": .string(warnings.joined(separator: " ")),
                ])
            )
        }
        return .object([
            "contentItems": .array(content),
            "success": .bool(true),
        ])
    }

    private static func nativeToolSuccess(
        text: String
    ) -> CodexRemoteVoiceJSON {
        .object([
            "contentItems": .array([
                .object([
                    "type": .string("inputText"),
                    "text": .string(text),
                ]),
            ]),
            "success": .bool(true),
        ])
    }

    private static func nativeToolFailure(
        _ message: String
    ) -> CodexRemoteVoiceJSON {
        .object([
            "contentItems": .array([
                .object([
                    "type": .string("inputText"),
                    "text": .string(message),
                ]),
            ]),
            "success": .bool(false),
        ])
    }

    private static func nativeToolFailure(
        _ error: any Error
    ) -> CodexRemoteVoiceJSON {
        let message: String
        if let voiceError = error as? CodexRemoteVoiceError,
           voiceError.isOutcomeUnknown
        {
            message = (voiceError.errorDescription
                ?? "Task creation could not be confirmed.")
                + " Do not retry automatically."
        } else if let localised = error as? any LocalizedError,
                  let detail = localised.errorDescription,
                  !detail.isEmpty
        {
            message = detail
        } else {
            message = "The Codex task request failed before it could be confirmed."
        }
        return nativeToolFailure(message)
    }

    private static func encodeToolPayload(
        _ payload: CodexRemoteVoiceJSON
    ) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(payload))
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? "{}"
    }

    private func sendServerResult(
        id: CodexRemoteVoiceJSON,
        result: CodexRemoteVoiceJSON
    ) async throws {
        let frame = try prepareClientMessageFrame(.object([
            "id": id,
            "result": result,
        ]))
        try await sendPreparedFrame(frame)
    }

    private func sendServerError(
        id: CodexRemoteVoiceJSON,
        code: Int64,
        message: String
    ) async throws {
        let frame = try prepareClientMessageFrame(.object([
            "id": id,
            "error": .object([
                "code": .integer(code),
                "message": .string(message),
            ]),
        ]))
        try await sendPreparedFrame(frame)
    }

    private func handleResponse(
        id: CodexRemoteVoiceJSON,
        message: [String: CodexRemoteVoiceJSON]
    ) async throws {
        guard let key = Self.messageIDKey(id) else {
            throw CodexRemoteVoiceError.malformedRemoteMessage
        }
        guard let waiter = pending[key] else {
            // A response may arrive after a bounded timeout. It is evidence,
            // but no timed-out mutation is retried or rebound to a new call.
            return
        }
        if let error = message["error"] {
            let detail = Self.safeDetail(
                error.objectValue?["message"]?.stringValue,
                fallback: "Desktop App Server request failed"
            )
            await waiter.resolve(.failure(.appServerRejected(detail)))
        } else if let result = message["result"] {
            await waiter.resolve(.success(result))
        } else {
            await waiter.resolve(.failure(.malformedRemoteMessage))
        }
    }

    private func handleNotification(
        method: String,
        params: [String: CodexRemoteVoiceJSON]
    ) async throws {
        guard method == "thread/realtime/sdp"
            || method == "thread/realtime/started"
            || method == "thread/realtime/error"
            || method == "thread/realtime/closed"
            || method == "turn/started"
            || method == "turn/completed"
        else {
            return
        }
        guard params["threadId"]?.stringValue == threadID else { return }
        switch method {
        case "turn/started":
            guard let turnID = Self.boundedTurnID(from: params) else { return }
            if backingTurnID != turnID {
                backingTurnID = turnID
                publish()
            }
        case "turn/completed":
            guard let turnID = Self.boundedTurnID(from: params),
                  backingTurnID == turnID
            else {
                return
            }
            backingTurnID = nil
            publish()
        case "thread/realtime/sdp":
            guard let sdp = params["sdp"]?.stringValue else {
                throw CodexRemoteVoiceError.malformedRemoteMessage
            }
            try Self.validateSDP(sdp)
            if let sdpAnswer, sdpAnswer != sdp {
                throw CodexRemoteVoiceError.malformedRemoteMessage
            }
            sdpAnswer = sdp
            await resolveReadinessIfComplete()
        case "thread/realtime/started":
            serverStarted = true
            realtimeClosed = false
            if state != .startOutcomeUnknown {
                state = .started
            }
            await resolveReadinessIfComplete()
            publish()
        case "thread/realtime/error":
            let error = CodexRemoteVoiceError.realtimeFailed(
                Self.safeDetail(
                    params["message"]?.stringValue,
                    fallback: "Codex Remote realtime failed"
                )
            )
            state = .failed
            backingTurnID = nil
            serverStarted = false
            errorDescription = error.localizedDescription
            guardTask?.cancel()
            guardTask = nil
            await readiness?.resolve(.failure(error))
            publish()
        default:
            realtimeClosed = true
            backingTurnID = nil
            serverStarted = false
            state = .closed
            errorDescription = nil
            guardTask?.cancel()
            guardTask = nil
            attestations.removeAll(keepingCapacity: false)
            let error = CodexRemoteVoiceError.realtimeClosedBeforeReady
            await readiness?.resolve(.failure(error))
            await closedSignal?.resolve(.success(()))
            publish()
        }
    }

    private static func boundedTurnID(
        from params: [String: CodexRemoteVoiceJSON]
    ) -> String? {
        guard let turnID = params["turn"]?.objectValue?["id"]?.stringValue,
              !turnID.isEmpty,
              turnID.utf8.count <= 1_024
        else {
            return nil
        }
        return turnID
    }

    private func resolveReadinessIfComplete() async {
        guard let result = confirmedStartResult() else { return }
        await readiness?.resolve(.success(result))
    }

    private func confirmedStartResult() -> CodexRemoteVoiceStartResult? {
        guard serverStarted,
              !realtimeClosed,
              let sdpAnswer,
              let threadID,
              let requestedVoice
        else {
            return nil
        }
        return CodexRemoteVoiceStartResult(
            sdpAnswer: sdpAnswer,
            threadID: threadID,
            voice: requestedVoice.rawValue,
            version: CodexRemoteVoiceConstants.version,
            model: CodexRemoteVoiceConstants.model,
            serverStarted: true
        )
    }

    private func closeTransport(
        preserveState: Bool,
        sendClientClosed: Bool = true
    ) async {
        invalidateLifecycleGeneration()
        backgroundSessionContinuation = false
        guard !transportClosed else {
            cancelHeartbeatToolTasks()
            cancelNativeToolTasks()
            let activeReader = readerTask
            readerTask = nil
            activeReader?.cancel()
            controllerSession = nil
            account = nil
            environmentProvider = nil
            sessionProvider = nil
            identityProvider = nil
            codexHome = nil
            sourceContext = nil
            attestations.removeAll(keepingCapacity: false)
            if let connection {
                self.connection = nil
                await connection.close()
            }
            if let activeReader {
                await activeReader.value
            }
            return
        }
        closing = true
        cancelHeartbeatToolTasks()
        cancelNativeToolTasks()
        heartbeatTask?.cancel()
        heartbeatTask = nil
        guardTask?.cancel()
        guardTask = nil

        if sendClientClosed,
           let connection,
           let clientID = controllerSession?.clientID,
           let environmentID,
           let streamID
        {
            if let sequence = try? takeClientSequence(),
               let frame = try? encodeFrame(.object([
                   "type": .string("client_closed"),
                   "client_id": .string(clientID),
                   "seq_id": .integer(sequence),
                   "stream_id": .string(streamID),
                   "env_id": .string(environmentID),
               ]))
            {
                try? await connection.send(frame)
            }
        }

        let activeReader = readerTask
        readerTask = nil
        activeReader?.cancel()
        let activeConnection = connection
        connection = nil
        await activeConnection?.close()
        if let activeReader {
            await activeReader.value
        }

        if !preserveState {
            if startAttempted, !realtimeClosed {
                if stopAttempted {
                    state = .stopOutcomeUnknown
                    errorDescription = CodexRemoteVoiceError
                        .operationOutcomeUnknown("Stopping Codex Voice")
                        .localizedDescription
                } else {
                    state = .startOutcomeUnknown
                    errorDescription = CodexRemoteVoiceError
                        .operationOutcomeUnknown("Starting Codex Voice")
                        .localizedDescription
                }
            } else {
                state = .closed
                errorDescription = nil
            }
        }
        controllerSession = nil
        codexHome = nil
        sourceContext = nil
        backingTurnID = nil
        attestations.removeAll(keepingCapacity: false)
        chunks.removeAll(keepingCapacity: false)
        transportClosed = true
        await failAllWaiters(with: .transportClosed)
        publish()
        finishObservers()
    }

    /// Connect may be suspended in native authentication or WebSocket
    /// handshake code while the app backgrounds. This cleanup never trusts
    /// the transportClosed flag: it closes the attempt-local socket and any
    /// socket it managed to install, then clears every credential reference.
    private func discardConnectAttempt(
        _ openedConnection: (any CodexRemoteWebSocketConnection)?
    ) async {
        invalidateLifecycleGeneration()
        backgroundSessionContinuation = false
        closing = true
        cancelHeartbeatToolTasks()
        cancelNativeToolTasks()
        heartbeatTask?.cancel()
        heartbeatTask = nil
        guardTask?.cancel()
        guardTask = nil
        let activeReader = readerTask
        readerTask = nil
        activeReader?.cancel()
        let installedConnection = connection
        connection = nil
        await openedConnection?.close()
        await installedConnection?.close()
        if let activeReader {
            await activeReader.value
        }
        controllerSession = nil
        account = nil
        environmentProvider = nil
        sessionProvider = nil
        identityProvider = nil
        codexHome = nil
        sourceContext = nil
        attestations.removeAll(keepingCapacity: false)
        chunks.removeAll(keepingCapacity: false)
        transportClosed = true
        await failAllWaiters(with: .transportClosed)
        finishObservers()
    }

    private func failAllWaiters(
        with error: CodexRemoteVoiceError
    ) async {
        let responseWaiters = pending.values
        pending.removeAll(keepingCapacity: false)
        for waiter in responseWaiters {
            await waiter.resolve(.failure(error))
        }
        await readiness?.resolve(.failure(error))
        await closedSignal?.resolve(.failure(error))
    }

    private func cancelHeartbeatToolTasks() {
        let tasks = heartbeatToolTasks.values
        heartbeatToolTasks.removeAll(keepingCapacity: false)
        for task in tasks { task.cancel() }
    }

    private func cancelNativeToolTasks() {
        let tasks = nativeToolTasks.values
        nativeToolTasks.removeAll(keepingCapacity: false)
        nativeThreadResults.removeAll(keepingCapacity: false)
        nativeCreatedThreadIDs.removeAll(keepingCapacity: false)
        for task in tasks { task.cancel() }
    }

    private func publish() {
        if revision < UInt64.max { revision += 1 }
        let value = snapshot()
        for continuation in observers.values {
            continuation.yield(value)
        }
    }

    private func finishObservers() {
        let continuations = observers.values
        observers.removeAll(keepingCapacity: false)
        for continuation in continuations {
            continuation.finish()
        }
    }

    private func removeObserver(_ observerID: UUID) {
        observers.removeValue(forKey: observerID)
    }

    private func ensureForegroundOperation(_ generation: UInt64) throws {
        guard isForegroundOperationAuthorised(generation) else {
            throw CodexRemoteVoiceError.applicationNotActive
        }
    }

    private func isForegroundOperationAuthorised(
        _ generation: UInt64
    ) -> Bool {
        generation == lifecycleGeneration
            && applicationForeground
            && !closing
            && !transportClosed
    }

    private func invalidateLifecycleGeneration() {
        if lifecycleGeneration == UInt64.max {
            lifecycleGeneration = 0
        } else {
            lifecycleGeneration += 1
        }
    }

    private func takeClientSequence() throws -> Int64 {
        guard nextClientSequence > 0, nextClientSequence < Int64.max else {
            throw CodexRemoteVoiceError.invalidSequence
        }
        let value = nextClientSequence
        nextClientSequence += 1
        return value
    }

    private func takeRequestID() throws -> Int64 {
        guard nextRequestID >= 0, nextRequestID < Int64.max else {
            throw CodexRemoteVoiceError.invalidSequence
        }
        let value = nextRequestID
        nextRequestID += 1
        return value
    }

    private func requiredInteger(
        _ object: [String: CodexRemoteVoiceJSON],
        _ key: String
    ) throws -> Int64 {
        guard let value = object[key]?.integerValue else {
            throw CodexRemoteVoiceError.malformedRemoteMessage
        }
        return value
    }

    private static func canonicalThreadID(_ value: String) throws -> String {
        guard value.utf8.count == 36,
              let uuid = UUID(uuidString: value),
              uuid.uuidString.lowercased() == value
        else {
            throw CodexRemoteVoiceError.invalidThreadID
        }
        return value
    }

    private static func validateSDP(_ value: String) throws {
        guard value.hasPrefix("v=0"),
              !value.utf8.contains(0),
              value.utf8.count <= CodexRemoteVoiceConstants.maximumSDPBytes
        else {
            throw CodexRemoteVoiceError.invalidSDPOffer
        }
    }

    private static func messageIDKey(
        _ value: CodexRemoteVoiceJSON
    ) -> String? {
        switch value {
        case .string(let string) where !string.isEmpty && string.utf8.count <= 256:
            return "s:\(string)"
        case .integer(let integer):
            return "i:\(integer)"
        default:
            return nil
        }
    }

    private static func safeDetail(
        _ value: String?,
        fallback: String
    ) -> String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = (trimmed?.isEmpty == false ? trimmed : fallback) ?? fallback
        return String(selected.prefix(500))
    }

    private static func voiceError(_ error: any Error) -> CodexRemoteVoiceError {
        if let value = error as? CodexRemoteVoiceError { return value }
        if error is CancellationError { return .cancelled }
        return .connectionFailed
    }

    private static func isAmbiguousTransportError(
        _ error: CodexRemoteVoiceError
    ) -> Bool {
        switch error {
        case .connectionFailed, .transportClosed, .cancelled,
             .malformedRemoteMessage, .oversizedWebSocketFrame,
             .invalidSequence, .invalidChunk, .streamIdentityMismatch:
            true
        default:
            false
        }
    }
}
