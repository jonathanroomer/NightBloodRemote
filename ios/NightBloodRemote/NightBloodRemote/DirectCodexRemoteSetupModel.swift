import Foundation
import Observation
@preconcurrency import UIKit

protocol DirectCodexPlanOAuthServing: Sendable {
    func signIn(
        timeout: Duration,
        presentSafari: CodexOAuthSafariPresentation
    ) async throws -> CodexPlanTokens
    func refreshStoredTokens() async throws -> CodexPlanTokens
    func storedTokens() async throws -> CodexPlanTokens?
    func cancel() async
}

extension CodexPlanOAuth: DirectCodexPlanOAuthServing {}

protocol DirectCodexRemoteEnrolling: Sendable {
    func enrol(
        ordinaryAccessToken: String,
        stepUpTimeout: Duration,
        presentSafari: CodexOAuthSafariPresentation
    ) async throws -> CodexRemoteEnrolmentMetadata
    func storedMetadata() async throws -> CodexRemoteEnrolmentMetadata?
    func cancel() async
}

extension CodexRemoteEnrolment: DirectCodexRemoteEnrolling {}

protocol DirectCodexRemotePairingClaiming: Sendable {
    func claim(code: String) async throws -> CodexRemotePairingReceipt
}

extension CodexRemoteManualPairingClaim: DirectCodexRemotePairingClaiming {}

protocol DirectCodexRemoteEnvironmentServing:
    CodexRemoteVoiceEnvironmentProviding
{
    func list() async throws -> CodexRemoteEnvironmentListing
    func verifyAndConfirm(
        environmentID: String
    ) async throws -> CodexRemotePairedEnvironment
}

extension CodexRemotePairedEnvironmentClient:
    DirectCodexRemoteEnvironmentServing
{}

protocol DirectCodexRemoteSessionServing:
    CodexRemoteVoiceControllerSessionProviding
{
    func currentValidSession() async -> CodexRemoteControllerSession?
    func refresh(authenticationReason: String) async throws
        -> CodexRemoteControllerSession
    func invalidateSession() async
}

extension CodexRemoteControllerSessionManager:
    DirectCodexRemoteSessionServing
{}

protocol DirectCodexRemoteSetupClientBuilding: Sendable {
    func makePairingClaim(
        account: CodexRemoteAccountContext,
        metadata: CodexRemoteEnrolmentMetadata
    ) -> any DirectCodexRemotePairingClaiming

    func makeEnvironmentClient(
        account: CodexRemoteAccountContext,
        metadata: CodexRemoteEnrolmentMetadata
    ) -> any DirectCodexRemoteEnvironmentServing

    func makeSessionManager(
        account: CodexRemoteAccountContext,
        metadata: CodexRemoteEnrolmentMetadata
    ) -> any DirectCodexRemoteSessionServing
}

struct DirectCodexRemoteSetupClientFactory:
    DirectCodexRemoteSetupClientBuilding
{
    private let transport: any CodexRemoteHTTPTransport
    private let identityProvider: any CodexRemoteDeviceIdentityProviding
    private let lifecycleStore: any CodexRemotePairingLifecycleStoring
    private let now: @Sendable () -> Date

    init(
        transport: any CodexRemoteHTTPTransport,
        identityProvider: any CodexRemoteDeviceIdentityProviding,
        lifecycleStore: any CodexRemotePairingLifecycleStoring,
        now: @escaping @Sendable () -> Date
    ) {
        self.transport = transport
        self.identityProvider = identityProvider
        self.lifecycleStore = lifecycleStore
        self.now = now
    }

    func makePairingClaim(
        account: CodexRemoteAccountContext,
        metadata: CodexRemoteEnrolmentMetadata
    ) -> any DirectCodexRemotePairingClaiming {
        CodexRemoteManualPairingClaim(
            account: account,
            metadata: metadata,
            transport: transport,
            lifecycleStore: lifecycleStore,
            now: now
        )
    }

    func makeEnvironmentClient(
        account: CodexRemoteAccountContext,
        metadata: CodexRemoteEnrolmentMetadata
    ) -> any DirectCodexRemoteEnvironmentServing {
        CodexRemotePairedEnvironmentClient(
            account: account,
            metadata: metadata,
            transport: transport,
            lifecycleStore: lifecycleStore,
            now: now
        )
    }

    func makeSessionManager(
        account: CodexRemoteAccountContext,
        metadata: CodexRemoteEnrolmentMetadata
    ) -> any DirectCodexRemoteSessionServing {
        CodexRemoteControllerSessionManager(
            account: account,
            metadata: metadata,
            transport: transport,
            identityProvider: identityProvider,
            pairingLifecycleStore: lifecycleStore,
            now: now
        )
    }
}

