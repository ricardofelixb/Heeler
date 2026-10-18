import SwiftUI

/// The same Pi session as the terminal underneath, drawn as a transcript.
/// Read-only: the screen's own composer and keys type into Pi's terminal.
struct PiConversationView: View {
    let store: PiConversationStore
    let palette: TerminalThemePalette
    let isActive: Bool
    let connectionGeneration: UInt64?
    /// Where the floating header ends, from the top of the screen's surface,
    /// which the transcript reaches by running under the status bar.
    let headerBottom: CGFloat
    /// A drag or tap on the messages: the reader wants the screen back.
    var onReading: () -> Void = {}
    @State private var followsLatest = true
    @State private var transcriptBottom: CGFloat = 0
    @State private var visibleBottom: CGFloat = 0
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
                // How far the transcript runs on beneath the Composer. Measured,
                // not read from the safe area: with the system keyboard up that
                // inset also counts the keyboard the screen has already lifted
                // its content above, which left a keyboard-sized gap.
                transcript(composerHeight: max(0, transcriptBottom - visibleBottom))
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: {
            visibleBottom = $0
        }
        .allowsHitTesting(store.showsTranscript)
        .animation(.easeInOut(duration: 0.15), value: store.showsTranscript)
        .task(id: ConnectionIdentity(active: isActive, generation: connectionGeneration)) {
            if isActive { await store.observe() }
        }
    }

    private var secondary: Color { palette.foreground.opacity(0.6) }
    private var surface: Color { palette.foreground.opacity(0.08) }

    /// Runs beneath the header and composer, fading into the background at
    /// both ends so messages pass under the glass rather than being cut off.
    private func transcript(composerHeight: CGFloat) -> some View {
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
            }
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentMargins(.top, headerBottom + 16, for: .scrollContent)
        .contentMargins(.bottom, composerHeight + 16, for: .scrollContent)
        .overlay(alignment: .top) {
            PiEdgeFade(edge: .top, color: palette.background)
                .frame(height: headerBottom + 48)
        }
        .overlay(alignment: .bottom) {
            // Solid under the whole Composer, its status line included, so
            // messages fade out above it rather than behind its text.
            VStack(spacing: 0) {
                PiEdgeFade(edge: .bottom, color: palette.background)
                    .frame(height: 48)
                palette.background
                    .frame(height: composerHeight)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .modifier(SystemScrollEdgeHidden())
        .background(palette.background)
        // Inside the safe-area extension, so this sees where the transcript
        // really ends rather than where it was laid out.
        .background {
            Color.clear
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: {
                    transcriptBottom = $0
                }
        }
        .ignoresSafeArea(.container, edges: .vertical)
        .foregroundStyle(palette.foreground)
        .scrollDismissesKeyboard(.interactively)
        .scrollPosition($scrollPosition)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.top, for: .alignment)
        // The keyboard coming up shrinks the transcript; keep its end in view.
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .overlay {
            if store.rows.isEmpty && !store.isConnected {
                Text("Connecting…").font(.footnote).foregroundStyle(secondary)
            }
        }
        .simultaneousGesture(TapGesture().onEnded { onReading() })
        .onScrollPhaseChange { previous, phase in
            scrollPhase = phase
            if phase == .interacting { onReading() }
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
        // Your own message landing means you sent it: follow the reply even if
        // you had scrolled back to read.
        .onChange(of: store.rows.last { $0.role == "user" }?.id) { previous, latest in
            guard previous != nil, latest != previous else { return }
            followsLatest = true
            scrollPosition.scrollTo(edge: .bottom)
        }
        .onChange(of: store.isBusy) {
            if followsLatest { scrollPosition.scrollTo(edge: .bottom) }
        }
        // The keyboard settling moves the Composer, and with it the margin.
        .onChange(of: composerHeight) {
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
                // Running tools need no spinner: the status line says Working.
                if !rows.contains(where: { $0.state == "running" }) {
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

/// The background closing in over an edge of the transcript, with a light
/// blur under it, so text dissolves behind the header or composer.
private struct PiEdgeFade: View {
    let edge: VerticalEdge
    let color: Color

    var body: some View {
        let mask = LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black.opacity(0.18), location: 0.22),
                .init(color: .black.opacity(0.62), location: 0.48),
                .init(color: .black.opacity(0.92), location: 0.72),
                .init(color: .black, location: 1),
            ],
            startPoint: edge == .top ? .bottom : .top,
            endPoint: edge == .top ? .top : .bottom)
        ZStack {
            // Materials lighten a dark theme; at full strength the blur reads
            // as a grey band around the header rather than a soft edge.
            Rectangle().fill(.ultraThinMaterial).mask(mask).opacity(0.5)
            color.mask(mask)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// iOS 26 dims a scroll view's edges under bars on its own; the edge fades
/// already do that, and a second tint would show as a grey band.
private struct SystemScrollEdgeHidden: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.scrollEdgeEffectHidden()
        } else {
            content
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
