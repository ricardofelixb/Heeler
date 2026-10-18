import Foundation
import Observation
import SwiftUI
import Testing
import UIKit
@testable import Heeler

@MainActor
@Suite("Pi conversation mirror", .timeLimit(.minutes(1)))
struct PiConversationTests {
    private func store() -> PiConversationStore {
        PiConversationStore { throw TransportError.cancelled }
    }

    private func snapshot(epoch: String = "bridge", session: String = "session", revision: UInt64 = 0,
                          rows: [PiConversationRow] = []) -> PiConversationFrame {
        .init(type: "snapshot", version: 1, epoch: epoch, revision: revision,
              sessionID: session, rows: rows, busy: false)
    }

    @Test func keyboardSendSubmitsWithoutInsertingANewlineAndKeepsPastedParagraphs() {
        var edits: [String] = []
        var submissions = 0
        let coordinator = AgentComposerTextEditor.Coordinator(
            onEdit: { text, _ in edits.append(text) }, isFocused: .constant(true),
            onSubmit: { submissions += 1 })
        let editor = UITextView()
        editor.text = "Send from the keyboard"
        let end = NSRange(location: (editor.text as NSString).length, length: 0)
        #expect(!coordinator.textView(editor, shouldChangeTextIn: end, replacementText: "\n"))
        #expect(edits == ["Send from the keyboard"])
        #expect(submissions == 1)
        #expect(editor.text == "Send from the keyboard")
        #expect(coordinator.textView(editor, shouldChangeTextIn: end, replacementText: "First\nSecond"))
        #expect(submissions == 1)
    }