enum DirectCodexRemoteSetupError: Error, LocalizedError, Sendable {
    case operationInProgress
    case applicationNotActive
    case browserUnavailable
    case signInRequired
    case signInRefreshRequired
    case enrolmentRequired
    case environmentListRequired
    case environmentSelectionRequired
    case voiceContextNotReady

    var errorDescription: String? {
        switch self {
        case .operationInProgress:
            "Finish or cancel the current setup step first."
        case .applicationNotActive:
            "Open NightBlood in the foreground before continuing setup."
        case .browserUnavailable:
            "NightBlood needs its visible Safari sign-in sheet before continuing."
        case .signInRequired:
            "Sign in to your ChatGPT plan before enrolling this iPhone."
        case .signInRefreshRequired:
            "Refresh the saved ChatGPT sign-in before continuing."
        case .enrolmentRequired:
            "Enrol this iPhone as a Codex Remote controller first."
        case .environmentListRequired:
            "Refresh the paired-Mac list before choosing a Mac."
        case .environmentSelectionRequired:
            "Choose the exact online Mac you want NightBlood to control."
        case .voiceContextNotReady:
            "Finish controller pairing and confirm the selected Mac before starting Voice."
        }
    }
}

/// Opaque native hand-off to the bounded voice transport. No token or raw
/// App Server operation is exposed as a property, Codable value or Objective-C
/// bridge, so this value must never be placed in the face WebView.
struct DirectCodexRemoteVoiceContext: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    private let account: CodexRemoteAccountContext
    private let metadata: CodexRemoteEnrolmentMetadata
    private let environmentProvider: any CodexRemoteVoiceEnvironmentProviding
    private let sessionProvider: any CodexRemoteVoiceControllerSessionProviding
    private let webSocketTransport: any CodexRemoteWebSocketTransport
    private let identityProvider: any CodexRemoteDeviceIdentityProviding
    private let attestationProvider: any CodexRemoteVoiceAttestationProviding
    private let foregroundProvider: any CodexRemoteVoiceForegroundProviding
    private let now: @Sendable () -> Date

    init(
        account: CodexRemoteAccountContext,
        metadata: CodexRemoteEnrolmentMetadata,
        environmentProvider: any CodexRemoteVoiceEnvironmentProviding,
        sessionProvider: any CodexRemoteVoiceControllerSessionProviding,
        webSocketTransport: any CodexRemoteWebSocketTransport,
        identityProvider: any CodexRemoteDeviceIdentityProviding,
        attestationProvider: any CodexRemoteVoiceAttestationProviding,
        foregroundProvider: any CodexRemoteVoiceForegroundProviding,
        now: @escaping @Sendable () -> Date
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
    }

    /// The only credential-consuming surface. Callers receive the bounded
    /// native actor, never the ordinary or controller bearer values it owns.
    func makeVoiceTransport() -> CodexRemoteVoiceTransport {
        CodexRemoteVoiceTransport(
            account: account,
            metadata: metadata,
            environmentProvider: environmentProvider,
            sessionProvider: sessionProvider,
            webSocketTransport: webSocketTransport,
            identityProvider: identityProvider,
            attestationProvider: attestationProvider,
            foregroundProvider: foregroundProvider,
            now: now
        )
    }

    var description: String { "DirectCodexRemoteVoiceContext(<redacted>)" }
    var debugDescription: String { description }
}

