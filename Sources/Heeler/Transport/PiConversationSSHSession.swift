import Foundation
import HeelerSSH

/// SSH types stop at this boundary; the observable store only sees protocol frames.
enum PiConversationSSHSession {
    static func open(channel: SSHStreamLocalChannel, lease: SSHChannelAdmissionLease) -> PiConversationSession {
        let (events, continuation) = AsyncThrowingStream<PiConversationFrame, any Error>.makeStream(
            bufferingPolicy: .bufferingOldest(256))
        let reader = Task {
            do {
                var decoder = PiConversationDecoder()
                while !Task.isCancelled {
                    let chunk: Data?
                    do {
                        chunk = try await channel.read(timeout: .seconds(60))
                    } catch SSHError.timedOut {
                        continue // An idle conversation isn't a failed connection.
                    }
                    guard let chunk else { break }
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
            send: { command in
                var data = try JSONEncoder().encode(command)
                data.append(0x0A)
                try await channel.write(data, timeout: .seconds(15))
            },
            end: {
                reader.cancel()
                try? await channel.close(timeout: .seconds(2))
                await lease.release()
            })
    }
}
