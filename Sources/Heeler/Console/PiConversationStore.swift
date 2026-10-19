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
            rows = incomingRows
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
                if let index = rows.firstIndex(where: { $0.id == row.id }) { rows[index] = row }
                else { rows.append(row) }
                if rows.count > 120 { rows.removeFirst(rows.count - 120); isTruncated = true }
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