@MainActor
@Observable
final class DirectCodexRemoteSetupModel {
    enum Phase: Equatable, Sendable {
        case checking
        case inactive
        case signedOut
        case signInRefreshRequired
        case signingIn
        case refreshingSignIn
        case signedIn
        case enrolling
        case enrolmentOutcomeUnknown
        case enrolmentReviewRequired
        case manualPairingCodeRequired
        case submittingPairingCode
        case pairingOutcomeUnknown
        case pairingProvisional
        case loadingEnvironments
        case environmentSelectionRequired
        case environmentSelected
        case confirmingEnvironment
        case selectedEnvironmentUnavailable
        case ready
        case cancelling
        case failed

        var label: String {
            switch self {
            case .checking: "Checking setup"
            case .inactive: "NightBlood is paused"
            case .signedOut: "Sign in to ChatGPT"
            case .signInRefreshRequired: "Refresh ChatGPT sign-in"
            case .signingIn: "Signing in"
            case .refreshingSignIn: "Refreshing sign-in"
            case .signedIn: "Signed in — enrol this iPhone"
            case .enrolling: "Enrolling this iPhone"
            case .enrolmentOutcomeUnknown: "Enrolment needs review"
            case .enrolmentReviewRequired: "Enrolment response needs review"
            case .manualPairingCodeRequired: "Enter the code shown by Codex"
            case .submittingPairingCode: "Claiming the pairing code"
            case .pairingOutcomeUnknown: "Pairing needs verification"
            case .pairingProvisional: "Pairing received — verify the Mac"
            case .loadingEnvironments: "Refreshing paired Macs"
            case .environmentSelectionRequired: "Choose the exact Mac"
            case .environmentSelected: "Confirm the selected Mac"
            case .confirmingEnvironment: "Confirming the selected Mac"
            case .selectedEnvironmentUnavailable: "Selected Mac unavailable"
            case .ready: "Ready for NightBlood Voice"
            case .cancelling: "Stopping setup safely"
            case .failed: "Setup needs attention"
            }
        }

        var guidance: String {
            switch self {
            case .checking:
                "NightBlood is reading device-only setup records."
            case .inactive:
                "Setup and Voice stay disconnected while NightBlood is not in the foreground."
            case .signedOut:
                "This signs in to your ChatGPT plan; it does not pair the Mac."
            case .signInRefreshRequired:
                "Your saved sign-in exists but its access token needs refreshing."
            case .signingIn, .refreshingSignIn:
                "Complete the visible browser step and return to NightBlood."
            case .signedIn:
                "Enrolment creates this iPhone's Face ID-protected controller key."
            case .enrolling:
                "Safari authorisation and Face ID are required. This step is never retried automatically."
            case .enrolmentOutcomeUnknown:
                "Enrolment may have completed. Review its saved state; do not enrol again."
            case .enrolmentReviewRequired:
                "The server answered, but NightBlood could not safely prove the final controller state."
            case .manualPairingCodeRequired:
                "Use the one-time code shown by Codex Remote on the Mac."
            case .submittingPairingCode:
                "This one-time mutation is sent once and is never automatically retried."
            case .pairingOutcomeUnknown:
                "Pairing may have completed. Refresh paired Macs instead of resubmitting the code."
            case .pairingProvisional:
                "The HTTP response is provisional until the selected Mac appears in a fresh paired list."
            case .loadingEnvironments:
                "NightBlood is reading only environments paired to this controller."
            case .environmentSelectionRequired:
                "Selection is never automatic, even if only one Mac is online."
            case .environmentSelected:
                "Confirming binds future connections to this exact environment ID."
            case .confirmingEnvironment:
                "NightBlood is re-reading the paired list before saving the binding."
            case .selectedEnvironmentUnavailable:
                "The saved Mac is offline or no longer paired. Choose only from a fresh native list."
            case .ready:
                "Every Voice connection will revalidate this same Mac before opening WSS."
            case .cancelling:
                "Backgrounding or cancellation stops the active setup operation."
            case .failed:
                "Read the message below, then refresh setup state before trying another step."
            }
        }

