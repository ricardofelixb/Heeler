import SwiftUI
import UIKit

/// The Agents list's one row, shaped like a chat: friend, title, and a
/// single quiet status line. Plugin-configurable fields stay with the
/// upstream card, which the fork no longer lists.
struct AgentListRow: View {
    let agent: ConsoleAgent
    let isPinned: Bool
    /// Under All Hosts the row says which machine it is on.
    let showsHost: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let status = agent.agent.status
        HStack(spacing: 12) {
            WorkspaceAgentPresentation.avatar(for: agent.id)
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(width: 44, height: 44)
                .overlay(alignment: .bottomTrailing) {
                    if status == .working || status == .blocked {
                        Circle()
                            .fill(Color(status.inkUIColor))
                            .frame(width: 11, height: 11)
                            .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 2))
                    }
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(WorkspaceAgentPresentation.title(for: agent.agent))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .accessibilityLabel("Pinned")
                    }
                }
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(status == .blocked ? Color(status.inkUIColor) : .secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if status == .done {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 10, height: 10)
                    .accessibilityLabel("Unread")
            }
        }
        .frame(minHeight: 52)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        let state = WorkspaceAgentPresentation.statusText(for: agent.agent.status)
        return showsHost ? "\(state) · \(agent.hostName)" : state
    }
}

enum WorkspaceAgentPresentation {
    static func title(for agent: Agent) -> String {
        for value in [agent.paneTitle, agent.terminalTitleStripped, agent.title, agent.displayName] {
            if let value {
                var title = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                // Pi brands its terminal title "π - …"; the friend says that.
                if title.hasPrefix("π - ") { title.removeFirst(4) }
                if !title.isEmpty { return title }
            }
        }
        return "Agent"
    }

    static func statusText(for status: AgentStatus) -> String {
        switch status {
        case .working: "Working"
        case .blocked: "Needs input"
        case .done: "Done"
        case .idle: "Idle"
        default: status.rawValue.capitalized
        }
    }

    /// Waiting on a dialog, or finished and not yet seen.
    static func needsAttention(_ status: AgentStatus) -> Bool {
        status == .blocked || status == .done
    }

    // These are bundled PNG resources, not asset-catalog entries.
    static func avatar(for id: ConsoleAgent.ID) -> Image {
        if let image = UIImage(named: friendAsset(for: id)) {
            return Image(uiImage: image)
        }
        return Image(systemName: "person.crop.circle")
    }

    /// Stable pseudo-random assignment to the Host/Pane identity, not its
    /// changing name, status, or list position. Swift's Hasher is process-seeded
    /// and would reshuffle friends on every launch. Pane reuse retains a friend,
    /// matching Heeler's existing pin identity; this is not session tracking.
    static func friendAsset(for id: ConsoleAgent.ID) -> String {
        let friends = ["hoshi", "kokoro", "kuma", "maru", "mikan", "neko", "sankaku", "shikaku", "usagi"]
        let key = "\(id.hostID.uuidString)/\(id.paneID)"
        let hash = key.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        return "friend-\(friends[Int(hash % UInt64(friends.count))])"
    }
}
