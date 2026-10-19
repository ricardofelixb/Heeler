#if DEBUG && targetEnvironment(simulator)
import Foundation

/// Deterministic native-chat fixture. No SSH, model calls, or real sessions.
actor DemoPiConversation {
    private let epoch = UUID().uuidString
    private let sessionID = "demo-pi-session"
    private var revision: UInt64 = 0
    private var settings = PiConversationSettings(
        model: .init(provider: "anthropic", id: "claude-sonnet", name: "Claude Sonnet",
                     thinkingLevels: ["off", "minimal", "low", "medium", "high"]),
        thinking: "medium",
        models: [
            .init(provider: "anthropic", id: "claude-sonnet", name: "Claude Sonnet",
                  thinkingLevels: ["off", "minimal", "low", "medium", "high"]),
            .init(provider: "anthropic", id: "claude-opus", name: "Claude Opus",
                  thinkingLevels: ["off", "minimal", "low", "medium", "high", "xhigh"]),
            .init(provider: "openai", id: "gpt-mini", name: "GPT Mini"),
        ],
        usage: .init(contextTokens: 48_200, contextWindow: 200_000, contextPercent: 24.1, limits: [
            .init(label: "Claude", left: 84, resetsAt: (Date.now.timeIntervalSince1970 + 3 * 86_400) * 1000),
            .init(label: "Codex", left: 58, resetsAt: (Date.now.timeIntervalSince1970 + 6 * 86_400) * 1000),
        ]),
        commands: [.init(name: "compact", description: "Manually compact the session context"),
                   .init(name: "new", description: "Start a new session"),
                   .init(name: "live", description: "Talk to Pi")])
    /// `--demo-pi-dialog <kind>` opens a question Pi waits on: select, confirm, input or questions.
    private var dialog: PiConversationDialog?
    private var clients: [UUID: AsyncThrowingStream<PiConversationFrame, any Error>.Continuation] = [:]
    private var rows: [PiConversationRow] = [
        .init(id: "demo-notice", role: "notice", text: "Demo conversation · no real agent is running"),
        .init(id: "demo-user", role: "user", text: "Can you simplify this workspace list? Keep the useful context, lose the clutter."),
        .init(id: "demo-tool", role: "tool", text: "read", detail: "Sources/Heeler/Console/WorkspaceAgentRow.swift\n\nRead the workspace row and its existing presentation helpers.", state: "done"),
        .init(id: "demo-commentary", role: "assistant", text: "I'll keep the presentation changes small."),
        .init(id: "demo-edit", role: "tool", text: "edit", detail: "Updated the row layout.", state: "done"),
        .init(id: "demo-test", role: "tool", text: "bash", detail: "Focused checks passed.", state: "done"),
        .init(id: "demo-assistant", role: "assistant", text: "Yes. I'd keep **the task title**, a quiet status, and one friend per session.\n\nWorkspace and host context belong in the section header—not repeated in every row. The terminal stays one tap away.")
    ]

    init() {
        if ProcessInfo.processInfo.arguments.contains("--demo-pi-long-history") {
            let sample = rows
            rows = (1...12).flatMap { index in
                sample.map { row in
                    PiConversationRow(id: "\(index)-\(row.id)", role: row.role,
                                      text: row.role == "user" ? "Earlier request \(index)" : row.text,
                                      detail: row.detail, state: row.state)
                }
            }
        }
        let arguments = ProcessInfo.processInfo.arguments
        if let flag = arguments.firstIndex(of: "--demo-pi-dialog"), arguments.indices.contains(flag + 1),
           let kind = PiConversationDialog.Kind(rawValue: arguments[flag + 1])
        {
            dialog = Self.dialog(kind)
        }
        if ProcessInfo.processInfo.arguments.contains("--demo-pi-queued") {
            rows.append(.init(id: "demo-queued", role: "user",
                              text: "Also keep the pin icon.", state: "queued"))
        }
    }

    private func snapshot() -> PiConversationFrame {
        PiConversationFrame(type: "snapshot", version: 1, epoch: epoch, revision: revision,
                            sessionID: sessionID, rows: rows, truncated: false, busy: false,
                            blocked: dialog?.title ?? dialog.map { _ in "Pi needs input in Terminal" },
                            dialog: dialog, settings: settings)
    }

    private static func dialog(_ kind: PiConversationDialog.Kind) -> PiConversationDialog {
        switch kind {
        case .select:
            .init(id: "demo-dialog", kind: kind, title: "Which computer are you at?",
                  options: ["Mac mini", "Omarchy", "Orgo"])
        case .confirm:
            .init(id: "demo-dialog", kind: kind, title: "Redeem a banked reset?",
                  message: "Uses one of your 2 banked Codex resets.")
        case .input:
            .init(id: "demo-dialog", kind: kind, title: "Name this session", placeholder: "attach-polish")
        case .questions:
            .init(id: "demo-dialog", kind: kind, questions: [
                .init(question: "Which layout should the Agents list use?", header: "Layout", multiSelect: false,
                      options: [.init(label: "Chat list (Recommended)", description: "One row per agent, newest first."),
                                .init(label: "Grouped by host", description: "A section for each machine.")]),
                .init(question: "What should each row show?", header: "Rows", multiSelect: true,
                      options: [.init(label: "Last message", description: "What the agent said last."),
                                .init(label: "Time", description: "When it last changed.")]),
            ])
        }
    }

    func open() -> PiConversationSession {
        let id = UUID()
        let (events, continuation) = AsyncThrowingStream<PiConversationFrame, any Error>.makeStream()
        clients[id] = continuation
        continuation.yield(snapshot())
        return PiConversationSession(
            events: events, send: { await self.apply($0) }, end: { await self.remove(id) })
    }

    private func apply(_ command: PiConversationCommand) {
        switch command {
        case let .setModel(provider, id):
            guard let model = settings.models.first(where: { $0.provider == provider && $0.id == id }) else { return }
            settings.model = model
            if let thinking = settings.thinking, !model.thinkingLevels.contains(thinking) {
                settings.thinking = model.thinkingLevels.last
            }
        case let .setThinking(level):
            settings.thinking = level
        case .answerDialog:
            dialog = nil
            revision += 1
            let frame = PiConversationFrame(type: "dialog", version: 1, epoch: epoch, revision: revision,
                                            sessionID: sessionID)
            for client in clients.values { client.yield(frame) }
            return
        }
        revision += 1
        let frame = PiConversationFrame(type: "settings", version: 1, epoch: epoch, revision: revision,
                                        sessionID: sessionID, settings: settings)
        for client in clients.values { client.yield(frame) }
    }

    private func remove(_ id: UUID) { clients.removeValue(forKey: id)?.finish() }

    func close() {
        for client in clients.values { client.finish() }
        clients.removeAll()
    }
}
#endif
