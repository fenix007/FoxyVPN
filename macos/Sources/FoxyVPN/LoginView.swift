import AppKit
import SwiftUI
import WebKit
import FoxyCore

private let firefoxLoginURL = URL(
    string: "https://accounts.firefox.com/?context=fx_desktop_v3&service=sync&action=email"
)!

private let firefoxDesktopUserAgent =
    "Mozilla/5.0 (X11; Linux x86_64; rv:159.0) Gecko/20100101 Firefox/159.0"

private let firefoxWebChannelScript = #"""
(function() {
  if (window.__foxyChannelHooked) return;
  window.__foxyChannelHooked = true;

  function forward(value) {
    try {
      if (window.location.origin !== "https://accounts.firefox.com") return;
      var envelope = value;
      if (typeof envelope === "string") envelope = JSON.parse(envelope);
      if (!envelope || typeof envelope !== "object" || !envelope.message) return;
      window.webkit.messageHandlers.foxyWebChannel.postMessage(envelope);
    } catch (_) {}
  }

  function onChannel(event) { forward(event.detail); }
  window.addEventListener("WebChannelMessageToChrome", onChannel);
  document.addEventListener("WebChannelMessageToChrome", onChannel);

  window.__foxyReply = function(envelope) {
    window.dispatchEvent(new CustomEvent("WebChannelMessageToContent", { detail: envelope }));
    document.dispatchEvent(new CustomEvent("WebChannelMessageToContent", { detail: envelope }));
  };
})();
"""#

@MainActor
private final class FirefoxLoginState: ObservableObject {
    @Published var visibleOrigin = "accounts.firefox.com"
    @Published var loadError: String?
    @Published var isLoading = true
    @Published var isCheckingSession = false
}

/// A private Firefox Accounts sign-in window that hands the resulting session
/// token to the app without retaining the account site's cookies on disk.
struct FirefoxLoginView: View {
    @StateObject private var state = FirefoxLoginState()

    private let onSession: (String) -> Void
    private let onCancel: () -> Void

    init(
        onSession: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onSession = onSession
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button("Отмена", action: onCancel)
                    .keyboardShortcut(.cancelAction)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Вход в Firefox Account")
                        .font(.headline)
                    Label(state.visibleOrigin, systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if state.isLoading || state.isCheckingSession {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(12)

            Divider()

            if state.isCheckingSession {
                Text("Подтверди вход на странице ниже или в письме Mozilla. Окно закроется после подтверждения.")
                    .font(.callout).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.08))
            }

            if let loadError = state.loadError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(loadError)
                        .font(.callout)
                    Spacer()
                }
                .padding(10)
                .background(Color.orange.opacity(0.08))
            }

            FirefoxWebView(
                state: state,
                onSession: onSession
            )
        }
        .frame(minWidth: 680, minHeight: 620)
    }
}

@MainActor
private struct FirefoxWebView: NSViewRepresentable {
    @ObservedObject var state: FirefoxLoginState
    let onSession: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(state: state, onSession: onSession)
    }

    func makeNSView(context: Context) -> WKWebView {
        let contentController = WKUserContentController()
        contentController.addUserScript(
            WKUserScript(
                source: firefoxWebChannelScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            )
        )
        contentController.add(context.coordinator, name: Coordinator.handlerName)

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = contentController
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = firefoxDesktopUserAgent
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        webView.load(URLRequest(url: firefoxLoginURL))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.state = state
        context.coordinator.onSession = onSession
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.cancelVerification()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeScriptMessageHandler(
            forName: Coordinator.handlerName
        )
        coordinator.webView = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        static let handlerName = "foxyWebChannel"

        var state: FirefoxLoginState
        var onSession: (String) -> Void
        weak var webView: WKWebView?
        private var lastSessionToken: String?
        private var verificationProcess: Process?
        private var verificationID = UUID()

        init(state: FirefoxLoginState, onSession: @escaping (String) -> Void) {
            self.state = state
            self.onSession = onSession
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == Self.handlerName,
                  message.frameInfo.isMainFrame,
                  message.frameInfo.securityOrigin.protocol.lowercased() == "https",
                  message.frameInfo.securityOrigin.host.lowercased() == "accounts.firefox.com",
                  let envelope = message.body as? [String: Any],
                  let channelMessage = envelope["message"] as? [String: Any],
                  let command = channelMessage["command"] as? String
            else { return }

            let channelID = envelope["id"] ?? "account_updates"
            let messageID = channelMessage["messageId"] ?? ""
            let replyData: [String: Any]

            switch command {
            case "fxaccounts:fxa_status":
                replyData = ["capabilities": [:], "signedInUser": NSNull()]
            case "fxaccounts:can_link_account":
                replyData = ["ok": true]
            case "fxaccounts:login", "fxaccounts:oauth_login", "fxaccounts:verified":
                replyData = ["ok": true]
                if let data = channelMessage["data"] as? [String: Any] {
                    let token = (data["sessionToken"] as? String)
                        ?? (data["token"] as? String)
                    if let token, Self.isSessionToken(token), token != lastSessionToken || verificationProcess == nil {
                        verifySession(token)
                    }
                }
            default:
                replyData = ["ok": true]
            }

            guard !(messageID is String) || !(messageID as? String ?? "").isEmpty else {
                return
            }

            let reply: [String: Any] = [
                "id": channelID,
                "message": [
                    "messageId": messageID,
                    "command": command,
                    "data": replyData,
                ],
            ]
            webView?.callAsyncJavaScript(
                "window.__foxyReply && window.__foxyReply(reply);",
                arguments: ["reply": reply],
                in: message.frameInfo,
                in: .page,
                completionHandler: nil
            )
        }

        func cancelVerification() {
            verificationID = UUID()
            if verificationProcess?.isRunning == true { verificationProcess?.terminate() }
            verificationProcess = nil
            state.isCheckingSession = false
        }

        private func verifySession(_ token: String) {
            cancelVerification()
            lastSessionToken = token
            let identifier = verificationID
            let fm = FileManager.default
            let directory = fm.temporaryDirectory.appendingPathComponent("foxyvpn-login-" + UUID().uuidString)
            do {
                guard let backend = Bundle.main.resourceURL?.appendingPathComponent("foxyvpn-proxy"),
                      fm.isExecutableFile(atPath: backend.path) else {
                    throw AppFailure("Не найден компонент проверки входа.")
                }
                try fm.createDirectory(at: directory, withIntermediateDirectories: false,
                                       attributes: [.posixPermissions: 0o700])
                let logFile = directory.appendingPathComponent("verification.log")
                guard fm.createFile(atPath: logFile.path, contents: Data(),
                                    attributes: [.posixPermissions: 0o600]) else {
                    throw AppFailure("Не удалось создать защищённые файлы проверки входа.")
                }
                let output = try FileHandle(forWritingTo: logFile)
                defer { try? output.close() }
                let process = Process()
                process.executableURL = backend
                process.arguments = ["-wait-session-confirmed"]
                var environment = ProcessInfo.processInfo.environment
                environment["FOXYVPN_PARENT_PID"] = String(ProcessInfo.processInfo.processIdentifier)
                environment["FOXYVPN_NONINTERACTIVE"] = "1"
                process.environment = environment
                let input = Pipe()
                process.standardInput = input
                process.standardOutput = output
                process.standardError = output
                process.terminationHandler = { [weak self] finished in
                    let data = (try? Data(contentsOf: logFile)) ?? Data()
                    try? FileManager.default.removeItem(at: directory)
                    let succeeded = finished.terminationReason == .exit && finished.terminationStatus == 0
                    Task { @MainActor [weak self] in
                        guard let self, self.verificationID == identifier else { return }
                        self.verificationProcess = nil
                        self.state.isCheckingSession = false
                        if succeeded {
                            self.onSession(token)
                        } else {
                            self.state.loadError = "Подтверждение входа не завершено. Попробуй войти заново. "
                                + RuntimeSupport.redact(String(decoding: data.prefix(8_192), as: UTF8.self))
                        }
                    }
                }
                verificationProcess = process
                state.isCheckingSession = true
                state.loadError = nil
                try process.run()
                try input.fileHandleForWriting.write(contentsOf: Data(token.utf8))
                try input.fileHandleForWriting.close()
            } catch {
                if verificationProcess?.isRunning == true { verificationProcess?.terminate() }
                verificationProcess = nil
                state.isCheckingSession = false
                state.loadError = RuntimeSupport.redact(error.localizedDescription)
                try? fm.removeItem(at: directory)
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url,
                  url.scheme?.lowercased() == "https"
            else {
                decisionHandler(.cancel)
                return
            }

            if Self.isAllowedWebHost(url.host) {
                decisionHandler(.allow)
                return
            }

            // Legal, support, and identity-provider links stay outside the
            // privileged login surface.
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            state.isLoading = true
            state.loadError = nil
            updateVisibleOrigin(webView.url)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            updateVisibleOrigin(webView.url)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            state.isLoading = false
            updateVisibleOrigin(webView.url)
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            showLoadError(error)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            showLoadError(error)
        }

        private func updateVisibleOrigin(_ url: URL?) {
            guard let url, let host = url.host else { return }
            let port = url.port.map { ":\($0)" } ?? ""
            state.visibleOrigin = "\(host.lowercased())\(port)"
        }

        private func showLoadError(_ error: Error) {
            state.isLoading = false
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain,
               nsError.code == NSURLErrorCancelled {
                return
            }
            state.loadError = "Не удалось открыть страницу входа: \(error.localizedDescription)"
        }

        private static func isSessionToken(_ value: String) -> Bool {
            value.count == 64 && value.utf8.allSatisfy {
                ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
            }
        }

        private static func isAllowedWebHost(_ host: String?) -> Bool {
            guard let host = host?.lowercased() else { return false }
            return host == "accounts.firefox.com"
                || host.hasSuffix(".accounts.firefox.com")
                || host == "firefox.com"
                || host.hasSuffix(".firefox.com")
                || host == "mozilla.org"
                || host.hasSuffix(".mozilla.org")
        }
    }
}