        var isBusy: Bool {
            switch self {
            case .checking, .signingIn, .refreshingSignIn, .enrolling,
                 .submittingPairingCode, .loadingEnvironments,
                 .confirmingEnvironment, .cancelling:
                true
            default:
                false
            }
        }
    }

    private(set) var phase: Phase = .checking
    private(set) var errorMessage: String?
    private(set) var environments: [CodexRemotePairedEnvironment] = []
    private(set) var selectedEnvironmentID: String?

    var statusLabel: String { phase.label }
    var guidance: String { phase.guidance }
    var isBusy: Bool { phase.isBusy }

    @ObservationIgnored private let oauth: any DirectCodexPlanOAuthServing
    @ObservationIgnored private let enrolment: any DirectCodexRemoteEnrolling
    @ObservationIgnored private let lifecycleStore:
        any CodexRemotePairingLifecycleStoring
    @ObservationIgnored private let clientFactory:
        any DirectCodexRemoteSetupClientBuilding
    @ObservationIgnored private let identityProvider:
        any CodexRemoteDeviceIdentityProviding
    @ObservationIgnored private let webSocketTransport:
        any CodexRemoteWebSocketTransport
    @ObservationIgnored private let attestationProvider:
        any CodexRemoteVoiceAttestationProviding
    @ObservationIgnored private let foregroundProvider:
        any CodexRemoteVoiceForegroundProviding
    @ObservationIgnored private let now: @Sendable () -> Date

    @ObservationIgnored private weak var presentationAnchor: UIViewController?
    @ObservationIgnored private var presenter:
        CodexOAuthSafariViewControllerPresenter?
    @ObservationIgnored private var injectedSafariPresentation:
        CodexOAuthSafariPresentation?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var backgroundWatcher: Task<Void, Never>?
    @ObservationIgnored private var foregroundWatcher: Task<Void, Never>?
    @ObservationIgnored private var applicationActive: Bool

    @ObservationIgnored private var account: CodexRemoteAccountContext?
    @ObservationIgnored private var metadata: CodexRemoteEnrolmentMetadata?
    @ObservationIgnored private var environmentClient:
        (any DirectCodexRemoteEnvironmentServing)?
    @ObservationIgnored private var sessionManager:
        (any DirectCodexRemoteSessionServing)?

    init(
        oauth: any DirectCodexPlanOAuthServing = CodexPlanOAuth(),
        enrolment: (any DirectCodexRemoteEnrolling)? = nil,
        transport: any CodexRemoteHTTPTransport =
            CodexRemoteURLSessionTransport(),
        identityProvider: any CodexRemoteDeviceIdentityProviding =
            CodexRemoteSecureEnclaveIdentityProvider(),
        metadataStore: any CodexRemoteEnrolmentMetadataStoring =
            CodexRemoteEnrolmentMetadataStore(),
        lifecycleStore: any CodexRemotePairingLifecycleStoring =
            CodexRemotePairingLifecycleStore.shared,
        clientFactory: (any DirectCodexRemoteSetupClientBuilding)? = nil,
        webSocketTransport: any CodexRemoteWebSocketTransport =
            CodexRemoteURLSessionWebSocketTransport(),
        attestationProvider: any CodexRemoteVoiceAttestationProviding =
            CodexRemoteDeviceCheckAttestationProvider(),
        foregroundProvider: any CodexRemoteVoiceForegroundProviding =
            CodexRemoteVoiceApplicationForegroundProvider(),
        safariPresentation: CodexOAuthSafariPresentation? = nil,
        observeBackground: Bool = true,
        initiallyActive: Bool? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.oauth = oauth
        self.identityProvider = identityProvider
        self.lifecycleStore = lifecycleStore
        self.now = now
        self.enrolment = enrolment ?? CodexRemoteEnrolment(
            transport: transport,
            identityProvider: identityProvider,
            metadataStore: metadataStore,
            now: now
        )
        self.clientFactory = clientFactory
            ?? DirectCodexRemoteSetupClientFactory(
                transport: transport,
                identityProvider: identityProvider,
                lifecycleStore: lifecycleStore,
                now: now
            )
        self.webSocketTransport = webSocketTransport
        self.attestationProvider = attestationProvider
        self.foregroundProvider = foregroundProvider
        applicationActive = initiallyActive
            ?? (UIApplication.shared.applicationState == .active)
        injectedSafariPresentation = safariPresentation

        if observeBackground {
            backgroundWatcher = Task { @MainActor [weak self] in
                for await _ in NotificationCenter.default.notifications(
                    named: UIApplication.didEnterBackgroundNotification
                ) {
                    guard !Task.isCancelled else { return }
                    self?.applicationDidEnterBackground()
                }
            }
            foregroundWatcher = Task { @MainActor [weak self] in
                for await _ in NotificationCenter.default.notifications(
                    named: UIApplication.didBecomeActiveNotification
                ) {
                    guard !Task.isCancelled else { return }
                    self?.applicationDidBecomeActive()
                }
            }
        }
    }

