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
        /// The Host runs no VNC server.
        case unavailable
        /// The server wants a password the Host doesn't let us read.
        case needsPassword
        case failed(String)
    }

    typealias Opener = @Sendable () async throws -> (probe: RemoteScreenProbe, stream: HostLoopbackStream)?

    private(set) var phase: Phase = .connecting
    private(set) var isKeyboardOpen = false
    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored private let hostID: Host.ID
    @ObservationIgnored private let store: RemoteScreenSettingsStore
    @ObservationIgnored private let viewOnly: Bool
    @ObservationIgnored private let open: Opener
    @ObservationIgnored private var stream: HostLoopbackStream?
    @ObservationIgnored private var pump: RemoteScreenPump?
    @ObservationIgnored private var opening: Task<Void, Never>?
    @ObservationIgnored private var isPageReady = false
    @ObservationIgnored private var generation = 0
    /// Whether this attempt's password came from the Host itself.
    @ObservationIgnored private var passwordFromHost = false

    init(hostID: Host.ID, store: RemoteScreenSettingsStore, viewOnly: Bool, open: @escaping Opener) {
        self.hostID = hostID
        self.store = store
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

    /// Finds and opens a Host's screen over its own SSH connection.
    convenience init(host: Host, store: RemoteScreenSettingsStore, viewOnly: Bool) {
        self.init(hostID: host.id, store: store, viewOnly: viewOnly) {
            let credentials: SSHCredentials
            do {
                credentials = try HostCredentialsProvider().credentials(for: host)
            } catch HostCredentialsError.passwordNotSet {
                throw TransportError.authenticationFailed
            }
            let policy = HostKeyPolicy(knownHosts: UserDefaultsKnownHostsStore.shared) { _ in false }
            return try await HeelerSSHTransport.openScreen(
                settings: SSHTransportSettings(
                    host: host, credentials: credentials, hostKeyPolicy: policy))
        }
    }

    /// Starts over after a failure.
    func retry() {
        guard isPageReady else { return }
        connect()
    }

    /// Remembers the password the user typed and tries again with it.
    func submitPassword(_ password: String) {
        try? store.savePassword(password, for: hostID)
        retry()
    }

    func toggleKeyboard() {
        webView.evaluateJavaScript("window.heelerScreen.toggleKeyboard()")
    }

    func stop() {
        generation += 1
        opening?.cancel()
        opening = nil
        if isPageReady { webView.evaluateJavaScript("window.heelerScreen.disconnect()") }
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
            endStream()
            guard body["reason"] as? String == "auth" else {
                phase = .failed("The screen could not be shown.")
                return
            }
            if passwordFromHost {
                phase = .failed("The VNC password was refused.")
            } else {
                // A typed password that no longer works is asked for again.
                try? store.savePassword(nil, for: hostID)
                phase = .needsPassword
            }
        case "disconnected":
            if case .failed = phase { break }
            if phase == .needsPassword { break }
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
        let open = self.open
        opening = Task { [weak self] in
            do {
                let opened = try await open()
                guard let self, self.generation == current, !Task.isCancelled else {
                    if let opened {
                        Darwin.close(opened.stream.descriptor)
                        await opened.stream.finish()
                    }
                    return
                }
                self.store.setHadScreen(opened != nil, for: self.hostID)
                guard let opened else {
                    self.phase = .unavailable
                    return
                }
                self.attach(opened.stream, probe: opened.probe, generation: current)
            } catch {
                guard let self, self.generation == current else { return }
                self.phase = .failed(Self.message(for: error))
            }
        }
    }

    private func attach(_ stream: HostLoopbackStream, probe: RemoteScreenProbe, generation current: Int) {
        self.stream = stream
        passwordFromHost = probe.password != nil
        let password = probe.password ?? store.password(for: hostID) ?? ""
        webView.callAsyncJavaScript(
            "window.heelerScreen.connect(options)",
            arguments: ["options": ["password": password, "viewOnly": viewOnly]],
            in: nil, in: .page, completionHandler: nil)
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
                    self.webView.evaluateJavaScript("window.heelerScreen.ended()")
                    switch self.phase {
                    case .failed, .needsPassword: return
                    default: break
                    }
                    self.phase = .failed("The screen disconnected.")
                    self.endStream()
                }
            })
        self.pump = pump
        pump.start()
        webView.evaluateJavaScript("window.heelerScreen.opened()")
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
