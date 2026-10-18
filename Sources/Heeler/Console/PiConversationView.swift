import SwiftUI

/// The same Pi session as the terminal underneath, drawn as a transcript.
/// Read-only: the screen's own composer and keys type into Pi's terminal.
struct PiConversationView: View {
    let store: PiConversationStore
    let palette: TerminalThemePalette
    let isActive: Bool
    let connectionGeneration: UInt64?
    @State private var followsLatest = true
    @State private var scrollPosition = ScrollPosition(edge: .bottom)
    @State private var scrollPhase = ScrollPhase.idle
    @State private var latestIsVisible = true
    @State private var expandedTools: Set<String> = []

    private struct ConnectionIdentity: Equatable {
        let active: Bool
        let generation: UInt64?
    }

    var body: some View {
        // Stays mounted to keep observing while the terminal shows through.
        ZStack {
            if store.showsTranscript {
                transcript
                    .background(palette.background)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(store.showsTranscript)
        .animation(.easeInOut(duration: 0.15), value: store.showsTranscript)
        .task(id: ConnectionIdentity(active: isActive, generation: connectionGeneration)) {
            if isActive { await store.observe() }
        }
    }

    private var secondary: Color { palette.foreground.opacity(0.6) }
    private var surface: Color { palette.foreground.opacity(0.08) }

    private var transcript: some View {
        ScrollView {
            // History is bounded to 120 rows. Lay out its real heights once,
            // rather than correcting lazy estimates while opening at the end.
            VStack(alignment: .leading, spacing: 24) {
                if store.isTruncated {
                    Text("Recent conversation · older history in Terminal")
                        .font(.caption).foregroundStyle(secondary)
                }
                ForEach(PiConversationItem.grouped(store.rows)) { item in
                    switch item {
                    case .message(let row): message(row)
                    case .tools(let id, let rows): tools(id: id, rows: rows)
                    }
                }
                if store.isBusy {
                    ProgressView().tint(secondary).accessibilityLabel("Pi is working")
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(palette.foreground)
        .scrollDismissesKeyboard(.interactively)
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
        .onChange(of: store.isBusy) {
            if followsLatest { scrollPosition.scrollTo(edge: .bottom) }
        }
        .onChange(of: store.sessionID) {
            expandedTools.removeAll()
            followsLatest = true
            scrollPosition.scrollTo(edge: .bottom)
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
                    ProgressView().controlSize(.mini).tint(secondary)
                } else {
                    Image(systemName: rows.contains(where: { $0.state == "error" })
                          ? "exclamationmark.circle" : "checkmark")
                }
                Text("Tools · \(rows.count)").font(.subheadline)
                Spacer(minLength: 0)
                let failures = rows.filter { $0.state == "error" }.count
                if failures > 0 { Text("\(failures) failed").font(.caption).foregroundStyle(.red) }
            }
            .foregroundStyle(secondary)
        }
        .tint(secondary)
        .padding(12)
        .background(surface, in: RoundedRectangle(cornerRadius: 12))
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
                .foregroundStyle(row.state == "error" ? Color.red : secondary)
            }
            .tint(secondary)
        } else if row.role == "user" {
            HStack {
                Spacer(minLength: 32)
                Text(verbatim: row.text).textSelection(.enabled)
                    .padding(14).background(surface, in: RoundedRectangle(cornerRadius: 18))
            }
        } else if row.role == "notice" {
            Text(verbatim: row.text).font(.caption).foregroundStyle(secondary).textSelection(.enabled)
        } else {
            Text(.init(row.text)).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
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
