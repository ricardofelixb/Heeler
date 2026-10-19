import Darwin

/// A forwarded TCP stream, presented as a connected non-blocking socket.
/// Bytes written to its descriptor reach the remote endpoint and the
/// endpoint's replies become readable; closing the descriptor ends the
/// stream.
public final class SSHForwardedStream: Sendable {
    private let transport: DirectTCPIPByteTransport

    init(transport: DirectTCPIPByteTransport) {
        self.transport = transport
    }

    /// The local end of the stream, once: the caller owns and closes it.
    public func takeDescriptor() throws -> Int32 {
        try transport.takeDescriptor()
    }

    /// Waits for the forwarding channel to wind down after the descriptor
    /// was closed, cancelling it if that takes longer than `timeout`.
    public func close(timeout: Duration) async throws {
        try await transport.close(timeout: timeout)
    }

    /// Ends the stream at once, closing the descriptor if it was not taken.
    public func abort() {
        transport.abort()
    }
}
