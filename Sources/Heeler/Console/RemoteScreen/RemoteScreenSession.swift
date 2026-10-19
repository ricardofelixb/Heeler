import Foundation
import Observation
import WebKit

/// One live view of a Host's screen: the bundled noVNC page in a web view,
/// fed through a dedicated SSH tunnel to the Host's VNC server. The page
/// never touches the network; its bytes cross `window.heelerScreen`.
@MainActor
@Observable
final class RemoteScreenSession {
    enum Phase: Equatable {
        case connecting
        case live
        case failed(String)
    }

    private(set) var phase: Phase = .connecting
    private(set) var isKeyboardOpen = false
    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored private let password: String
    @ObservationIgnored private let viewOnly: Bool
    @ObservationIgnored private let open: @Sendable () async throws -> HostLoopbackStream
    @ObservationIgnored private var stream: HostLoopbackStream?
    @ObservationIgnored private var pump: RemoteScreenPump?
    @ObservationIgnored private var opening: Task<Void, Never>?
    @ObservationIgnored private var isPageReady = false
    @ObservationIgnored private var generation = 0

    init(
        password: String,
        viewOnly: Bool,
        open: @escaping @Sendable () async throws -> HostLoopbackStream
    ) {
        self.password = password
        self.viewOnly = viewOnly
        self.open = open
        let configuration = WKWebViewConfiguration()
        let messages = RemoteScreenMessages()
        configuration.userContentController.add(messages, name: "screen")
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        messages.session = self
        if let url = Bundle.main.url(forResource: "RemoteScreenViewer", withExtension: "html"),
           let html = try? String(contentsOf: url, encoding: .utf8)
        {
            webView.loadHTMLString(html, baseURL: nil)
        } else {
            phase = .failed("The screen viewer is missing from this build.")
        }
    }

    /// Opens a Host's screen over its own SSH connection.
    convenience init(host: Host, settings: RemoteScreenSettings, viewOnly: Bool) {
        self.init(password: settings.password, viewOnly: viewOnly) {
            let credentials: SSHCredentials
            do {
                credentials = try HostCredentialsProvider().credentials(for: host)
            } catch HostCredentialsError.passwordNotSet {
                throw TransportError.authenticationFailed
            }
            let policy = HostKeyPolicy(knownHosts: UserDefaultsKnownHostsStore.shared) { _ in false }
            return try await HeelerSSHTransport.openLoopbackStream(
                settings: SSHTransportSettings(
                    host: host, credentials: credentials, hostKeyPolicy: policy),
                port: settings.port)
        }
    }

    /// Starts over after a failure.
    func retry() {
        guard isPageReady else { return }
        connect()
    }

    func toggleKeyboard() {
        webView.evaluateJavaScript("window.heelerScreen.toggleKeyboard()", completionHandler: nil)
    }

    func stop() {
        generation += 1
        opening?.cancel()
        opening = nil
        if isPageReady { webView.evaluateJavaScript("window.heelerScreen.disconnect()", completionHandler: nil) }
        endStream()
    }

    fileprivate func handle(_ body: [String: Any]) {
        switch body["type"] as? String {
        case "ready":
            isPageReady = true
            connect()
        case "send":
            if let text = body["data"] as? String, let data = Data(base64Encoded: text) {
                pump?.write(data)
            }
        case "close":
            endStream()
        case "rendered":
            phase = .live
        case "keyboard":
            isKeyboardOpen = body["open"] as? Bool ?? false
        case "error":
            phase = .failed(
                body["reason"] as? String == "auth"
                    ? "The VNC password was refused." : "The screen could not be shown.")
            endStream()
        case "disconnected":
            if case .failed = phase { break }
            phase = .failed("The screen disconnected.")
            endStream()
        default:
            break
        }
    }

    private func connect() {
        stop()
        generation += 1
        let current = generation
        phase = .connecting
        isKeyboardOpen = false
        webView.callAsyncJavaScript(
            "window.heelerScreen.connect(options)",
            arguments: ["options": ["password": password, "viewOnly": viewOnly]],
            in: nil, in: .page, completionHandler: nil)
        let open = self.open
        opening = Task { [weak self] in
            do {
                let stream = try await open()
                guard let self, self.generation == current, !Task.isCancelled else {
                    Darwin.close(stream.descriptor)
                    await stream.finish()
                    return
                }
                self.attach(stream, generation: current)
            } catch {
                guard let self, self.generation == current else { return }
                self.phase = .failed(Self.message(for: error))
                self.webView.evaluateJavaScript("window.heelerScreen.ended()", completionHandler: nil)
            }
        }
    }

    private func attach(_ stream: HostLoopbackStream, generation current: Int) {
        self.stream = stream
        let pump = RemoteScreenPump(
            descriptor: stream.descriptor,
            onData: { [weak self] data in
                let text = data.base64EncodedString()
                Task { @MainActor in
                    guard let self, self.generation == current else { return }
                    self.webView.callAsyncJavaScript(
                        "window.heelerScreen.receive(data)", arguments: ["data": text],
                        in: nil, in: .page, completionHandler: nil)
                }
            },
            onEnd: { [weak self] in
                Task { @MainActor in
                    guard let self, self.generation == current else { return }
                    self.webView.evaluateJavaScript("window.heelerScreen.ended()", completionHandler: nil)
                    if case .failed = self.phase { return }
                    self.phase = .failed("The screen disconnected.")
                    self.endStream()
                }
            })
        self.pump = pump
        pump.start()
        webView.evaluateJavaScript("window.heelerScreen.opened()", completionHandler: nil)
    }

    private func endStream() {
        pump?.close()
        pump = nil
        if let stream {
            self.stream = nil
            Task { await stream.finish() }
        }
    }

    private static func message(for error: any Error) -> String {
        if let error = error as? TransportError { return error.screenMessage }
        return error.localizedDescription
    }
}

private extension TransportError {
    var screenMessage: String {
        switch self {
        case .authenticationFailed: "The Host refused this device's key."
        case .tcpForwardingUnavailable: "The Host doesn't allow tunnels to its screen."
        default: "The Host couldn't be reached."
        }
    }
}

/// Breaks the retain cycle between the web view's content controller and
/// the session it reports to.
private final class RemoteScreenMessages: NSObject, WKScriptMessageHandler {
    weak var session: RemoteScreenSession?

    func userContentController(
        _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any] else { return }
        MainActor.assumeIsolated { session?.handle(body) }
    }
}