    deinit {
        operation?.cancel()
        backgroundWatcher?.cancel()
        foregroundWatcher?.cancel()
    }

    func installPresenter(_ viewController: UIViewController) {
        guard presentationAnchor !== viewController else { return }
        // The settings sheet may first appear while its persisted setup state
        // is still being read. Installing the initial presentation anchor is
        // independent of that operation and must not lose its only
        // `viewDidAppear` callback. Once a presenter exists, keep it stable
        // throughout any active OAuth/enrolment operation.
        guard presenter == nil || !isBusy else { return }
        presentationAnchor = viewController
        presenter = CodexOAuthSafariViewControllerPresenter(
            presentingViewController: viewController
        )
    }

    func refreshPersistedState() {
        // Launch and the Settings sheet can request the same read-only refresh
        // at nearly the same time. The in-flight reconciliation already owns
        // the result, so make this one refresh entry point idempotent instead
        // of briefly replacing useful state with an operation-in-progress
        // failure. Mutating setup operations remain strictly single-owner.
        guard operation == nil else { return }
        startOperation(phase: .checking) { model in
            await model.reconcilePersistedState()
        }
    }

    func signIn() {
        guard let presentation = safariPresentation() else {
            fail(DirectCodexRemoteSetupError.browserUnavailable)
            return
        }
        startOperation(phase: .signingIn) { model in
            do {
                _ = try await model.oauth.signIn(
                    timeout: .seconds(180),
                    presentSafari: presentation
                )
                await model.reconcilePersistedState()
            } catch let error as CodexPlanOAuthError where error.isCancellation {
                await model.reconcilePersistedState()
            } catch {
                guard model.acceptsOperationResults else { return }
                model.fail(error)
            }
        }
    }

    func refreshSignIn() {
        startOperation(phase: .refreshingSignIn) { model in
            do {
                _ = try await model.oauth.refreshStoredTokens()
                await model.reconcilePersistedState()
            } catch let error as CodexPlanOAuthError where error.isCancellation {
                await model.reconcilePersistedState()
            } catch {
                guard model.acceptsOperationResults else { return }
                model.fail(error)
            }
        }
    }

