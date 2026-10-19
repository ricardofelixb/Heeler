import CommonCrypto
import Foundation

/// What a Host says about its screen: the VNC server listening on its own
/// loopback and, when the server keeps it in a readable file, its password.
struct RemoteScreenProbe: Equatable, Sendable {
    var port: UInt16
    var password: String?

    /// Run with `sh -s` on the Host: prints `port=` for the lowest VNC port
    /// listening (Linux `ss`, or `netstat` on macOS), then `vncpasswd=` with
    /// the base64 password file of a running Xvnc, when the user can read it.
    static let script = """
        port=$( { ss -ltnH 2>/dev/null | awk '{print $4}'; netstat -an 2>/dev/null | awk '/LISTEN/ {print $4}'; } |
          sed -n 's/.*[:.]\\(59[0-9][0-9]\\)$/\\1/p' | sort -n | head -n 1)
        [ -n "$port" ] || exit 0
        echo "port=$port"
        file=$(ps -A -o args= 2>/dev/null |
          sed -n 's/.*-\\(PasswordFile\\|passwordfile\\|rfbauth\\|rfbAuth\\)[= ]\\([^ ]*\\).*/\\2/p' | head -n 1)
        if [ -n "$file" ] && [ -r "$file" ]; then
          echo "vncpasswd=$(base64 < "$file" | tr -d '\\n')"
        fi

        """

    /// Nil when the Host runs no VNC server.
    init?(output: String) {
        var port: UInt16?
        var password: String?
        for line in output.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("port=") {
                port = UInt16(line.dropFirst("port=".count))
            } else if line.hasPrefix("vncpasswd="),
                      let file = Data(base64Encoded: String(line.dropFirst("vncpasswd=".count)))
            {
                password = Self.decodePasswordFile(file)
            }
        }
        guard let port, port > 0 else { return nil }
        self.port = port
        self.password = password
    }

    init(port: UInt16, password: String?) {
        self.port = port
        self.password = password
    }

    /// A VNC password file holds the password DES-encrypted under a key
    /// every VNC implementation shares; it obscures, it doesn't protect.
    static func decodePasswordFile(_ file: Data) -> String? {
        guard file.count >= 8 else { return nil }
        let key: [UInt8] = [0xE8, 0x4A, 0xD6, 0x60, 0xC4, 0x72, 0x1A, 0xE0]
        var plain = [UInt8](repeating: 0, count: 8)
        var moved = 0
        let status = file.prefix(8).withUnsafeBytes { cipher in
            CCCrypt(
                CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmDES),
                CCOptions(kCCOptionECBMode), key, kCCKeySizeDES, nil,
                cipher.baseAddress, 8, &plain, 8, &moved)
        }
        guard status == kCCSuccess else { return nil }
        let bytes = plain.prefix { $0 != 0 }
        return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
    }
}
