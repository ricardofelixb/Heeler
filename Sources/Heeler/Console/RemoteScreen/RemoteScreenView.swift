import SwiftUI
import WebKit

/// The session's web view, as SwiftUI lays it out.
private struct RemoteScreenWebView: UIViewRepresentable {
    let session: RemoteScreenSession

    func makeUIView(context: Context) -> WKWebView { session.webView }
    func updateUIView(_ webView: WKWebView, context: Context) {}
}

/// A Host's screen at a glance, inside the Agent sheet: live but untouchable.
/// Tapping it asks for full control. The sheet owns the session, so it can
/// leave the section out for Hosts without a screen.
struct RemoteScreenPreview: View {
    let hostName: String
    let session: RemoteScreenSession
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            ZStack {
                Color.black
                RemoteScreenWebView(session: session)
                    .allowsHitTesting(false)
                RemoteScreenStatus(session: session, compact: true)
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.black.opacity(0.5), in: Circle())
                    .padding(8)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Control \(hostName)'s screen")
    }
}

/// Full control of a Host's screen: touch drives the pointer like a
/// trackpad, and the keyboard types into the Host.
struct RemoteScreenFullView: View {
    let title: String
    let makeSession: () -> RemoteScreenSession
    @Environment(\.dismiss) private var dismiss
    @State private var session: RemoteScreenSession?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let session {
                RemoteScreenWebView(session: session)
                RemoteScreenStatus(session: session, compact: false)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Button("Close", systemImage: "xmark") {
                    session?.stop()
                    dismiss()
                }
                Spacer()
                Text(verbatim: title)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("Keyboard", systemImage: "keyboard") { session?.toggleKeyboard() }
                    .symbolVariant(session?.isKeyboardOpen == true ? .fill : .none)
                    .disabled(session?.phase != .live)
            }
            .labelStyle(.iconOnly)
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .onAppear { session = makeSession() }
        .onDisappear {
            session?.stop()
            session = nil
        }
    }
}

/// Connecting and failure, over the screen. A live screen shows nothing.
private struct RemoteScreenStatus: View {
    let session: RemoteScreenSession
    let compact: Bool

    var body: some View {
        switch session.phase {
        case .live:
            EmptyView()
        case .connecting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(.white)
                if !compact {
                    Text("Connecting…").font(.footnote)
                }
            }
            .foregroundStyle(.white.opacity(0.7))
        case .unavailable:
            Text("No screen found on this Host.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.8))
        case .needsPassword:
            if compact {
                Label("Enter the screen's password", systemImage: "lock")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.8))
            } else {
                RemoteScreenPasswordPrompt(session: session)
            }
        case .failed(let message):
            VStack(spacing: 10) {
                Text(message)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.8))
                if !compact {
                    Button("Retry") { session.retry() }
                        .buttonStyle(.bordered)
                        .tint(.white)
                }
            }
            .padding(24)
        }
    }
}

/// Asked once, for servers that keep their password where the Host's
/// user can't read it, such as macOS Screen Sharing.
private struct RemoteScreenPasswordPrompt: View {
    let session: RemoteScreenSession
    @State private var password = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 12) {
            Text("This screen needs its VNC password.")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.8))
            SecureField("Password", text: $password)
                .textContentType(.password)
                .focused($isFocused)
                .submitLabel(.go)
                .onSubmit(submit)
                .padding(10)
                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                .frame(maxWidth: 280)
            Button("Connect", action: submit)
                .buttonStyle(.bordered)
                .tint(.white)
                .disabled(password.isEmpty)
        }
        .padding(24)
        .onAppear { isFocused = true }
    }

    private func submit() {
        guard !password.isEmpty else { return }
        session.submitPassword(password)
    }
}