    func enrolController() {
        guard let account else {
            fail(
                phase == .signInRefreshRequired
                    ? DirectCodexRemoteSetupError.signInRefreshRequired
                    : DirectCodexRemoteSetupError.signInRequired
            )
            return
        }
        guard let presentation = safariPresentation() else {
            fail(DirectCodexRemoteSetupError.browserUnavailable)
            return
        }
        startOperation(phase: .enrolling) { model in
            do {
                _ = try await model.enrolment.enrol(
                    ordinaryAccessToken: account.accessToken,
                    stepUpTimeout: .seconds(600),
                    presentSafari: presentation
                )
                await model.reconcilePersistedState()
            } catch let error as CodexRemoteEnrolmentError
                where error.isCancellation
            {
                await model.reconcilePersistedState()
            } catch {
                // The persisted enrolment state, not the thrown transport
                // detail, decides whether this is retryable, unknown or review.
                await model.reconcilePersistedState(fallbackError: error)
            }
        }
    }

    func submitPairingCode(_ code: String) {
        guard let account, let metadata, metadata.state == .enrolled else {
            fail(DirectCodexRemoteSetupError.enrolmentRequired)
            return
        }
        let claim = clientFactory.makePairingClaim(
            account: account,
            metadata: metadata
        )
        startOperation(phase: .submittingPairingCode) { model in
            do {
                _ = try await claim.claim(code: code)
                await model.reconcilePersistedState()
            } catch {
                // A sent claim is always reconciled from its durable unknown
                // state; this method never creates a replacement claim itself.
                await model.reconcilePersistedState(fallbackError: error)
            }
        }
    }

    func loadEnvironments() {
        guard let environmentClient else {
            fail(DirectCodexRemoteSetupError.enrolmentRequired)
            return
        }
        startOperation(phase: .loadingEnvironments) { model in
            do {
                let listing = try await environmentClient.list()
                guard model.acceptsOperationResults else { return }
                model.environments = listing.environments
                try await model.applyEnvironmentListing(listing)
            } catch is CancellationError {
                await model.reconcilePersistedState()
            } catch {
                guard model.acceptsOperationResults else { return }
                model.fail(error)
            }
        }
    }

    /// Called only by a native environment row selected from `environments`.
    /// It does not persist or confirm anything by itself.
    func selectEnvironment(id: String) {
        guard applicationActive else {
            phase = .inactive
            errorMessage = DirectCodexRemoteSetupError.applicationNotActive
                .localizedDescription
            return
        }
        guard operation == nil else {
            fail(DirectCodexRemoteSetupError.operationInProgress)
            return
        }
        do {
            _ = try CodexRemoteEnvironmentListing(
                environments: environments
            ).selecting(environmentID: id)
            selectedEnvironmentID = id
            phase = .environmentSelected
            errorMessage = nil
        } catch {
            fail(error)
        }
    }

    func confirmSelectedEnvironment() {
        guard let environmentClient else {
            fail(DirectCodexRemoteSetupError.enrolmentRequired)
            return
        }
        guard let selectedEnvironmentID else {
            fail(DirectCodexRemoteSetupError.environmentSelectionRequired)
            return
        }
        startOperation(phase: .confirmingEnvironment) { model in
            do {
                let confirmed = try await environmentClient.verifyAndConfirm(
                    environmentID: selectedEnvironmentID
                )
                guard model.acceptsOperationResults else { return }
                model.replaceEnvironment(with: confirmed)
                model.selectedEnvironmentID = selectedEnvironmentID
                model.phase = .ready
                model.errorMessage = nil
            } catch is CancellationError {
                await model.reconcilePersistedState()
            } catch {
                guard model.acceptsOperationResults else { return }
                model.fail(error)
            }
        }
    }

    /// Builds only an opaque native dependency bundle. The returned value has
    /// no token getters and must be consumed by native Voice code, never JS.
    func makeVoiceContext() throws -> DirectCodexRemoteVoiceContext {
        guard applicationActive,
              phase == .ready,
              let account,
              let metadata,
              metadata.state == .enrolled,
              selectedEnvironmentID?.isEmpty == false,
              let environmentClient,
              let sessionManager
        else {
            throw DirectCodexRemoteSetupError.voiceContextNotReady
        }
        return DirectCodexRemoteVoiceContext(
            account: account,
            metadata: metadata,
            environmentProvider: environmentClient,
            sessionProvider: sessionManager,
            webSocketTransport: webSocketTransport,
            identityProvider: identityProvider,
            attestationProvider: attestationProvider,
            foregroundProvider: foregroundProvider,
            now: now
        )
    }

