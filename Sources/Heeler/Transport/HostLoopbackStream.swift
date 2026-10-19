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
    /// A dedicated connection to the Host that finds its VNC server, then
    /// carries one stream to it. Nil, connection closed, when there is none.
    static func openScreen(
        settings: SSHTransportSettings
    ) async throws -> (probe: RemoteScreenProbe, stream: HostLoopbackStream)? {
        let transport = try await connect(settings: settings)
        let probe: RemoteScreenProbe?
        do {
            probe = try await transport.probeScreen()
        } catch {
            try? await transport.close()
            throw error
        }
        guard let probe else {
            try? await transport.close()
            return nil
        }
        return (probe, try await transport.openLoopbackStream(port: probe.port))
    }
}
