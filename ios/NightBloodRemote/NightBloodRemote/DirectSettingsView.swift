import SwiftUI
import UIKit

struct DirectSettingsView: View {
    @Bindable var setup: DirectCodexRemoteSetupModel
    @Bindable var voice: DirectVoiceSessionModel
    @Environment(\.dismiss) private var dismiss
    @State private var pairingCode = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Status", value: setup.statusLabel)
                    Text(setup.guidance)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let error = setup.errorMessage, !error.isEmpty {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    setupAction
                } header: {
                    Text("Private Codex Remote")
                } footer: {
                    Text("This controller uses your ChatGPT plan, this iPhone's Secure Enclave and Face ID. It opens no Mac or LAN listening port.")
                }

                if shouldShowPairingCode {
                    Section("One-time Mac code") {
                        TextField("ABCD-EFGH", text: $pairingCode)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .fontDesign(.monospaced)
                            .onChange(of: pairingCode) { _, value in
                                pairingCode = Self.normalisePairingInput(value)
                            }
                        Button("Claim code once") {
                            setup.submitPairingCode(pairingCode)
                        }
                        .disabled(setup.isBusy || pairingCode.count < 8)
                    }
                }

                if shouldShowEnvironments {
                    Section {
                        if setup.environments.isEmpty {
                            Text("No paired Mac has been loaded yet.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(
                                setup.environments,
                                id: \.stableListID
                            ) { environment in
                                Button {
                                    guard let id = environment.environmentID else {
                                        return
                                    }
                                    setup.selectEnvironment(id: id)
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(environment.displayLabel)
                                                .foregroundStyle(.primary)
                                            Text(environment.online == true
                                                ? "Online"
                                                : "Unavailable")
                                                .font(.caption)
                                                .foregroundStyle(
                                                    environment.online == true
                                                        ? .green : .secondary
                                                )
                                        }
                                        Spacer()
                                        if environment.environmentID
                                            == setup.selectedEnvironmentID
                                        {
                                            Image(systemName: "checkmark.circle.fill")
                                                .foregroundStyle(.green)
                                        }
                                    }
                                }
                                .disabled(environment.online != true)
                            }
                        }

                        Button("Refresh paired Macs") {
                            setup.loadEnvironments()
                        }
                        .disabled(setup.isBusy)

