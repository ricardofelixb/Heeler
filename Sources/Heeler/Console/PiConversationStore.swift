import Foundation
import Observation

/// Mirrors Pi's authoritative branch, read-only. No terminal parsing,
/// optimistic transcript, input path, or agent lifetime ownership.
@MainActor @Observable
final class PiConversationStore {
    typealias Open = @Sendable () async throws -> PiConversationSession
    private(set) var rows: [PiConversationRow] = []
    private(set) var isConnected = false
    /// The first attempt failed before any snapshot: most likely no extension
    /// in this Pi, so the terminal shows while retries continue.
    private(set) var isUnavailable = false
    private(set) var isBusy = false
    private(set) var blocked: String?
    private(set) var isTruncated = false
    private(set) var sessionID: String?
    private(set) var settings: PiConversationSettings?
    /// The question Pi is waiting on, while the phone can answer it.
    private(set) var dialog: PiConversationDialog?
    /// Answered here and on its way to Pi, which closes it in a moment.
    private var answeredDialogID: String?
    /// Your messages that just landed, which the transcript pops in; not
    /// those already there on connect, nor a queued one Pi has now taken.
    private(set) var freshUserIDs: Set<String> = []
    /// Where a row's identity on screen differs from Pi's: a finished reply
    /// keeps the place of the text that streamed in, rather than replacing it.
    @ObservationIgnored private var displayIDs: [String: String] = [:]
    @ObservationIgnored private let open: Open
    @ObservationIgnored private let retryDelay: @Sendable (Int) async throws -> Void
    @ObservationIgnored private var session: PiConversationSession?
    @ObservationIgnored private var epoch: String?
    @ObservationIgnored private var revision: UInt64 = 0
    @ObservationIgnored private var observers: [UUID: CheckedContinuation<Void, Never>] = [:]
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var workerID = UUID()

    init(open: @escaping Open,
         retryDelay: @escaping @Sendable (Int) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.open = open
        self.retryDelay = retryDelay
    }

    /// The transcript covers the terminal unless Pi is asking for input there
    /// or the mirror has never answered. It stays up while connecting and
    /// through reconnects, showing the last snapshot, so the terminal never
    /// flashes through on a cold start, a remount, or a dropped stream.
    var showsTranscript: Bool {
        !isUnavailable && (blocked == nil || dialog != nil)
    }

    /// The question to ask natively, until it is answered.
    var pendingDialog: PiConversationDialog? {
        dialog?.id == answeredDialogID ? nil : dialog
    }

    /// Sends an answer and puts the question away. If Pi hasn't taken it
    /// shortly after, the question comes back rather than leaving Pi waiting.
    func answer(_ dialog: PiConversationDialog, _ answer: PiDialogAnswer) {
        answeredDialogID = dialog.id
        send(.answerDialog(id: dialog.id, answer))
        Task {
            try? await Task.sleep(for: .seconds(4))
            if answeredDialogID == dialog.id { answeredDialogID = nil }
        }
    }

    /// Multiple windows share one stream. The last departing view releases only SSH, never Pi.
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
        isConnected = false
        Task { await previous?.end() }
    }

    /// Retries every failure. A dropped link and a missing extension look the
    /// same from here, and the terminal stays usable while this backs off.
    private func connectLoop(run: UUID) async {
        var delay = 1
        while !Task.isCancelled, workerID == run {
            do {
                let opened = try await open()
                guard !Task.isCancelled, workerID == run else { await opened.end(); return }
                session = opened
                do {
                    for try await frame in opened.events {
                        guard !Task.isCancelled, workerID == run else { break }
                        try apply(frame)
                        if frame.type == "snapshot" { delay = 1 }
                    }
                } catch {}
                await opened.end()
            } catch {}
            guard !Task.isCancelled, workerID == run else { return }
            session = nil
            isConnected = false
            if sessionID == nil { isUnavailable = true }
            do { try await retryDelay(delay) } catch { return }
            delay = min(delay * 2, 30)
        }
    }

    /// The row's identity on screen.
    func displayID(_ row: PiConversationRow) -> String { displayIDs[row.id] ?? row.id }

    /// Carries screen identities across an update of the same live session.
    private func adopt(_ incoming: [PiConversationRow], continuing: Bool) {
        let previous = rows
        rows = incoming
        guard continuing else {
            displayIDs = [:]
            freshUserIDs = []
            return
        }
        let streaming = PiConversationRow.streamingID
        let previousIDs = Set(previous.map(\.id))
        let incomingIDs = Set(incoming.map(\.id))
        if previousIDs.contains(streaming), !incomingIDs.contains(streaming),
           let finished = incoming.last(where: { $0.role == "assistant" && !previousIDs.contains($0.id) })
        {
            displayIDs[finished.id] = displayIDs[streaming] ?? streaming
        }
        displayIDs[streaming] = incomingIDs.contains(streaming)
            ? (previousIDs.contains(streaming) ? displayIDs[streaming] : "live:\(UUID().uuidString)")
            : nil
        displayIDs = displayIDs.filter { incomingIDs.contains($0.key) }
        let queued = Set(previous.filter { $0.role == "user" && $0.state == "queued" }.map(\.text))
        let fresh = incoming.filter {
            $0.role == "user" && !previousIDs.contains($0.id) && !queued.contains($0.text)
        }
        if !fresh.isEmpty { freshUserIDs = Set(fresh.map(\.id)) }
    }

    /// Best effort: Pi answers with the settings it actually applied, and a
    /// dropped link reconnects to a fresh snapshot.
    func send(_ command: PiConversationCommand) {
        guard let session else { return }
        Task { try? await session.send(command) }
    }

    func apply(_ frame: PiConversationFrame) throws {
        if frame.type == "heartbeat" { return }
        guard frame.version == 1, let incomingEpoch = frame.epoch,
              let incomingSession = frame.sessionID, let incomingRevision = frame.revision else {
            throw PiConversationDecoder.invalidStream
        }
        if frame.type == "snapshot" {
            guard let incomingRows = frame.rows, incomingRows.count <= 120,
                  Set(incomingRows.map(\.id)).count == incomingRows.count else {
                throw PiConversationDecoder.invalidStream
            }
            // A reconnect or another session starts the screen afresh.
            adopt(incomingRows, continuing: isConnected && incomingEpoch == epoch
                && incomingSession == sessionID)
            epoch = incomingEpoch
            sessionID = incomingSession
            revision = incomingRevision
            isTruncated = frame.truncated ?? false
            isBusy = frame.busy ?? false
            blocked = frame.blocked
            dialog = frame.dialog
            settings = frame.settings
            isConnected = true
            isUnavailable = false
        } else {
            guard incomingEpoch == epoch, incomingSession == sessionID else {
                throw PiConversationDecoder.invalidStream
            }
            guard incomingRevision > revision else { return }
            // Revisions are contiguous after each authoritative snapshot.
            guard incomingRevision == revision + 1 else { throw PiConversationDecoder.invalidStream }
            revision = incomingRevision
            if frame.type == "message", let row = frame.row {
                var updated = rows
                if let index = updated.firstIndex(where: { $0.id == row.id }) { updated[index] = row }
                else { updated.append(row) }
                if updated.count > 120 { updated.removeFirst(updated.count - 120); isTruncated = true }
                adopt(updated, continuing: true)
            } else if frame.type == "status" {
                isBusy = frame.busy ?? false
                blocked = frame.blocked
            } else if frame.type == "settings", let incoming = frame.settings {
                settings = incoming
            } else if frame.type == "dialog" {
                dialog = frame.dialog
            }
        }
    }
}
