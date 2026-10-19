import Foundation

/// Where a Host's VNC server listens on its own loopback, and its password.
/// Hosts without one show no Screen.
struct RemoteScreenSettings: Equatable, Sendable {
    var port: UInt16
    var password: String
}

/// Per-Host screen settings: the port in user defaults, the password in the
/// Keychain. Kept apart from the Host catalog, which the fork leaves as is.
struct RemoteScreenSettingsStore: Sendable {
    /// The user defaults suite holding ports; nil is the app's standard one.
    var suiteName: String?
    var secrets: any SecretStore = KeychainSecretStore(service: "dev.ricardofelixb.heeler.screen")

    func settings(for hostID: Host.ID) -> RemoteScreenSettings? {
        let port = defaults().integer(forKey: Self.portKey(hostID))
        guard let port = UInt16(exactly: port), port > 0 else { return nil }
        let password = (try? secrets.read(account: hostID.uuidString))
            .flatMap { $0 }
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return RemoteScreenSettings(port: port, password: password)
    }

    /// Saves `settings`, or forgets the Host's screen when nil.
    func save(_ settings: RemoteScreenSettings?, for hostID: Host.ID) throws {
        guard let settings else {
            defaults().removeObject(forKey: Self.portKey(hostID))
            try secrets.removeSecret(account: hostID.uuidString)
            return
        }
        try secrets.write(Data(settings.password.utf8), account: hostID.uuidString)
        defaults().set(Int(settings.port), forKey: Self.portKey(hostID))
    }

    private func defaults() -> UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    private static func portKey(_ hostID: Host.ID) -> String {
        "remoteScreen.port.\(hostID.uuidString)"
    }
}
