import Foundation

/// What the app remembers about each Host's screen: a password the user
/// typed, for servers that keep theirs unreadable (macOS Screen Sharing), in
/// the Keychain; and whether the Host had a screen last time, in user
/// defaults, so the Agent sheet keeps its place while the Host is asked again.
/// Kept apart from the Host catalog, which the fork leaves as is.
struct RemoteScreenSettingsStore: Sendable {
    /// The user defaults suite; nil is the app's standard one.
    var suiteName: String?
    var secrets: any SecretStore = KeychainSecretStore(service: "dev.ricardofelixb.heeler.screen")

    func password(for hostID: Host.ID) -> String? {
        (try? secrets.read(account: hostID.uuidString))
            .flatMap { $0 }
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Saves the typed password, or forgets it when nil.
    func savePassword(_ password: String?, for hostID: Host.ID) throws {
        guard let password else {
            try secrets.removeSecret(account: hostID.uuidString)
            return
        }
        try secrets.write(Data(password.utf8), account: hostID.uuidString)
    }

    /// Nil until the Host has been asked once.
    func hadScreen(_ hostID: Host.ID) -> Bool? {
        defaults().object(forKey: Self.availabilityKey(hostID)) as? Bool
    }

    func setHadScreen(_ hadScreen: Bool, for hostID: Host.ID) {
        defaults().set(hadScreen, forKey: Self.availabilityKey(hostID))
    }

    private func defaults() -> UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    private static func availabilityKey(_ hostID: Host.ID) -> String {
        "remoteScreen.available.\(hostID.uuidString)"
    }
}
