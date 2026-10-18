import Foundation
import HeelerSSH

/// SSH types stop at this boundary; the observable store only sees protocol frames.
enum PiConversationSSHSession {
    /// The bridge sends a heartbeat every 15 seconds, so this much silence
    /// means a stalled channel, not an idle Pi.
    static let silenceLimit: Duration = .seconds(45)

    static func open(channel: SSHStreamLocalChannel, lease: SSHChannelAdmissionLease) -> PiConversationSession {
        let (events, continuation) = AsyncThrowingStream<PiConversationFrame, any Error>.makeStream(
            bufferingPolicy: .bufferingOldest(256))
        let reader = Task {
            do {
                var decoder = PiConversationDecoder()
                while !Task.isCancelled {
                    guard let chunk = try await channel.read(timeout: silenceLimit) else { break }
                    for frame in try decoder.append(chunk) {
                        if case .dropped = continuation.yield(frame) {
                            throw PiConversationDecoder.invalidStream
                        }
                    }
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
            try? await channel.close(timeout: .seconds(2))
            await lease.release()
        }
        continuation.onTermination = { _ in reader.cancel() }
        return PiConversationSession(
            events: events,
            send: { command in try await channel.write(command.line, timeout: .seconds(5)) },
            end: {
                reader.cancel()
                try? await channel.close(timeout: .seconds(2))
                await lease.release()
            })
    }
}
