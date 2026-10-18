import SwiftUI

/// A quiet native face for the same Pi session that's open on the computer.
struct PiConversationView: View {
    @Bindable var store: PiConversationStore
    let agent: ConsoleAgent
    let isActive: Bool
    let connectionGeneration: UInt64?
    let onTerminal: () -> Void
    @State private var followsLatest = true
    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    @State private var scrollPhase = ScrollPhase.idle
    @State private var latestIsVisible = true
    @State private var expandedTools: Set<String> = []
    @State private var composerIsFocused = false
    @State private var selection = NSRange(location: 0, length: 0)

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

    @ViewBuilder private var transcript: some View {
        if store.rows.isEmpty {
            ContentUnavailableView(
                store.isConnected ? "You're in the same Pi session" : "Your Pi, on your phone",
                systemImage: "bubble.left.and.bubble.right")
        } else {
            ScrollView {
                // History is bounded to 120 rows. Lay out its real heights once,
                // rather than correcting lazy estimates while opening at the end.
                VStack(alignment: .leading, spacing: 24) {
                    if store.isTruncated {
                        Text("Recent conversation · older history in Terminal")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(PiConversationItem.grouped(store.rows)) { item in
                        switch item {
                        case .message(let row): message(row)
                        case .tools(let id, let rows): tools(id: id, rows: rows)
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollPosition($scrollPosition)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.top, for: .alignment)
            .onScrollPhaseChange { previous, phase in
                scrollPhase = phase
                if phase == .interacting || (phase == .idle && previous == .decelerating) {
                    followsLatest = latestIsVisible
                }
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 80
            } action: { _, value in
                latestIsVisible = value
                // New tokens and keyboard layout aren't user scrolling.
                // Only a drag may opt out of following the reply.
                if scrollPhase == .interacting || scrollPhase == .decelerating {
                    followsLatest = value
                }
            }
            .onChange(of: store.rows) {
                if followsLatest { scrollPosition.scrollTo(edge: .bottom) }
            }
            .onChange(of: store.sessionID) {
                expandedTools.removeAll()
                followsLatest = true
                scrollPosition.scrollTo(edge: .bottom)
            }
        }
    }

    private func tools(id: String, rows: [PiConversationRow]) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { expandedTools.contains(id) },
            set: { expanded in
                if expanded {
                    expandedTools.insert(id)
                    followsLatest = false
                } else {
                    expandedTools.remove(id)
                }
            })) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(rows) { message($0) }
            }
            .padding(.top, 12)
        } label: {
            HStack(spacing: 8) {
                if rows.contains(where: { $0.state == "running" }) {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: rows.contains(where: { $0.state == "error" })
                          ? "exclamationmark.circle" : "checkmark")
                }
                Text("Tools · \(rows.count)").font(.subheadline)
                Spacer(minLength: 0)
                let failures = rows.filter { $0.state == "error" }.count
                if failures > 0 { Text("\(failures) failed").font(.caption).foregroundStyle(.red) }
            }
            .foregroundStyle(.secondary)
        }
        .tint(.secondary)
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
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
                ZStack(alignment: .topLeading) {
                    if store.draft.isEmpty {
                        Text(store.isBusy ? "Follow up with Pi…" : "Message Pi…")
                            .foregroundStyle(.tertiary).padding(.vertical, 8)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
                    AgentComposerTextEditor(
                        text: store.draft, selectedRange: draftSelection,
                        onEdit: { text, range in store.draft = text; selection = range },
                        isFocused: $composerIsFocused,
                        keyboardPresentation: .system, keyboardHandoffID: nil,
                        isKeyboardHandoffCurrent: { _ in false },
                        onFirstResponderRequest: { _, _ in },
                        onKeyboardHandoffSettled: { _ in },
                        onSubmit: sendDraft)
                        .accessibilityIdentifier("pi-conversation-composer")
                }
                .padding(.horizontal, 12).padding(.vertical, 4)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                if store.isBusy {
                    Button { Task { await store.stop() } } label: {
                        Image(systemName: "stop.circle").font(.title2).frame(width: 44, height: 44)
                    }
                    .disabled(!store.isConnected || store.pending != nil)
                    .accessibilityLabel("Stop Pi")
                }
                AgentComposerSendButton(isEnabled: store.canSend,
                                        accessibilityHint: store.isBusy ? "Queue a follow-up" : "Send to Pi",
                                        action: sendDraft)
                    .accessibilityLabel(store.isBusy ? "Queue follow-up" : "Send message")
                    .accessibilityIdentifier("pi-conversation-send")
            }
            .padding(.horizontal, 16).padding(.bottom, 8)
            if store.pending != nil {
                Text("Confirming submission…").font(.caption).foregroundStyle(.secondary).padding(.bottom, 4)
            }
        }
        .background(Color(.systemBackground))
    }

    private var draftSelection: NSRange {
        let length = (store.draft as NSString).length
        let location = min(selection.location, length)
        return NSRange(location: location, length: min(selection.length, length - location))
    }

    private func sendDraft() {
        Task { await store.sendPrompt() }
    }
}

/// Presentation only: keep authoritative messages in order, collecting every
/// tool call between user messages into the first tools row of that reply.
enum PiConversationItem: Equatable, Identifiable {
    case message(PiConversationRow)
    case tools(id: String, rows: [PiConversationRow])

    var id: String {
        switch self {
        case .message(let row): row.id
        case .tools(let id, _): "tools-\(id)"
        }
    }

    static func grouped(_ rows: [PiConversationRow]) -> [Self] {
        var items: [Self] = []
        var toolIndex: Int?
        for row in rows {
            if row.role == "user" { toolIndex = nil }
            if row.role == "tool" {
                if let toolIndex, case .tools(let id, var tools) = items[toolIndex] {
                    tools.append(row)
                    items[toolIndex] = .tools(id: id, rows: tools)
                } else {
                    toolIndex = items.count
                    items.append(.tools(id: row.id, rows: [row]))
                }
            } else {
                items.append(.message(row))
            }
        }
        return items
    }
}
