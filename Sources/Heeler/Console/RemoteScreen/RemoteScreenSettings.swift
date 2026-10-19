import Foundation

/// What the app remembers about each Host's screen: a password the user
/// typed, for servers that keep theirs unreadable (macOS Screen Sharing), in
/// the Keychain. Kept apart from the Host catalog, which the fork leaves as is.
struct RemoteScreenSettingsStore: Sendable {
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
}
