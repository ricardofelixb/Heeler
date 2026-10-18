import Foundation
import Testing

@testable import Heeler

@MainActor
@Suite("Console list presentation store")
struct ConsoleListPresentationStoreTests {
    @Test func workspacePresentationIsAvailableAndPersists() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let mode = try #require(ConsoleListPresentationMode(rawValue: "byWorkspace"))
        #expect(mode.title == "By Workspace")
        let store = ConsoleListPresentationStore(defaults: defaults)
        store.select(mode)
        #expect(ConsoleListPresentationStore(defaults: defaults).mode == mode)
    }

    private func makeDefaults() throws -> (UserDefaults, cleanup: () -> Void) {
        let suiteName = "hm-console-list-presentation-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    private func consoleAgent(
        host: Host,
        paneID: String,
        status: AgentStatus,
        workspaceID: String = "w1",
        label: String? = nil
    ) -> ConsoleAgent {
        ConsoleAgent(
            hostID: host.id,
            hostName: host.displayName,
            agent: Agent(.fixture(paneID: paneID, status: status, workspaceID: workspaceID)),
            workspaceLabel: label,
            repositoryCheckout: nil)
    }

    @Test func workspaceGroupsUseHostAndOpaqueIDAndKeepIncomingOrder() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let first = Host.fixture(name: "Studio")
        let second = Host.fixture(name: "Build")
        let agents = [
            consoleAgent(host: second, paneID: "p1", status: .blocked, label: "Shared"),
            consoleAgent(host: first, paneID: "p2", status: .done, workspaceID: "w2", label: "Shared"),
            consoleAgent(host: first, paneID: "p1", status: .working, label: "Shared"),
            consoleAgent(host: first, paneID: "p3", status: .idle, workspaceID: "w2", label: "Shared"),
        ]
        let store = ConsoleListPresentationStore(defaults: defaults)
        let groups = store.workspaceSections(hosts: [first, second, first], agents: agents)
        #expect(groups.map(\.id) == [
            .init(hostID: first.id, workspaceID: "w2"),
            .init(hostID: first.id, workspaceID: "w1"),
            .init(hostID: second.id, workspaceID: "w1"),
        ])
        #expect(groups.map { $0.agents.map(\.id) } == [
            [agents[1].id, agents[3].id], [agents[2].id], [agents[0].id],
        ])
        #expect(groups.allSatisfy { !$0.isCollapsed && $0.title == "Shared" })
        #expect(groups.flatMap(\.visibleAgentIDs).count == agents.count)
        let filtered = store.workspaceSections(
            hosts: [first, second], agents: agents, filteredHostID: second.id)
        #expect(filtered.map(\.id) == [.init(hostID: second.id, workspaceID: "w1")])
    }

    @Test func workspaceCollapsePersistsAcrossRenameAndReconnectButNotOtherHosts() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let first = Host.fixture(name: "Studio")
        let second = Host.fixture(name: "Build")
        let opaqueID = "workspace:/with|separators"
        let id = ConsoleWorkspaceSection.ID(hostID: first.id, workspaceID: opaqueID)
        let agents = [first, second].map {
            consoleAgent(host: $0, paneID: "p1", status: .blocked, workspaceID: opaqueID, label: "Renamed")
        }
        let store = ConsoleListPresentationStore(defaults: defaults)
        store.toggleWorkspace(id)
        #expect(store.workspaceSections(hosts: [], agents: []).isEmpty)
        let reloaded = ConsoleListPresentationStore(defaults: defaults)
        let groups = reloaded.workspaceSections(hosts: [first, second], agents: agents)
        let collapsed = try #require(groups.first)
        #expect(collapsed.title == "Renamed")
        #expect(collapsed.isCollapsed)
        #expect(collapsed.visibleAgentIDs.isEmpty)
        #expect(collapsed.statusCounts == .init(blocked: 1))
        #expect(collapsed.accessibilityValue == "1 Agent, Collapsed, 1 blocked")
        #expect(groups.last?.isCollapsed == false)
        reloaded.toggleWorkspace(id)
        #expect(ConsoleListPresentationStore(defaults: defaults)
            .workspaceSections(hosts: [first], agents: agents).first?.isCollapsed == false)
    }

    @Test func workspaceSearchRevealsOnlyMatchesWithoutChangingCollapsePreference() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture()
        let agents = [
            consoleAgent(host: host, paneID: "p1", status: .working, label: "Website"),
            consoleAgent(host: host, paneID: "p2", status: .done, workspaceID: "w2", label: "API"),
        ]
        let store = ConsoleListPresentationStore(defaults: defaults)
        store.toggleWorkspace(.init(hostID: host.id, workspaceID: "w1"))
        let result = store.workspaceSections(hosts: [host], agents: agents, searchQuery: "  WEBSITE  ")
        #expect(result.count == 1)
        #expect(result.first?.isCollapsed == false)
        #expect(result.flatMap(\.visibleAgentIDs) == [agents[0].id])
        #expect(store.workspaceSections(hosts: [host], agents: agents, searchQuery: "does-not-exist").isEmpty)
        #expect(store.workspaceSections(hosts: [host], agents: agents, searchQuery: " \n").first?.isCollapsed == true)
    }

    @Test func workspaceGroupsReprojectNamesStatusesMembershipAndMissingLabels() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture()
        let store = ConsoleListPresentationStore(defaults: defaults)
        let original = consoleAgent(host: host, paneID: "p1", status: .working)
        #expect(store.workspaceSections(hosts: [host], agents: [original]).first?.title == "w1")
        let updated = consoleAgent(host: host, paneID: "p1", status: .done, label: "Website")
        let added = consoleAgent(host: host, paneID: "p2", status: .blocked, label: "Website")
        let groups = store.workspaceSections(hosts: [host], agents: [added, updated])
        #expect(groups.first?.title == "Website")
        #expect(groups.first?.statusCounts == .init(blocked: 1, done: 1))
        #expect(groups.first?.agents.map(\.id) == [added.id, updated.id])
        #expect(store.workspaceSections(hosts: [host], agents: []).isEmpty)
        let unnamed = consoleAgent(host: host, paneID: "p3", status: .idle, workspaceID: "", label: " \n")
        #expect(store.workspaceSections(hosts: [host], agents: [unnamed]).first?.title == "Unknown Workspace")
    }

    @Test func presentationModeDefaultsToWorkspaceAndPersists() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }

        let store = ConsoleListPresentationStore(defaults: defaults)
        #expect(store.mode == .byWorkspace)

        store.select(.grouped)
        #expect(ConsoleListPresentationStore(defaults: defaults).mode == .grouped)

        store.select(.flat)
        #expect(ConsoleListPresentationStore(defaults: defaults).mode == .flat)
    }

    @Test func collapsedStatePersistsAndIsIsolatedPerHost() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let hostA = Host.fixture(name: "alpha")
        let hostB = Host.fixture(name: "beta")

        let store = ConsoleListPresentationStore(defaults: defaults)
        store.setCollapsed(true, for: hostA.id)

        let reloaded = ConsoleListPresentationStore(defaults: defaults)
        #expect(reloaded.isCollapsed(hostA.id))
        #expect(!reloaded.isCollapsed(hostB.id))

        reloaded.toggleCollapsed(hostB.id)
        reloaded.toggleCollapsed(hostA.id)
        let reloadedAgain = ConsoleListPresentationStore(defaults: defaults)
        #expect(!reloadedAgain.isCollapsed(hostA.id))
        #expect(reloadedAgain.isCollapsed(hostB.id))
    }

    @Test func sectionsFollowCatalogOrderAndFilterToAtMostOneHost() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let first = Host.fixture(name: "zeta")
        let second = Host.fixture(name: "alpha")
        let store = ConsoleListPresentationStore(defaults: defaults)

        let all = store.sections(hosts: [first, second], agents: [])
        #expect(all.map(\.hostID) == [first.id, second.id])

        let filtered = store.sections(
            hosts: [first, second], agents: [], filteredHostID: second.id)
        #expect(filtered.map(\.hostID) == [second.id])

        let missing = store.sections(
            hosts: [first, second], agents: [], filteredHostID: UUID())
        #expect(missing.isEmpty)
    }

    @Test func sectionsPreserveTheSuppliedAgentOrderWithinEachHost() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let hostA = Host.fixture(name: "alpha")
        let hostB = Host.fixture(name: "beta")
        let aIdle = consoleAgent(host: hostA, paneID: "opaque-A", status: .idle)
        let bBlocked = consoleAgent(host: hostB, paneID: "%opaque-B", status: .blocked)
        let aDone = consoleAgent(host: hostA, paneID: "opaque-C", status: .done)
        let bWorking = consoleAgent(host: hostB, paneID: "opaque-D", status: .working)
        let store = ConsoleListPresentationStore(defaults: defaults)

        let sections = store.sections(
            hosts: [hostA, hostB],
            agents: [aIdle, bBlocked, aDone, bWorking])

        #expect(sections[0].agents.map(\.agent.paneID) == ["opaque-A", "opaque-C"])
        #expect(sections[1].agents.map(\.agent.paneID) == ["%opaque-B", "opaque-D"])
    }

    @Test func changedInputsReprojectMembershipAndReadiness() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture(name: "studio")
        let working = consoleAgent(host: host, paneID: "pane-1", status: .working)
        let done = consoleAgent(host: host, paneID: "pane-2", status: .done)
        let store = ConsoleListPresentationStore(defaults: defaults)

        let loading = store.sections(
            hosts: [host],
            agents: [working],
            hostStatuses: [host.id: .connected],
            hostsAwaitingSnapshot: [host.id])
        #expect(loading[0].agents.map(\.id) == [working.id])
        #expect(loading[0].isAwaitingSnapshot)
        #expect(loading[0].statusPresentation?.message == "Loading Agents from studio…")

        let refreshed = store.sections(
            hosts: [host],
            agents: [done],
            hostStatuses: [host.id: .connected])
        #expect(refreshed[0].agents.map(\.id) == [done.id])
        #expect(!refreshed[0].isAwaitingSnapshot)
        #expect(refreshed[0].statusPresentation == nil)
    }

    @Test func emptyAndDisconnectedHostsRemainSections() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let empty = Host.fixture(name: "empty")
        let disconnected = Host.fixture(name: "offline")
        let failure = TransportError.sshUnreachable(detail: "connection refused")
        let store = ConsoleListPresentationStore(defaults: defaults)

        let sections = store.sections(
            hosts: [empty, disconnected],
            agents: [],
            hostStatuses: [
                empty.id: .connected,
                disconnected.id: .failed(failure),
            ])

        #expect(sections.count == 2)
        #expect(sections[0].agents.isEmpty)
        #expect(sections[1].agents.isEmpty)
        #expect(sections[0].connectionStatus == .connected)
        #expect(sections[0].statusPresentation == nil)
        #expect(sections[1].connectionStatus == .failed(failure))
        #expect(sections[1].statusPresentation?.hostID == disconnected.id)
    }

    @Test func statusCountsMatchLiveActivityStatusesEvenWhenCollapsed() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let host = Host.fixture()
        let agents = [
            consoleAgent(host: host, paneID: "blocked", status: .blocked),
            consoleAgent(host: host, paneID: "done", status: .done),
            consoleAgent(host: host, paneID: "working", status: .working),
            consoleAgent(host: host, paneID: "idle", status: .idle),
            consoleAgent(
                host: host, paneID: "unknown", status: AgentStatus(rawValue: "future")),
        ]
        let store = ConsoleListPresentationStore(defaults: defaults)
        store.setCollapsed(true, for: host.id)

        let section = try #require(store.sections(hosts: [host], agents: agents).first)
        #expect(section.isCollapsed)
        #expect(section.statusCounts == .init(blocked: 1, working: 1, done: 1))
        #expect(section.statusCounts.items.map(\.status) == [.blocked, .working, .done])
    }
}

