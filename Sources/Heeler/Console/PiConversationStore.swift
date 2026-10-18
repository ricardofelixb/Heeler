import Foundation
import Observation

/// Mirrors Pi's authoritative branch. No terminal parsing, optimistic transcript, or agent lifetime ownership.
@MainActor @Observable
final class PiConversationStore {
    typealias Open = @Sendable () async throws -> PiConversationSession
    var draft = ""
    private(set) var rows: [PiConversationRow] = []
    private(set) var isConnected = false
    private(set) var isConnecting = false
    private(set) var isBusy = false
    private(set) var blocked: String?
    private(set) var error: String?
    private(set) var isTruncated = false
    private(set) var pending: PiConversationCommand?
    @ObservationIgnored private let open: Open
    @ObservationIgnored private var session: PiConversationSession?
    @ObservationIgnored private var connectionID = UUID()
    @ObservationIgnored private var epoch: String?
    private(set) var sessionID: String?
    @ObservationIgnored private var revision: UInt64 = 0
    @ObservationIgnored private var observers: [UUID: CheckedContinuation<Void, Never>] = [:]
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var workerID = UUID()

    init(open: @escaping Open) { self.open = open }

    /// Multiple windows share one stream/draft. The last departing view releases only SSH, never Pi.
    func observe() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(); return }
                observers[id] = continuation
                if worker == nil {
                    let run = UUID()
                    workerID = run
                    worker = Task { await self.connectLoop(run: run) }
                }
            }
        } onCancel: {
            Task { @MainActor in self.release(id) }
        }
    }

    private func release(_ id: UUID) {
        observers.removeValue(forKey: id)?.resume()
        guard observers.isEmpty else { return }
        workerID = UUID()
        worker?.cancel()
        worker = nil
        let previous = session
        session = nil
        connectionID = UUID()
        isConnected = false
        isConnecting = false
        Task { await previous?.end() }
    }

    private func connectLoop(run: UUID) async {
        var hasConnected = false
        var delay = 2
        while !Task.isCancelled, workerID == run {
            isConnecting = true
            do {
                let opened = try await open()
                guard !Task.isCancelled, workerID == run else { await opened.end(); return }
                session = opened
                connectionID = UUID()
                do {
                    for try await frame in opened.events {
                        guard !Task.isCancelled, workerID == run else { break }
                        try apply(frame)
                        if frame.type == "snapshot" {
                            hasConnected = true
                            delay = 2
                            // Retries are safe only within this exact live bridge/session.
                            if let pending { try await opened.send(pending) }
                        }
                    }
                    if !Task.isCancelled { throw TransportError.channelFailed(detail: "Pi mirror disconnected.") }
                } catch {
                    await opened.end()
                    throw error
                }
                await opened.end()
            } catch {
                guard !Task.isCancelled, workerID == run else { return }
                self.error = error.localizedDescription
            }
            guard workerID == run else { return }
            session = nil
            connectionID = UUID()
            isConnected = false
            isConnecting = false
            // A missing opt-in extension needs user action, not socket polling.
            guard hasConnected else { return }
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            delay = min(delay * 2, 30)
        }
    }

    func retry() {
        guard !observers.isEmpty else { return }
        workerID = UUID()
        worker?.cancel()
        let previous = session
        session = nil
        connectionID = UUID()
        isConnected = false
        let run = UUID()
        workerID = run
        worker = Task {
            await previous?.end()
            guard !Task.isCancelled else { return }
            await self.connectLoop(run: run)
        }
    }

    var canSend: Bool {
        isConnected && pending == nil && blocked == nil && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func sendPrompt() async {
        guard canSend else { return }
        await submit(type: "prompt", text: draft)
    }

    func stop() async {
        guard isConnected, pending == nil else { return }
        await submit(type: "stop", text: nil)
    }

    private func submit(type: String, text: String?) async {
        guard let session, let sessionID, let epoch else { return }
        let command = PiConversationCommand(id: UUID().uuidString, sessionID: sessionID,
                                            epoch: epoch, type: type, text: text)
        pending = command
        error = nil
        let sendingConnection = connectionID
        do { try await session.send(command) }
        catch {
            // A late old-channel failure must not tear down a newer connection or an acknowledged send.
            guard connectionID == sendingConnection, pending?.id == command.id else { return }
            // The write might have reached Pi. Keep its ID; don't create a duplicate prompt.
            self.error = "Delivery not confirmed. Reconnect to check the same request safely."
            isConnected = false
            retry()
        }
    }

    func apply(_ frame: PiConversationFrame) throws {
        if frame.type == "ack" {
            guard frame.id == pending?.id, let command = pending else { return }
            pending = nil
            error = frame.error
            if frame.error == nil, command.type == "prompt", draft == command.text { draft = "" }
            return
        }
        guard frame.version == 1, let incomingEpoch = frame.epoch,
              let incomingSession = frame.sessionID, let incomingRevision = frame.revision else {
            throw PiConversationDecoder.invalidStream
        }
        if frame.type == "snapshot" {
            guard let incomingRows = frame.rows, incomingRows.count <= 120,
                  Set(incomingRows.map(\.id)).count == incomingRows.count else {
                throw PiConversationDecoder.invalidStream
            }
            if let pending, pending.epoch != incomingEpoch || pending.sessionID != incomingSession {
                self.pending = nil
                error = "Pi changed sessions or restarted. Delivery wasn't confirmed; review history before sending again."
            } else if pending == nil { error = nil }
            rows = incomingRows
            epoch = incomingEpoch
            sessionID = incomingSession
            revision = incomingRevision
            isTruncated = frame.truncated ?? false
            isBusy = frame.busy ?? false
            blocked = frame.blocked
            isConnected = true
            isConnecting = false
        } else {
            guard incomingEpoch == epoch, incomingSession == sessionID else {
                throw PiConversationDecoder.invalidStream
            }
            guard incomingRevision > revision else { return }
            // Revisions are contiguous after each authoritative snapshot.
            guard incomingRevision == revision + 1 else { throw PiConversationDecoder.invalidStream }
            revision = incomingRevision
            if frame.type == "message", let row = frame.row {
                if let index = rows.firstIndex(where: { $0.id == row.id }) { rows[index] = row }
                else { rows.append(row) }
                if rows.count > 120 { rows.removeFirst(rows.count - 120); isTruncated = true }
            } else if frame.type == "status" {
                isBusy = frame.busy ?? false
                blocked = frame.blocked
            }
        }
    }
}