    @Test func terminalEditorAndIMEConfirmationDoNotTriggerSend() throws {
        var submissions = 0
        let coordinator = AgentComposerTextEditor.Coordinator(
            onEdit: { _, _ in }, isFocused: .constant(true))
        let editor = UITextView()
        #expect(coordinator.textView(editor, shouldChangeTextIn: .init(location: 0, length: 0),
                                    replacementText: "\n"))
        coordinator.onSubmit = { submissions += 1 }
        editor.setMarkedText("候補", selectedRange: .init(location: 2, length: 0))
        _ = try #require(editor.markedTextRange)
        #expect(coordinator.textView(editor, shouldChangeTextIn: .init(location: 0, length: 0),
                                    replacementText: "\n"))
        #expect(submissions == 0)
    }

    @Test func toolsAcrossCommentaryCollapseOncePerUserReply() {
        let user = PiConversationRow(id: "user", role: "user", text: "Change this")
        let first = PiConversationRow(id: "tool1", role: "tool", text: "read", state: "done")
        let commentary = PiConversationRow(id: "commentary", role: "assistant", text: "Found it")
        let second = PiConversationRow(id: "tool2", role: "tool", text: "edit", state: "running")
        let reply = PiConversationRow(id: "reply", role: "assistant", text: "Done")
        let next = PiConversationRow(id: "next", role: "user", text: "Again")
        let third = PiConversationRow(id: "tool3", role: "tool", text: "bash", state: "error")
        #expect(PiConversationItem.grouped([user, first, commentary, second, reply, next, third]) == [
            .message(user), .tools(id: first.id, rows: [first, second]),
            .message(commentary), .message(reply), .message(next), .tools(id: third.id, rows: [third])
        ])
    }

    @Test func truncatedToolHistoryAndStreamingUpdatesKeepStableGroupIdentity() {
        let first = PiConversationRow(id: "tool1", role: "tool", text: "read", state: "running")
        let second = PiConversationRow(id: "tool2", role: "tool", text: "bash", state: "running")
        let before = PiConversationItem.grouped([first])
        var finished = first
        finished.state = "done"
        finished.detail = "Finished output"
        let after = PiConversationItem.grouped([finished, second])
        #expect(before.map(\.id) == after.map(\.id))
        #expect(after == [.tools(id: first.id, rows: [finished, second])])
        #expect(PiConversationItem.grouped([]).isEmpty)
    }

    @Test func endpointMatchesNodeAndKeepsOpaqueIDsOutOfThePath() {
        #expect(PiConversationEndpoint.socket(home: "/home/test", herdrSocket: "/tmp/herdr.sock", paneID: "opaque:pane")
                == "/tmp/heeler-pi-928cd28cdeb14f38/2fac444f425c85ff601211138fa11f05.sock")
        let malicious = PiConversationEndpoint.socket(home: "/home/test", herdrSocket: "/tmp/herdr.sock", paneID: "../; $(exit)")
        #expect(!malicious.contains(".."))
        #expect(!malicious.contains("$"))
    }

    @Test func fragmentedUnicodeAndMultipleFramesDecodeWithoutLosingBytes() throws {
        let data = Data("{\"type\":\"status\",\"version\":1,\"blocked\":\"你好 👋\"}\n{\"type\":\"ack\",\"id\":\"one\"}\n".utf8)
        var decoder = PiConversationDecoder()
        var frames: [PiConversationFrame] = []
        for byte in data { frames += try decoder.append(Data([byte])) }
        #expect(frames.count == 2)
        #expect(frames[0].blocked == "你好 👋")
        #expect(frames[1].id == "one")
    }

    @Test func oversizedAndUnknownVersionFramesFailInsteadOfDroppingUpdates() {
        var decoder = PiConversationDecoder()
        #expect(throws: (any Error).self) {
            try decoder.append(Data(repeating: 0x78, count: PiConversationDecoder.maximumBytes + 1))
        }
        var other = PiConversationDecoder()
        #expect(throws: (any Error).self) {
            try other.append(Data("{\"type\":\"snapshot\",\"version\":2}\n".utf8))
        }
    }

    @Test func streamingUpdatesReplaceRowsAndFinalSnapshotReconcilesIDs() throws {
        let store = store()
        try store.apply(snapshot(rows: [.init(id: "user", role: "user", text: "Hello")]))
        for revision in UInt64(1)...3 {
            try store.apply(.init(type: "message", version: 1, epoch: "bridge", revision: revision,
                                  sessionID: "session", row: .init(id: "streaming", role: "assistant", text: "\(revision)")))
        }
        #expect(store.rows.map(\.id) == ["user", "streaming"])
        #expect(store.rows.last?.text == "3")
        try store.apply(snapshot(revision: 4, rows: [.init(id: "user", role: "user", text: "Hello"),
                                                    .init(id: "persisted", role: "assistant", text: "3")]))
        #expect(store.rows.map(\.id) == ["user", "persisted"])
    }

    @Test func reconnectAndBranchSwitchReplaceRatherThanAppendHistoryAndKeepDraft() throws {
        let store = store()
        store.draft = "Unsent from phone"
        try store.apply(snapshot(rows: [.init(id: "a", role: "user", text: "Old branch")]))
        try store.apply(snapshot(rows: [.init(id: "a", role: "user", text: "Old branch")]))
        #expect(store.rows.count == 1)
        try store.apply(snapshot(epoch: "new-bridge", session: "new-session",
                                 rows: [.init(id: "b", role: "user", text: "New branch")]))
        #expect(store.rows.map(\.id) == ["b"])
        #expect(store.draft == "Unsent from phone")
        #expect(store.isConnected)
    }

    @Test func revisionGapsAndDuplicateSnapshotIDsRequireFreshSnapshot() throws {
        let store = store()
        try store.apply(snapshot())
        #expect(throws: (any Error).self) {
            try store.apply(.init(type: "status", version: 1, epoch: "bridge", revision: 2, sessionID: "session"))
        }
        #expect(throws: (any Error).self) {
            try store.apply(snapshot(rows: [.init(id: "x", role: "user", text: "a"), .init(id: "x", role: "user", text: "b")]))
        }
    }

    @Test func sendWaitsForAckAndDoesNotEraseNewTypingOrInventTranscriptRows() async throws {
        let bridge = PiConversationTestBridge()
        let store = PiConversationStore { await bridge.open() }
        let observer = Task { await store.observe() }
        defer { observer.cancel() }
        try await waitUntil("Pi mirror should have an authoritative snapshot") { store.isConnected }
        store.draft = "First prompt"
        await store.sendPrompt()
        #expect(store.pending != nil)
        #expect(store.rows.isEmpty)
        await store.sendPrompt()
        #expect(await bridge.commands.count == 1)
        store.draft = "Typing the next prompt"
        let command = try #require(await bridge.commands.first)
        await bridge.emit(.init(type: "ack", id: command.id))
        try await waitUntil("ack should resolve the pending request") { store.pending == nil }
        #expect(store.draft == "Typing the next prompt")
        await store.sendPrompt()
        let second = try #require(await bridge.commands.last)
        await bridge.emit(.init(type: "ack", id: second.id, error: "Use Terminal first"))
        try await waitUntil("rejection should resolve pending delivery") { store.pending == nil }
        #expect(store.draft == "Typing the next prompt")
        #expect(store.error == "Use Terminal first")
        observer.cancel()
        await observer.value
        await bridge.waitForClose()
        #expect(await bridge.closedCount == 1)
    }

    @Test func busyPiStillAcceptsTypedFollowUpsExactlyOnce() async throws {
        let bridge = PiConversationTestBridge()
        let store = PiConversationStore { await bridge.open() }
        let observer = Task { await store.observe() }
        defer { observer.cancel() }
        try await waitUntil("initial Pi snapshot") { store.isConnected }
        try store.apply(.init(type: "status", version: 1, epoch: "bridge", revision: 1,
                              sessionID: "session", busy: true))
        store.draft = "Follow up while working"
        #expect(store.canSend)
        await store.sendPrompt()
        #expect(!store.canSend)
        #expect(await bridge.commands.count == 1)
        let command = try #require(await bridge.commands.first)
        #expect(command.text == "Follow up while working")
        await bridge.emit(.init(type: "ack", id: command.id))
        try await waitUntil("accepted follow-up clears draft") { store.draft.isEmpty }
        #expect(store.pending == nil)
        #expect(store.rows.isEmpty) // Acceptance isn't an invented transcript message.
    }

    @Test func reconnectRetriesUnconfirmedDeliveryWithTheSameIDOnly() async throws {
        let bridge = PiConversationTestBridge()
        let store = PiConversationStore { await bridge.open() }
        let observer = Task { await store.observe() }
        defer { observer.cancel() }
        try await waitUntil("initial Pi snapshot") { store.isConnected }
        store.draft = "Unconfirmed"
        await store.sendPrompt()
        let original = try #require(await bridge.commands.first)
        store.retry()
        await bridge.waitForCommands(2)
        let retried = try #require(await bridge.commands.last)
        #expect(retried.id == original.id)
        #expect(retried.text == original.text)
        #expect(store.rows.isEmpty)
        await bridge.emit(.init(type: "ack", id: original.id))
        try await waitUntil("receipt should clear the draft once") { store.pending == nil }
        #expect(store.draft.isEmpty)
    }

    @Test func lateWriteFailureCannotDisconnectTheReplacementStream() async throws {
        let bridge = PiConversationTestBridge()
        let store = PiConversationStore { await bridge.open() }
        let observer = Task { await store.observe() }
        defer { observer.cancel() }
        try await waitUntil("initial Pi snapshot") { store.isConnected }
        await bridge.pauseNextWrite()
        store.draft = "Slow original connection"
        let sending = Task { await store.sendPrompt() }
        await bridge.waitForCommands(1)
        store.retry()
        await bridge.waitForCommands(2)
        await bridge.failPausedWrite()
        await sending.value
        #expect(store.isConnected)
        #expect(store.error == nil)
        #expect(await bridge.commands.count == 2)
        let command = try #require(await bridge.commands.first)
        await bridge.emit(.init(type: "ack", id: command.id))
        try await waitUntil("replacement stream receives the same receipt") { store.pending == nil }
        #expect(store.draft.isEmpty)
    }

    @Test func changedBridgeNeverAutomaticallyResubmitsAnUnconfirmedPrompt() async throws {
        let bridge = PiConversationTestBridge()
        let store = PiConversationStore { await bridge.open() }
        let observer = Task { await store.observe() }
        defer { observer.cancel() }
        try await waitUntil("initial Pi snapshot") { store.isConnected }
        store.draft = "Possibly already delivered"
        await store.sendPrompt()
        await bridge.setEpoch("restarted")
        store.retry()
        try await waitUntil("a restarted bridge must invalidate pending delivery") { store.isConnected && store.pending == nil }
        #expect(await bridge.commands.count == 1)
        #expect(store.draft == "Possibly already delivered")
        #expect(store.error?.contains("Delivery wasn't confirmed") == true)
    }

    /// Observe state transitions rather than polling the UI or sleeping for guessed timings.
    private func waitUntil(_ message: String, _ condition: @escaping @MainActor @Sendable () -> Bool) async throws {
        while !condition() {
            await withCheckedContinuation { continuation in
                withObservationTracking { _ = condition() } onChange: { continuation.resume() }
            }
        }
    }

    @Test func blockingDialogsPreventSendWithoutDiscardingDraft() throws {
        let store = store()
        store.draft = "Continue"
        try store.apply(snapshot())
        #expect(store.canSend)
        try store.apply(.init(type: "status", version: 1, epoch: "bridge", revision: 1,
                              sessionID: "session", busy: true, blocked: "Choose an option in Terminal"))
        #expect(!store.canSend)
        #expect(store.draft == "Continue")
        try store.apply(.init(type: "status", version: 1, epoch: "bridge", revision: 2,
                              sessionID: "session", busy: false))
        #expect(store.canSend)
    }
}

