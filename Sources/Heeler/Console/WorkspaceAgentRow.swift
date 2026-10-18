import SwiftUI
import UIKit

/// A deliberately quieter row for By Workspace. Other presentations retain
/// the plugin-configurable fields; the section already identifies this Host.
struct WorkspaceAgentRow: View {
    let agent: ConsoleAgent
    let isPinned: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    // These are bundled PNG resources, not asset-catalog entries.
    private var avatar: Image {
        if let image = UIImage(named: WorkspaceAgentPresentation.friendAsset(for: agent.id)) {
            return Image(uiImage: image)
        }
        return Image(systemName: "person.crop.circle")
    }

    var body: some View {
        HStack(spacing: 12) {
            avatar
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(width: 42, height: 42)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(WorkspaceAgentPresentation.title(for: agent.agent))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Pinned")
                    }
                }
                HStack(spacing: 5) {
                    Text(agent.agent.status.rawValue.capitalized)
                        .foregroundStyle(agent.agent.status == .blocked
                            ? Color(agent.agent.status.inkUIColor) : .secondary)
                    Text("·")
                    Text(agent.agent.kind.capitalized)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 52)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

enum WorkspaceAgentPresentation {
    static func title(for agent: Agent) -> String {
        for value in [agent.paneTitle, agent.terminalTitleStripped, agent.title, agent.displayName] {
            if let value {
                let title = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                if !title.isEmpty { return title }
            }
        }
        return "Agent"
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
