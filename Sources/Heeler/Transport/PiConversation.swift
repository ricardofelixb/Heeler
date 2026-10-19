import CryptoKit
import Foundation

/// Private protocol v1 with the opt-in extension in pi-extension/. Not herdr wire data.
struct PiConversationRow: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let role: String
    let text: String
    var detail: String? = nil
    var state: String? = nil

    /// The reply Pi is still writing; the mirror resends it as it grows.
    static let streamingID = "streaming"
}

/// The running Pi's model, thinking level, usage and slash commands.
struct PiConversationSettings: Codable, Sendable, Equatable {
    struct Model: Codable, Sendable, Equatable, Hashable {
        let provider: String
        let id: String
        let name: String
        var thinkingLevels: [String] = ["off"]
    }
    struct Limit: Codable, Sendable, Equatable {
        let label: String
        /// Percent of the week's allowance still left.
        let left: Int
        /// When the week starts over, in milliseconds since 1970.
        let resetsAt: Double
    }
    struct Usage: Codable, Sendable, Equatable {
        var contextTokens: Int? = nil
        var contextWindow: Int? = nil
        var contextPercent: Double? = nil
        /// Weekly allowance left per provider, as Pi's usage status saved it.
        /// Nil from mirrors older than weekly limits.
        var limits: [Limit]? = nil
    }
    struct Command: Codable, Sendable, Equatable {
        let name: String
        var description: String = ""
    }
    var model: Model? = nil
    var thinking: String? = nil
    var models: [Model] = []
    var usage: Usage? = nil
    var commands: [Command] = []
}

/// A question Pi is waiting on that the phone can answer: a pick, a yes or
/// no, one line of text, or ask_user_question's questionnaire.
struct PiConversationDialog: Codable, Sendable, Equatable, Identifiable {
    enum Kind: String, Codable, Sendable {
        case select, confirm, input, questions
    }
    struct Question: Codable, Sendable, Equatable {
        struct Option: Codable, Sendable, Equatable {
            let label: String
            var description: String? = nil
        }
        let question: String
        var header: String? = nil
        var multiSelect: Bool? = nil
        var options: [Option]? = nil
    }
    let id: String
    let kind: Kind
    var title: String? = nil
    var message: String? = nil
    var options: [String]? = nil
    var placeholder: String? = nil
    var questions: [Question]? = nil
}

/// One answered question of a questionnaire: picked options or typed text.
struct PiQuestionAnswer: Sendable, Equatable {
    let questionIndex: Int
    var optionIndexes: [Int]? = nil
    var text: String? = nil
}

enum PiDialogAnswer: Sendable, Equatable {
    case option(Int)
    case confirmed(Bool)
    case text(String)
    case answers([PiQuestionAnswer])
    case cancel
}

/// The only requests the phone sends: messages go through Pi's terminal.
enum PiConversationCommand: Sendable, Equatable {
    case setModel(provider: String, id: String)
    case setThinking(String)
    case answerDialog(id: String, PiDialogAnswer)

    var line: Data {
        let object: [String: Any] = switch self {
        case let .setModel(provider, id): ["type": "setModel", "provider": provider, "id": id]
        case let .setThinking(level): ["type": "setThinking", "level": level]
        case let .answerDialog(id, answer): Self.answer(answer).merging(
            ["type": "answerDialog", "id": id]) { _, new in new }
        }
        var data = (try? JSONSerialization.data(withJSONObject: object, options: .sortedKeys)) ?? Data()
        data.append(0x0A)
        return data
    }

    private static func answer(_ answer: PiDialogAnswer) -> [String: Any] {
        switch answer {
        case let .option(index): return ["option": index]
        case let .confirmed(value): return ["confirmed": value]
        case let .text(text): return ["text": text]
        case .cancel: return ["cancel": true]
        case let .answers(answers):
            return ["answers": answers.map { answer -> [String: Any] in
                var entry: [String: Any] = ["questionIndex": answer.questionIndex]
                if let indexes = answer.optionIndexes { entry["optionIndexes"] = indexes }
                if let text = answer.text { entry["text"] = text }
                return entry
            }]
        }
    }
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
    var dialog: PiConversationDialog? = nil
    var settings: PiConversationSettings? = nil
}

/// Messages reach Pi through its terminal; the mirror only takes settings.
struct PiConversationSession: Sendable {
    let events: AsyncThrowingStream<PiConversationFrame, any Error>
    var send: @Sendable (PiConversationCommand) async throws -> Void = { _ in }
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
            if frame.version != 1 { throw Self.invalidStream }
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