@Suite("Agent card presentation")
struct AgentCardPresentationTests {
    @Test func defaultsShowWorkspaceThenAgentWithoutTheOldDirectoryRow() {
        let card = AgentCardPresentation(agent: agent(workspace: "Project"))
        #expect(card.headline == "Project")
        #expect(card.additionalRows == ["reviewer"])
    }

    @Test func configuredTitlesAndPluginTextStayLiteralAndRetainStyles() throws {
        let layout = AgentRowLayout(rows: [
            [.init(.stateIcon), .init(.terminalTitleStripped, fg: HexColor("#abc"), bold: true)],
            [.init(.custom("note")), .init(.agent)],
        ])
        let card = AgentCardPresentation(agent: agent(), layout: layout)
        #expect(card.headline == "Task title")
        #expect(card.additionalRows == ["**literal** [link](url) · reviewer"])
        let first = try #require(card.rows.first?.first)
        #expect(first.fg == HexColor("#abc") && first.bold == true)
    }

    @Test func kindOverridesReplaceAllRowsAndSkipEmptyStatusRows() {
        let layout = AgentRowLayout(rows: [[.init(.workspace)]], rowsByAgent: [
            "claude": [[.init(.stateText)], [.init(.terminalTitle)], [.init(.custom("missing"))]],
        ])
        let card = AgentCardPresentation(agent: agent(), layout: layout)
        #expect(card.headline == "◑ Task title")
        #expect(card.additionalRows.isEmpty)
    }

    @Test func emptyLayoutsAndMissingValuesKeepAnIdentifiableAgent() {
        for layout in [AgentRowLayout(rows: []), AgentRowLayout(rows: [[], [.init(.custom("absent"))]])] {
            let card = AgentCardPresentation(agent: agent(), layout: layout)
            #expect(card.headline == "reviewer")
            #expect(card.additionalRows.isEmpty)
        }
        #expect(AgentCardPresentation(agent: agent()).headline == "reviewer")
    }

    private func agent(workspace: String? = nil) -> ConsoleAgent {
        ConsoleAgent(
            hostID: UUID(), hostName: "devbox",
            agent: Agent(
                terminalID: "terminal", kind: "claude", title: "Old title", status: .blocked,
                workspaceID: "w", tabID: "t", paneID: "p", cwd: "/work/project", revision: 1,
                name: "reviewer", terminalTitle: "◑ Task title", terminalTitleStripped: "Task title",
                tokens: ["note": "**literal** [link](url)"]),
            workspaceLabel: workspace, repositoryCheckout: nil)
    }
}
