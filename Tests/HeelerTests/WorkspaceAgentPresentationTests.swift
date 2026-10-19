import Foundation
import Testing
import UIKit

@testable import Heeler

@Suite("Workspace agent presentation")
struct WorkspaceAgentPresentationTests {
    @Test func titleUsesManualTitleThenCleanTerminalTitleThenFallback() {
        func agent(title: String = "Fallback task", stripped: String? = nil, pane: String? = nil,
                   name: String? = nil, kind: String = "codex") -> Agent {
            Agent(terminalID: "t1", kind: kind, title: title, status: .working,
                  workspaceID: "w1", tabID: "tab1", paneID: "p1", cwd: "/work", revision: 1,
                  name: name, terminalTitleStripped: stripped, paneTitle: pane)
        }
        #expect(WorkspaceAgentPresentation.title(for: agent(stripped: "Terminal task", pane: "My task")) == "My task")
        #expect(WorkspaceAgentPresentation.title(for: agent(stripped: " Clean\n task ", pane: " \n")) == "Clean task")
        #expect(WorkspaceAgentPresentation.title(for: agent(stripped: " ")) == "Fallback task")
        #expect(WorkspaceAgentPresentation.title(for: agent(title: "", name: "Reviewer")) == "Reviewer")
        #expect(WorkspaceAgentPresentation.title(for: agent(title: "")) == "codex")
        #expect(WorkspaceAgentPresentation.title(for: agent(title: "", kind: "")) == "Agent")
        #expect(WorkspaceAgentPresentation.title(for: agent(stripped: "π - fix-login - heeler")) == "fix-login - heeler")
    }

    @MainActor
    @Test func friendsAreStableAndBundled() throws {
        let hostID = try #require(UUID(uuidString: "11111111-1111-4111-8111-111111111111"))
        let id = ConsoleAgent.ID(hostID: hostID, paneID: "p1")
        // A fixed expectation catches accidental process-seeded hashing or
        // catalog reordering, either of which would reshuffle existing friends.
        #expect(WorkspaceAgentPresentation.friendAsset(for: id) == "friend-mikan")
        let assets = Set((0..<100).map {
            WorkspaceAgentPresentation.friendAsset(for: .init(hostID: hostID, paneID: "p\($0)"))
        })
        #expect(assets.count == 9)
        for asset in assets {
            #expect(UIImage(named: asset, in: Bundle.main, compatibleWith: nil) != nil)
        }
    }

    @Test func onlyDialogsAndUnseenFinishesNeedAttention() {
        #expect(WorkspaceAgentPresentation.needsAttention(.blocked))
        #expect(WorkspaceAgentPresentation.needsAttention(.done))
        #expect(!WorkspaceAgentPresentation.needsAttention(.working))
        #expect(!WorkspaceAgentPresentation.needsAttention(.idle))
        #expect(WorkspaceAgentPresentation.statusText(for: .blocked) == "Needs input")
    }
}
