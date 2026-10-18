#if DEBUG && targetEnvironment(simulator)
import Foundation

/// Deterministic native-chat fixture. No SSH, model calls, or real sessions.
actor DemoPiConversation {
    private let epoch = UUID().uuidString
    private let sessionID = "demo-pi-session"
    private var revision: UInt64 = 0
    private var clients: [UUID: AsyncThrowingStream<PiConversationFrame, any Error>.Continuation] = [:]
    private var accepted: Set<String> = []
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
    }

    private func snapshot() -> PiConversationFrame {
        PiConversationFrame(type: "snapshot", version: 1, epoch: epoch, revision: revision,
                            sessionID: sessionID, rows: rows, truncated: false, busy: false)
    }

    func open() -> PiConversationSession {
        let id = UUID()
        let (events, continuation) = AsyncThrowingStream<PiConversationFrame, any Error>.makeStream()
        clients[id] = continuation
        continuation.yield(snapshot())
        return PiConversationSession(events: events, send: { command in
            await self.receive(command, client: id)
        }, end: { await self.remove(id) })
    }

    private func receive(_ command: PiConversationCommand, client: UUID) {
        clients[client]?.yield(PiConversationFrame(type: "ack", id: command.id))
        guard accepted.insert(command.id).inserted, command.type == "prompt", let text = command.text else { return }
        rows.append(.init(id: command.id, role: "user", text: text))
        rows.append(.init(id: "reply-\(command.id)", role: "assistant",
                          text: "This is the native conversation fixture. Real Pi messages, tool activity, and replies will use this same view once the companion extension is loaded."))
        if rows.count > 120 { rows.removeFirst(rows.count - 120) }
        revision += 1
        for client in clients.values { client.yield(snapshot()) }
    }

    private func remove(_ id: UUID) { clients.removeValue(forKey: id)?.finish() }

    func close() {
        for client in clients.values { client.finish() }
        clients.removeAll()
    }
}
#endif