    func cancelCurrentOperation() {
        cancelActiveOperation(forBackground: false)
    }

    func applicationDidEnterBackground() {
        cancelActiveOperation(forBackground: true)
    }

    func applicationDidBecomeActive() {
        applicationActive = true
        if phase == .inactive {
            phase = .checking
            errorMessage = nil
        }
    }

    private func startOperation(
        phase requestedPhase: Phase,
        _ body: @escaping @MainActor @Sendable (
            DirectCodexRemoteSetupModel
        ) async -> Void
    ) {
        guard applicationActive else {
            phase = .inactive
            errorMessage = DirectCodexRemoteSetupError.applicationNotActive
                .localizedDescription
            return
        }
        guard operation == nil else {
            fail(DirectCodexRemoteSetupError.operationInProgress)
            return
        }
        phase = requestedPhase
        errorMessage = nil
        operation = Task { @MainActor [weak self] in
            guard let self else { return }
            await body(self)
            operation = nil
            if phase == .cancelling {
                phase = applicationActive ? .checking : .inactive
            }
        }
    }

    private func cancelActiveOperation(forBackground: Bool) {
        if forBackground {
            applicationActive = false
        }
        let active = operation
        if active != nil {
            phase = .cancelling
            errorMessage = nil
            active?.cancel()
            Task { [oauth, enrolment] in
                await oauth.cancel()
                await enrolment.cancel()
            }
        }
        if let sessionManager {
            Task { await sessionManager.invalidateSession() }
        }
        if forBackground {
            // Drop every in-memory ordinary/session bearer owner held by this
            // model. Device-only stores remain and are reread only after unlock.
            clearControllerContext()
            phase = .inactive
            errorMessage = nil
        }
    }

    private func reconcilePersistedState(
        fallbackError: Error? = nil
    ) async {
        guard acceptsOperationResults else { return }
        do {
            guard let tokens = try await oauth.storedTokens() else {
                guard acceptsOperationResults else { return }
                clearControllerContext()
                phase = .signedOut
                errorMessage = nil
                return
            }
            guard acceptsOperationResults else { return }
            let parsedAccount: CodexRemoteAccountContext
            do {
                parsedAccount = try CodexRemoteAccountContext.parse(
                    accessToken: tokens.accessToken,
                    now: now()
                )
            } catch CodexRemoteEnrolmentError.ordinaryAccessTokenNeedsRefresh {
                clearControllerContext()
                phase = .signInRefreshRequired
                errorMessage = fallbackError.map(Self.message(for:))
                return
            }
            account = parsedAccount

            guard let storedMetadata = try await enrolment.storedMetadata() else {
                guard acceptsOperationResults else { return }
                metadata = nil
                environmentClient = nil
                sessionManager = nil
                environments = []
                selectedEnvironmentID = nil
                phase = .signedIn
                errorMessage = fallbackError.map(Self.message(for:))
                return
            }
            guard acceptsOperationResults else { return }
            metadata = storedMetadata
            guard storedMetadata.accountUserID == parsedAccount.accountUserID
                    || storedMetadata.accountUserID == parsedAccount.tokenUserID
            else {
                phase = .enrolmentReviewRequired
                errorMessage = CodexRemoteControllerError.accountMismatch
                    .localizedDescription
                return
            }

            switch storedMetadata.state {
            case .finishInFlight, .finishUnknown:
                environmentClient = nil
                sessionManager = nil
                phase = .enrolmentOutcomeUnknown
                errorMessage = fallbackError.map(Self.message(for:))
                return
            case .finishReturnedUnvalidated, .reviewRequired,
                 .authorising, .cleanupRequired:
                environmentClient = nil
                sessionManager = nil
                phase = .enrolmentReviewRequired
                errorMessage = fallbackError.map(Self.message(for:))
                return
            case .enrolled:
                break
            }

            let environmentClient = clientFactory.makeEnvironmentClient(
                account: parsedAccount,
                metadata: storedMetadata
            )
            let sessionManager = clientFactory.makeSessionManager(
                account: parsedAccount,
                metadata: storedMetadata
            )
            self.environmentClient = environmentClient
            self.sessionManager = sessionManager

            let pairing = try await lifecycleStore.load(
                accountUserID: storedMetadata.accountUserID,
                clientID: storedMetadata.clientID
            )
            guard acceptsOperationResults else { return }
            switch pairing?.state {
            case nil, .ready:
                selectedEnvironmentID = nil
                phase = .manualPairingCodeRequired
            case .inFlight, .outcomeUnknown:
                selectedEnvironmentID = nil
                phase = .pairingOutcomeUnknown
            case .responseReceivedUnverified:
                selectedEnvironmentID = nil
                phase = .pairingProvisional
            case .confirmed:
                guard let environmentID = pairing?.confirmedEnvironmentID,
                      !environmentID.isEmpty
                else {
                    phase = .enrolmentReviewRequired
                    errorMessage = CodexRemoteControllerError
                        .invalidPairingLifecycle.localizedDescription
                    return
                }
                selectedEnvironmentID = environmentID
                // A confirmed binding is the only Mac NightBlood may restore
                // automatically. Refresh the controller-scoped list on every
                // foreground setup pass and require that exact environment ID
                // to be present and online. Never fall back to another Mac,
                // even when it is the only environment returned.
                phase = .loadingEnvironments
                let listing = try await environmentClient.list()
                guard acceptsOperationResults else { return }
                environments = listing.environments
                try await applyEnvironmentListing(listing)
            }
            if errorMessage == nil {
                errorMessage = fallbackError.map(Self.message(for:))
            }
        } catch {
            guard acceptsOperationResults else { return }
            fail(fallbackError ?? error)
        }
    }

