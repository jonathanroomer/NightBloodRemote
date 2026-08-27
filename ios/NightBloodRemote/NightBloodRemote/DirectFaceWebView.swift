@preconcurrency import WebKit
import SwiftUI

struct DirectFaceWebView: UIViewRepresentable {
    let model: DirectVoiceSessionModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.addScriptMessageHandler(
            context.coordinator,
            contentWorld: .page,
            name: "nightbloodDirect"
        )
        configuration.userContentController.add(
            context.coordinator,
            contentWorld: .page,
            name: "nightbloodEvents"
        )

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.isOpaque = true
        webView.underPageBackgroundColor = .black
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isUserInteractionEnabled = false
        webView.allowsLinkPreview = false
        webView.isInspectable = false
        context.coordinator.webView = webView
        context.coordinator.loadFace()
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.model = model
    }

    static func dismantleUIView(
        _ webView: WKWebView,
        coordinator: Coordinator
    ) {
        webView.configuration.userContentController
            .removeScriptMessageHandler(
                forName: "nightbloodDirect",
                contentWorld: .page
            )
        webView.configuration.userContentController
            .removeScriptMessageHandler(
                forName: "nightbloodEvents",
                contentWorld: .page
            )
        webView.stopLoading()
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandlerWithReply,
        WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate,
        DirectFaceJavaScriptControlling
    {
        var model: DirectVoiceSessionModel
        weak var webView: WKWebView?
        private var trustedPage: URL?
        private var attached = false
        private var desiredSkin: DirectFaceSkin = .nightblood
        private var appliedSkin: DirectFaceSkin?
        private var skinApplyTask: Task<Void, Never>?
        private var skinRunID: UUID?
        private var pageGeneration: UInt64 = 0

        init(model: DirectVoiceSessionModel) {
            self.model = model
        }

        func loadFace() {
            guard let webView,
                  let page = Bundle.main.url(
                      forResource: "ios-direct-bundled",
                      withExtension: "html",
                      subdirectory: "dist-ios-direct"
                  )
            else {
                model.state = .failed
                model.lastError = "The signed direct NightBlood face is missing."
                return
            }
            trustedPage = page.standardizedFileURL
            attached = false
            appliedSkin = nil
            pageGeneration = pageGeneration == UInt64.max
                ? 0 : pageGeneration + 1
            skinApplyTask?.cancel()
            skinApplyTask = nil
            skinRunID = nil
            webView.loadFileURL(
                page,
                allowingReadAccessTo: page.deletingLastPathComponent()
            )
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage,
            replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void
        ) {
            guard message.name == "nightbloodDirect",
                  isTrusted(message)
            else {
                replyHandler(nil, "Untrusted NightBlood controller frame.")
                return
            }
            guard let body = message.body as? [String: Any],
                  let operation = body["operation"] as? String
            else {
                replyHandler(nil, "Invalid NightBlood controller request.")
                return
            }
            switch operation {
            case "start":
                guard Set(body.keys) == Set(["operation", "sdpOffer"]),
                      let sdp = body["sdpOffer"] as? String,
                      sdp.utf8.count <= CodexRemoteVoiceConstants.maximumSDPBytes
                else {
                    replyHandler(nil, "Invalid WebRTC offer.")
                    return
                }
                Task { @MainActor [weak self] in
                    guard let self else {
                        replyHandler(nil, "NightBlood controller closed.")
                        return
                    }
                    do {
                        let result = try await model.bridgeStart(sdpOffer: sdp)
                        replyHandler([
                            "sdp": result.sdpAnswer,
                            "serverStarted": result.serverStarted,
                        ], nil)
                    } catch {
                        replyHandler(nil, Self.message(for: error))
                    }
                }
            case "stop":
                guard Set(body.keys) == Set(["operation"]) else {
                    replyHandler(nil, "Invalid Voice stop request.")
                    return
                }
                Task { @MainActor [weak self] in
                    guard let self else {
                        replyHandler(nil, "NightBlood controller closed.")
                        return
                    }
                    do {
                        try await model.bridgeStop()
                        replyHandler(["stopped": true], nil)
                    } catch {
                        replyHandler(nil, Self.message(for: error))
                    }
                }
            default:
                replyHandler(nil, "Unsupported NightBlood controller operation.")
            }
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "nightbloodEvents", isTrusted(message) else {
                return
            }
            if let body = message.body as? [String: Any],
               body["type"] as? String == "ready",
               !attached
            {
                attached = true
                model.attach(face: self)
            }
            model.handleEventMessage(message.body)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (
                WKNavigationActionPolicy
            ) -> Void
        ) {
            guard navigationAction.targetFrame?.isMainFrame == true,
                  isTrustedURL(navigationAction.request.url)
            else {
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping @MainActor @Sendable (
                WKNavigationResponsePolicy
            ) -> Void
        ) {
            decisionHandler(
                isTrustedURL(navigationResponse.response.url) ? .allow : .cancel
            )
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            attached = false
            model.faceProcessWillReload()
            loadFace()
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: any Error
        ) {
            model.state = .failed
            model.lastError = "The signed NightBlood face could not load."
        }

        func webView(
            _ webView: WKWebView,
            decideMediaCapturePermissionsFor origin: WKSecurityOrigin,
            initiatedBy frame: WKFrameInfo,
            type: WKMediaCaptureType
        ) async -> WKPermissionDecision {
            isTrusted(frame: frame) && type == .microphone ? .grant : .deny
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            nil
        }

        func setAvailable(_ available: Bool) {
            call(
                "return window.NightBloodDirect?.setAvailable(available)",
                arguments: ["available": available]
            )
        }

        func setWorking(_ active: Bool) {
            call(
                "return window.NightBloodDirect?.setWorking(active)",
                arguments: ["active": active]
            )
        }

        func setInputMuted(_ muted: Bool) async -> Bool {
            guard attached,
                  let webView,
                  isTrustedURL(webView.url)
            else {
                return false
            }
            let generation = pageGeneration
            do {
                let result = try await webView.callAsyncJavaScript(
                    "return window.NightBloodDirect?.setInputMuted(muted)",
                    arguments: ["muted": muted],
                    in: nil,
                    contentWorld: .page
                )
                guard attached,
                      generation == pageGeneration,
                      isTrustedURL(webView.url),
                      let actual = result as? Bool
                else {
                    return false
                }
                return actual == muted
            } catch {
                return false
            }
        }

        func setOutputMuted(_ muted: Bool) async -> Bool {
            guard let webView, isTrustedURL(webView.url) else { return false }
            do {
                let result = try await webView.callAsyncJavaScript(
                    "return window.NightBloodDirect?.setOutputMuted(muted)",
                    arguments: ["muted": muted],
                    in: nil,
                    contentWorld: .page
                )
                guard isTrustedURL(webView.url),
                      let actual = result as? Bool
                else {
                    return false
                }
                return actual == muted
            } catch {
                return false
            }
        }

        func resumeAfterBackground(
            state: DirectVoiceSessionState
        ) async -> Bool {
            guard attached,
                  let webView,
                  isTrustedURL(webView.url)
            else {
                return false
            }
            let generation = pageGeneration
            do {
                let result = try await webView.callAsyncJavaScript(
                    "return await window.NightBloodDirect?.resumeAfterBackground(state)",
                    arguments: ["state": state.rawValue],
                    in: nil,
                    contentWorld: .page
                )
                guard attached,
                      generation == pageGeneration,
                      isTrustedURL(webView.url),
                      let resumed = result as? Bool
                else {
                    return false
                }
                return resumed
            } catch {
                return false
            }
        }

        func setSkin(_ skin: DirectFaceSkin) {
            desiredSkin = skin
            guard attached, skinApplyTask == nil else { return }
            let runID = UUID()
            let generation = pageGeneration
            skinRunID = runID
            skinApplyTask = Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    if self.skinRunID == runID {
                        self.skinRunID = nil
                        self.skinApplyTask = nil
                    }
                }
                while !Task.isCancelled {
                    guard self.attached,
                          self.pageGeneration == generation
                    else {
                        return
                    }
                    let target = self.desiredSkin
                    if self.appliedSkin == target { return }
                    guard await self.applySkin(
                        target,
                        pageGeneration: generation
                    ),
                    !Task.isCancelled,
                    self.attached,
                    self.pageGeneration == generation
                    else {
                        return
                    }
                    self.appliedSkin = target
                }
            }
        }

        func start(character: DirectFaceSkin) {
            call(
                "return await window.NightBloodDirect?.start(character)",
                arguments: ["character": character.rawValue]
            )
        }

        func stop() {
            call("return await window.NightBloodDirect?.stop()")
        }

        func closeLocalOnly() {
            call("return await window.NightBloodDirect?.closeLocalOnly()")
        }

        func gaze(_ sample: GazeSample) {
            call(
                "return window.NightBloodDirect?.gaze(sample)",
                arguments: ["sample": sample.bridgePayload]
            )
        }

        private func call(
            _ body: String,
            arguments: [String: Any] = [:]
        ) {
            guard let webView, isTrustedURL(webView.url) else { return }
            Task { @MainActor [weak self, weak webView] in
                guard let self, let webView, isTrustedURL(webView.url) else {
                    return
                }
                do {
                    _ = try await webView.callAsyncJavaScript(
                        body,
                        arguments: arguments,
                        in: nil,
                        contentWorld: .page
                    )
                } catch {
                    // Session lifecycle evidence comes through the bounded
                    // native transport. A JavaScript call failure cannot be
                    // interpreted as proof that a mutation did not happen.
                }
            }
        }

        private func applySkin(
            _ skin: DirectFaceSkin,
            pageGeneration generation: UInt64
        ) async -> Bool {
            guard attached,
                  pageGeneration == generation,
                  let webView,
                  isTrustedURL(webView.url)
            else {
                return false
            }
            do {
                let result = try await webView.callAsyncJavaScript(
                    "return window.NightBloodDirect?.setSkin(skin)",
                    arguments: ["skin": skin.rawValue],
                    in: nil,
                    contentWorld: .page
                )
                guard !Task.isCancelled,
                      attached,
                      pageGeneration == generation,
                      isTrustedURL(webView.url),
                      let applied = result as? String
                else {
                    return false
                }
                return applied == skin.rawValue
            } catch {
                return false
            }
        }

        private func isTrusted(_ message: WKScriptMessage) -> Bool {
            isTrusted(frame: message.frameInfo)
                && isTrustedURL(webView?.url)
        }

        private func isTrusted(frame: WKFrameInfo) -> Bool {
            frame.isMainFrame && isTrustedURL(frame.request.url)
        }

        private func isTrustedURL(_ candidate: URL?) -> Bool {
            guard let trustedPage, let candidate, candidate.isFileURL else {
                return false
            }
            return candidate.standardizedFileURL == trustedPage
        }

        private static func message(for error: Error) -> String {
            ((error as? LocalizedError)?.errorDescription
                ?? "The private Codex Voice operation failed.")
                .prefix(512)
                .description
        }
    }
}