                        if setup.phase == .environmentSelected {
                            Button("Confirm this exact Mac") {
                                setup.confirmSelectedEnvironment()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(setup.isBusy)
                        }
                    } header: {
                        Text("Paired Mac")
                    } footer: {
                        Text("NightBlood never chooses a new Mac automatically. After confirmation, it reconnects only to that exact Remote environment identity.")
                    }
                }

                Section {
                    Picker(
                        "NightBlood",
                        selection: preferredVoiceBinding(for: .nightblood)
                    ) {
                        voiceOptions
                    }
                    .pickerStyle(.menu)
                    .accessibilityLabel("NightBlood voice")
                    .accessibilityValue(
                        voice.preferredVoice(for: .nightblood).displayName
                    )

                    Picker(
                        "Marshmallow",
                        selection: preferredVoiceBinding(for: .marshmallow)
                    ) {
                        voiceOptions
                    }
                    .pickerStyle(.menu)
                    .accessibilityLabel("Marshmallow voice")
                    .accessibilityValue(
                        voice.preferredVoice(for: .marshmallow).displayName
                    )
                } header: {
                    Text("Character voices")
                } footer: {
                    Text(voice.canChangeVoicePreferences
                        ? "Each character uses its chosen voice when the next conversation starts."
                        : "End the current conversation before changing character voices.")
                }
                .disabled(!voice.canChangeVoicePreferences)

                Section {
                    TextField(
                        "Codex task link or UUID",
                        text: $voice.taskReference,
                        axis: .vertical
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .fontDesign(.monospaced)
                    LabeledContent("Voice", value: voice.statusLabel)
                    if let error = voice.lastError, !error.isEmpty {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("Codex task")
                } footer: {
                    Text("A pasted link is reduced to its task UUID before storage. The task identity remains native; the face WebView receives only a WebRTC answer and never sees this ID, your Mac ID or any credential.")
                }
            }
            .navigationTitle("Connection")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        voice.refreshAvailability()
                        dismiss()
                    }
                }
            }
        }
        .background(
            DirectOAuthPresenterAnchor { controller in
                setup.installPresenter(controller)
            }
            .frame(width: 0, height: 0)
        )
        .task {
            setup.refreshPersistedState()
        }
        .onChange(of: setup.phase) {
            voice.refreshAvailability()
        }
    }

    @ViewBuilder
    private var setupAction: some View {
        switch setup.phase {
        case .signedOut:
            Button("Sign in to ChatGPT") { setup.signIn() }
        case .signInRefreshRequired:
            Button("Refresh ChatGPT sign-in") { setup.refreshSignIn() }
        case .signedIn:
            #if targetEnvironment(simulator)
            Text("Controller enrolment requires a physical iPhone with Face ID.")
                .font(.caption)
                .foregroundStyle(.secondary)
            #else
            Button("Enrol this iPhone") { setup.enrolController() }
            #endif
        case .pairingOutcomeUnknown, .pairingProvisional,
             .environmentSelectionRequired, .selectedEnvironmentUnavailable,
             .ready:
            Button("Refresh paired Macs") { setup.loadEnvironments() }
                .disabled(setup.isBusy)
        case .checking, .signingIn, .refreshingSignIn, .enrolling,
             .submittingPairingCode, .loadingEnvironments,
             .confirmingEnvironment, .cancelling:
            HStack {
                ProgressView()
                Text(setup.statusLabel)
            }
            Button("Cancel", role: .cancel) {
                setup.cancelCurrentOperation()
            }
        case .enrolmentOutcomeUnknown, .enrolmentReviewRequired,
             .failed:
            Button("Re-read saved setup state") {
                setup.refreshPersistedState()
            }
            .disabled(setup.isBusy)
        case .inactive:
            Text("Return to NightBlood in the foreground to continue.")
                .font(.caption)
        case .manualPairingCodeRequired, .environmentSelected:
            EmptyView()
        }
    }

    private var shouldShowPairingCode: Bool {
        setup.phase == .manualPairingCodeRequired
    }

    private func preferredVoiceBinding(
        for face: DirectFaceSkin
    ) -> Binding<CodexRemoteVoiceName> {
        Binding(
            get: { voice.preferredVoice(for: face) },
            set: { voice.setPreferredVoice($0, for: face) }
        )
    }

    @ViewBuilder
    private var voiceOptions: some View {
        ForEach(CodexRemoteVoiceName.allCases) { option in
            Text(option.displayName).tag(option)
        }
    }

    private var shouldShowEnvironments: Bool {
        switch setup.phase {
        case .pairingOutcomeUnknown, .pairingProvisional,
             .loadingEnvironments, .environmentSelectionRequired,
             .environmentSelected, .confirmingEnvironment,
             .selectedEnvironmentUnavailable, .ready:
            true
        default:
            false
        }
    }

    private static func normalisePairingInput(_ input: String) -> String {
        let characters = input.uppercased().filter {
            $0.isASCII && ($0.isLetter || $0.isNumber)
        }
        let bounded = String(characters.prefix(8))
        guard bounded.count > 4 else { return bounded }
        let split = bounded.index(bounded.startIndex, offsetBy: 4)
        return String(bounded[..<split]) + "-" + String(bounded[split...])
    }
}

private extension CodexRemotePairedEnvironment {
    var stableListID: String {
        environmentID ?? "missing-\(name ?? displayName ?? hostName ?? "environment")"
    }

    var displayLabel: String {
        for candidate in [displayName, name, hostName] {
            if let candidate, !candidate.isEmpty { return candidate }
        }
        return "Codex Mac"
    }
}

private struct DirectOAuthPresenterAnchor: UIViewControllerRepresentable {
    let onReady: @MainActor (UIViewController) -> Void

    func makeUIViewController(context: Context) -> AnchorViewController {
        let controller = AnchorViewController()
        controller.onReady = onReady
        return controller
    }

    func updateUIViewController(
        _ uiViewController: AnchorViewController,
        context: Context
    ) {
        uiViewController.onReady = onReady
    }

    @MainActor
    final class AnchorViewController: UIViewController {
        var onReady: (@MainActor (UIViewController) -> Void)?

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            onReady?(self)
        }
    }
}
