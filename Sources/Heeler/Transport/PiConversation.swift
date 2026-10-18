import CryptoKit
import Foundation

/// Private protocol v1 with the opt-in extension in pi-extension/. Not herdr wire data.
struct PiConversationRow: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let role: String
    let text: String
    var detail: String? = nil
    var state: String? = nil
}

struct PiConversationFrame: Codable, Sendable {
    let type: String
    var version: Int? = nil
    var epoch: String? = nil
    var revision: UInt64? = nil
    var sessionID: String? = nil
    var rows: [PiConversationRow]? = nil
    var row: PiConversationRow? = nil
    var truncated: Bool? = nil
    var busy: Bool? = nil
    var blocked: String? = nil
    var id: String? = nil
    var error: String? = nil
}

struct PiConversationCommand: Codable, Sendable {
    let id: String
    let sessionID: String
    let epoch: String
    let type: String
    var text: String? = nil
}

struct PiConversationSession: Sendable {
    let events: AsyncThrowingStream<PiConversationFrame, any Error>
    let send: @Sendable (PiConversationCommand) async throws -> Void
    let end: @Sendable () async -> Void
}

enum PiConversationEndpoint {
    static func socket(home: String, herdrSocket: String, paneID: String) -> String {
        func hash(_ text: String) -> String {
            SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        return "/tmp/heeler-pi-\(hash(home).prefix(16))/\(hash(herdrSocket + "\0" + paneID).prefix(32)).sock"
    }
}

/// Bounded NDJSON parser. Never discard an event silently: reconnect to a snapshot instead.
struct PiConversationDecoder {
    static let maximumBytes = 1_048_576
    private var buffer = Data()

    mutating func append(_ data: Data) throws -> [PiConversationFrame] {
        buffer.append(data)
        var frames: [PiConversationFrame] = []
        while let end = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<end]
            guard line.count <= Self.maximumBytes else { throw Self.invalidStream }
            let frame = try JSONDecoder().decode(PiConversationFrame.self, from: line)
            if frame.type != "ack", frame.version != 1 { throw Self.invalidStream }
            frames.append(frame)
            buffer.removeSubrange(...end)
        }
        guard buffer.count <= Self.maximumBytes else { throw Self.invalidStream }
        return frames
    }

    static var invalidStream: TransportError {
        .channelFailed(detail: "Unsupported or oversized Pi mirror stream. Update the companion extension.")
    }
}
