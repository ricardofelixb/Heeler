import SwiftUI
import WebKit

/// The session's web view, as SwiftUI lays it out.
private struct RemoteScreenWebView: UIViewRepresentable {
    let session: RemoteScreenSession

    func makeUIView(context: Context) -> WKWebView { session.webView }
    func updateUIView(_ webView: WKWebView, context: Context) {}
}

/// A Host's screen at a glance, inside the Agent sheet: live but untouchable.
/// Tapping it asks for full control.
struct RemoteScreenPreview: View {
    let host: Host
    let settings: RemoteScreenSettings
    let onOpen: () -> Void
    @State private var session: RemoteScreenSession?

    var body: some View {
        Button(action: onOpen) {
            ZStack {
                Color.black
                if let session {
                    RemoteScreenWebView(session: session)
                        .allowsHitTesting(false)
                    RemoteScreenStatus(session: session, compact: true)
                }
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
        .accessibilityLabel("Control \(host.name)'s screen")
        .onAppear {
            session = RemoteScreenSession(host: host, settings: settings, viewOnly: true)
        }
        .onDisappear {
            session?.stop()
            session = nil
        }
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

/// The one-time setup of a Host's screen: where its VNC server listens on
/// the Host itself, and its password.
struct RemoteScreenSetupForm: View {
    let host: Host
    var current: RemoteScreenSettings?
    let onSave: (RemoteScreenSettings?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var port = ""
    @State private var password = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Port", text: $port, prompt: Text(verbatim: "5900"))
                        .keyboardType(.numberPad)
                    SecureField("VNC password", text: $password)
                } footer: {
                    Text("The VNC server on \(host.name) itself, reached through SSH. It doesn't need to listen on the network.")
                }
                if current != nil {
                    Section {
                        Button("Remove Screen", role: .destructive) {
                            onSave(nil)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Screen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(RemoteScreenSettings(port: parsedPort ?? 5900, password: password))
                        dismiss()
                    }
                    .disabled(!port.isEmpty && parsedPort == nil)
                }
            }
        }
        .onAppear {
            port = current.map { String($0.port) } ?? ""
            password = current?.password ?? ""
        }
    }

    private var parsedPort: UInt16? {
        UInt16(port.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil }
    }
}