private actor PiConversationTestBridge {
    private var epoch = "bridge"
    private var streams: [UUID: AsyncThrowingStream<PiConversationFrame, any Error>.Continuation] = [:]
    private var closed: Set<UUID> = []
    private(set) var commands: [PiConversationCommand] = []
    private var commandWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var shouldPauseWrite = false
    private var pausedWrite: CheckedContinuation<Void, any Error>?
    var closedCount: Int { closed.count }

    func waitForCommands(_ count: Int) async {
        guard commands.count < count else { return }
        await withCheckedContinuation { commandWaiters.append((count, $0)) }
    }

    func waitForClose() async {
        guard closed.isEmpty else { return }
        await withCheckedContinuation { closeWaiters.append($0) }
    }

    func pauseNextWrite() { shouldPauseWrite = true }
    func failPausedWrite() {
        pausedWrite?.resume(throwing: TransportError.cancelled)
        pausedWrite = nil
    }
    func setEpoch(_ value: String) { epoch = value }

    func open() -> PiConversationSession {
        let id = UUID()
        let (events, continuation) = AsyncThrowingStream<PiConversationFrame, any Error>.makeStream()
        streams[id] = continuation
        continuation.yield(.init(type: "snapshot", version: 1, epoch: epoch, revision: 0,
                                 sessionID: "session", rows: [], busy: false))
        return PiConversationSession(events: events, send: { try await self.record($0) },
                                     end: { await self.close(id) })
    }

    private func record(_ command: PiConversationCommand) async throws {
        commands.append(command)
        commandWaiters = commandWaiters.filter { count, continuation in
            if commands.count >= count { continuation.resume(); return false }
            return true
        }
        if shouldPauseWrite {
            shouldPauseWrite = false
            try await withCheckedThrowingContinuation { pausedWrite = $0 }
        }
    }
    func emit(_ frame: PiConversationFrame) { for stream in streams.values { stream.yield(frame) } }
    private func close(_ id: UUID) {
        closed.insert(id)
        streams.removeValue(forKey: id)?.finish()
        for waiter in closeWaiters { waiter.resume() }
        closeWaiters.removeAll()
    }
}
