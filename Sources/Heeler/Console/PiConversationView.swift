import SwiftUI

/// A quiet native face for the same Pi session that's open on the computer.
struct PiConversationView: View {
    @Bindable var store: PiConversationStore
    let agent: ConsoleAgent
    let isActive: Bool
    let connectionGeneration: UInt64?
    let onTerminal: () -> Void
    @State private var followsLatest = true

    private struct ConnectionIdentity: Equatable {
        let active: Bool
        let generation: UInt64?
    }

    var body: some View {
        VStack(spacing: 0) {
            if let blocked = store.blocked {
                HStack(alignment: .top) {
                    Image(systemName: "hand.raised")
                    Text(verbatim: blocked).font(.subheadline)
                    Spacer(minLength: 0)
                    Button("Open Terminal", action: onTerminal)
                }
                .padding().background(Color(.secondarySystemBackground))
            }
            if let error = store.error {
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: error).font(.subheadline).foregroundStyle(.secondary)
                    if !store.isConnected { Button("Retry") { store.retry() } }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding()
            }
            transcript
        }
        .background(Color(.systemBackground))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { header }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: onTerminal) { Image(systemName: "terminal") }
                    .accessibilityLabel("Open Pi Terminal")
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { composer }
        .task(id: ConnectionIdentity(active: isActive, generation: connectionGeneration)) {
            if isActive { await store.observe() }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let image = UIImage(named: WorkspaceAgentPresentation.friendAsset(for: agent.id)) {
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(width: 32, height: 32).accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: WorkspaceAgentPresentation.title(for: agent.agent))
                    .font(.headline).lineLimit(1)
                Text(store.blocked != nil ? "Needs input in Terminal" :
                        store.isConnected ? (store.isBusy ? "Working · Pi" : "Connected · Pi") :
                        store.isConnecting ? "Connecting to Pi…" : "Disconnected · Pi")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: 260)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }

    private var transcript: some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if store.isTruncated {
                        Text("Recent conversation · older history in Terminal")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if store.rows.isEmpty {
                        ContentUnavailableView(
                            store.isConnected ? "You're in the same Pi session" : "Your Pi, on your phone",
                            systemImage: "bubble.left.and.bubble.right",
                            description: Text(store.isConnected ?
                                "Messages from either device appear here." :
                                "The companion extension mirrors your existing terminal session. Nothing new is launched."))
                    }
                    ForEach(store.rows) { row in
                        message(row)
                    }
                    Color.clear.frame(height: 1).id("latest")
                }
                .padding(20)
            }
            .defaultScrollAnchor(.bottom)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 80
            } action: { _, value in followsLatest = value }
            .onChange(of: store.rows) {
                if followsLatest { reader.scrollTo("latest", anchor: .bottom) }
            }
        }
    }

    @ViewBuilder private func message(_ row: PiConversationRow) -> some View {
        if row.role == "tool" {
            DisclosureGroup {
                Text(verbatim: row.detail ?? "")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: row.state == "error" ? "exclamationmark.circle" :
                            row.state == "running" ? "ellipsis" : "checkmark")
                    Text(verbatim: row.text).font(.subheadline)
                    if row.state == "error" { Text("Failed").font(.caption) }
                }
                .foregroundStyle(row.state == "error" ? .red : .secondary)
            }
            .tint(.secondary)
        } else if row.role == "user" {
            HStack {
                Spacer(minLength: 32)
                Text(verbatim: row.text).textSelection(.enabled)
                    .padding(14).background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
            }
        } else if row.role == "notice" {
            Text(verbatim: row.text).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        } else {
            Text(.init(row.text)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            Divider()
            HStack(alignment: .bottom, spacing: 12) {
                TextField(store.isBusy ? "Follow up with Pi…" : "Message Pi…", text: $store.draft, axis: .vertical)
                    .lineLimit(1...6).padding(12)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                    .accessibilityIdentifier("pi-conversation-composer")
                if store.isBusy {
                    Button { Task { await store.stop() } } label: {
                        Image(systemName: "stop.circle").font(.title2).frame(width: 44, height: 44)
                    }
                    .disabled(!store.isConnected || store.pending != nil)
                    .accessibilityLabel("Stop Pi")
                }
                Button { Task { await store.sendPrompt() } } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title).frame(width: 44, height: 44)
                }
                .disabled(!store.canSend)
                .accessibilityLabel(store.isBusy ? "Queue follow-up" : "Send message")
            }
            .padding(.horizontal, 16).padding(.bottom, 8)
            if store.pending != nil {
                Text("Confirming submission…").font(.caption).foregroundStyle(.secondary).padding(.bottom, 4)
            }
        }
        .background(Color(.systemBackground))
    }
}
