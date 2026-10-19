import Foundation
import Network

/// Re-proves Host connections the moment the device changes networks
/// (Wi-Fi to cellular, back from no signal) instead of waiting for a
/// keepalive or a foreground return to notice the old route is gone.
@MainActor
struct NetworkPathDriver {
    let console: ConsoleStore

    /// What counts as a different network. The first report only describes
    /// the current one; losing the network has nothing to re-prove yet.
    private struct Route: Equatable, Sendable {
        let isSatisfied: Bool
        let interfaces: [String]
    }

    /// Consumes path updates until cancelled.
    func run() async {
        let monitor = NWPathMonitor()
        let routes = AsyncStream<Route> { continuation in
            monitor.pathUpdateHandler = { path in
                continuation.yield(Route(
                    isSatisfied: path.status == .satisfied,
                    interfaces: path.availableInterfaces.map(\.name)))
            }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "dev.heeler.network-path"))
        }
        var previous: Route?
        for await route in routes {
            guard !Task.isCancelled else { return }
            defer { previous = route }
            guard let previous, previous != route, route.isSatisfied else { continue }
            await console.networkPathDidChange()
        }
    }
}
