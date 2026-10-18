import Foundation
import Observation
import SwiftUI
import Testing
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
        let data = Data("{\"type\":\"status\",\"version\":1,\"blocked\":\"你好 👋\"}\n{\"type\":\"heartbeat\",\"version\":1}\n".utf8)
        var decoder = PiConversationDecoder()
        var frames: [PiConversationFrame] = []
        for byte in data { frames += try decoder.append(Data([byte])) }
        #expect(frames.count == 2)
        #expect(frames[0].blocked == "你好 👋")
        #expect(frames[1].type == "heartbeat")
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

    @Test func reconnectAndBranchSwitchReplaceRatherThanAppendHistory() throws {
        let store = store()
        try store.apply(snapshot(rows: [.init(id: "a", role: "user", text: "Old branch")]))
        try store.apply(snapshot(rows: [.init(id: "a", role: "user", text: "Old branch")]))
        #expect(store.rows.count == 1)
        try store.apply(snapshot(epoch: "new-bridge", session: "new-session",
                                 rows: [.init(id: "b", role: "user", text: "New branch")]))
        #expect(store.rows.map(\.id) == ["b"])
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

    /// Observe state transitions rather than polling the UI or sleeping for guessed timings.
    private func waitUntil(_ message: String, _ condition: @escaping @MainActor @Sendable () -> Bool) async throws {
        while !condition() {
            await withCheckedContinuation { continuation in
                withObservationTracking { _ = condition() } onChange: { continuation.resume() }
            }
        }
    }

    @Test func failuresBeforeTheFirstSnapshotKeepRetryingAndDroppedStreamsReconnect() async throws {
        let bridge = PiConversationTestBridge(failures: 2)
        let store = PiConversationStore(open: { try await bridge.open() }, retryDelay: { _ in })
        let observer = Task { await store.observe() }
        defer { observer.cancel() }
        try await waitUntil("transient failures before any snapshot must not stop retrying") {
            store.rows.map(\.id) == ["open-3"]
        }
        #expect(store.showsTranscript)
        await bridge.dropStreams()
        try await waitUntil("a dropped stream reconnects to a fresh snapshot") {
            store.rows.map(\.id) == ["open-4"]
        }
        #expect(store.showsTranscript) // The last snapshot stayed up throughout.
        observer.cancel()
        await observer.value
    }

    @Test func aPiWithoutTheExtensionShowsTheTerminalUntilItAnswers() async throws {
        let gate = RetryGate()
        let bridge = PiConversationTestBridge(failures: 1)
        let store = PiConversationStore(open: { try await bridge.open() }, retryDelay: { _ in await gate.wait() })
        let observer = Task { await store.observe() }
        defer { observer.cancel() }
        try await waitUntil("a first failure reveals the terminal") { !store.showsTranscript }
        await gate.open()
        try await waitUntil("the first snapshot covers it again") { store.showsTranscript && store.isConnected }
    }

    @Test func dialogsAndDisconnectsRevealTheTerminalAndHeartbeatsChangeNothing() throws {
        let store = store()
        #expect(store.showsTranscript) // Covers the terminal while the first attempt connects.
        try store.apply(snapshot(rows: [.init(id: "a", role: "user", text: "Hi")]))
        #expect(store.showsTranscript)
        try store.apply(.init(type: "heartbeat", version: 1))
        try store.apply(.init(type: "status", version: 1, epoch: "bridge", revision: 1,
                              sessionID: "session", busy: true, blocked: "Choose an option"))
        #expect(!store.showsTranscript)
        #expect(store.isBusy)
        try store.apply(.init(type: "status", version: 1, epoch: "bridge", revision: 2,
                              sessionID: "session", busy: false))
        #expect(store.showsTranscript)
        #expect(store.rows.map(\.id) == ["a"])
    }
}

private actor PiConversationTestBridge {
    private var failures: Int
    private var streams: [UUID: AsyncThrowingStream<PiConversationFrame, any Error>.Continuation] = [:]
    private(set) var opens = 0

    init(failures: Int = 0) { self.failures = failures }

    func open() throws -> PiConversationSession {
        opens += 1
        if failures > 0 {
            failures -= 1
            throw TransportError.timedOut
        }
        let id = UUID()
        let (events, continuation) = AsyncThrowingStream<PiConversationFrame, any Error>.makeStream()
        streams[id] = continuation
        continuation.yield(.init(type: "snapshot", version: 1, epoch: "bridge", revision: 0,
                                 sessionID: "session", rows: [.init(id: "open-\(opens)", role: "notice", text: "")],
                                 busy: false))
        return PiConversationSession(events: events, end: { await self.close(id) })
    }

    func dropStreams() {
        for stream in streams.values { stream.finish(throwing: TransportError.timedOut) }
        streams.removeAll()
    }

    private func close(_ id: UUID) { streams.removeValue(forKey: id)?.finish() }
}

private actor RetryGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}
