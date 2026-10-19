import Foundation

/// A byte stream to a service on a Host's own loopback, over a dedicated SSH
/// connection. `descriptor` is a connected non-blocking socket the caller
/// owns: closing it ends the stream, then `finish` releases the connection.
final class HostLoopbackStream: Sendable {
    let descriptor: Int32
    private let release: @Sendable () async -> Void

    init(descriptor: Int32, release: @escaping @Sendable () async -> Void) {
        self.descriptor = descriptor
        self.release = release
    }

    /// Call once the descriptor is closed.
    func finish() async {
        await release()
    }
}

extension HeelerSSHTransport {
    /// A dedicated connection to the Host, carrying one stream to `port` on
    /// its loopback.
    static func openLoopbackStream(
        settings: SSHTransportSettings, port: UInt16
    ) async throws -> HostLoopbackStream {
        try await connect(settings: settings).openLoopbackStream(port: port)
    }
}