    private func applyEnvironmentListing(
        _ listing: CodexRemoteEnvironmentListing
    ) async throws {
        guard acceptsOperationResults else { throw CancellationError() }
        guard let metadata else {
            throw DirectCodexRemoteSetupError.enrolmentRequired
        }
        let pairing = try await lifecycleStore.load(
            accountUserID: metadata.accountUserID,
            clientID: metadata.clientID
        )
        guard acceptsOperationResults else { throw CancellationError() }
        if pairing?.state == .confirmed,
           let savedID = pairing?.confirmedEnvironmentID,
           !savedID.isEmpty
        {
            selectedEnvironmentID = savedID
            do {
                _ = try listing.selecting(environmentID: savedID)
                phase = .ready
                errorMessage = nil
            } catch {
                phase = .selectedEnvironmentUnavailable
                errorMessage = Self.message(for: error)
            }
            return
        }
        selectedEnvironmentID = nil
        phase = .environmentSelectionRequired
        errorMessage = listing.environments.isEmpty
            ? "No Mac is currently paired to this iPhone controller."
            : nil
    }

    private func replaceEnvironment(with environment: CodexRemotePairedEnvironment) {
        guard let identifier = environment.environmentID else { return }
        if let index = environments.firstIndex(where: {
            $0.environmentID == identifier
        }) {
            environments[index] = environment
        } else {
            environments.append(environment)
        }
    }

    private func clearControllerContext() {
        account = nil
        metadata = nil
        environmentClient = nil
        sessionManager = nil
        environments = []
        selectedEnvironmentID = nil
    }

    private var acceptsOperationResults: Bool {
        applicationActive && operation != nil && !Task.isCancelled
    }

    private func safariPresentation() -> CodexOAuthSafariPresentation? {
        injectedSafariPresentation ?? presenter?.presentation()
    }

    private func fail(_ error: Error) {
        phase = .failed
        errorMessage = Self.message(for: error)
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription
            ?? "Codex Remote setup could not be completed safely."
    }
}
