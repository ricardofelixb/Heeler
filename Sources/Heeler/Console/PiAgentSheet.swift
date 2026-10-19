import SwiftUI

/// The Agent behind the conversation header's capsule: the running Pi's
/// model and thinking level, what the session has used, then the screen's
/// other views. Settings changes go to Pi, which answers with what it applied.
struct PiAgentSheet: View {
    let store: PiConversationStore
    let avatar: Image
    let name: String
    let actions: [AgentDetailHeaderAction]
    /// The Agent's Host, whose screen the sheet shows when it has one.
    var host: Host?
    var screenSettings = RemoteScreenSettingsStore()
    @Environment(\.dismiss) private var dismiss
    /// The preview's session; full control replaces it, one connection at a time.
    @State private var screen: RemoteScreenSession?
    @State private var isScreenPresented = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        avatar
                            .renderingMode(.original)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 44, height: 44)
                            .accessibilityHidden(true)
                        Text(verbatim: name)
                            .font(.headline)
                            .lineLimit(2)
                    }
                }
                if let settings = store.settings {
                    Section {
                        modelRow(settings)
                        if let model = settings.model, model.thinkingLevels.count > 1 {
                            PiThinkingRow(
                                levels: model.thinkingLevels,
                                current: settings.thinking ?? model.thinkingLevels[0]
                            ) { store.send(.setThinking($0)) }
                        }
                        if let usage = settings.usage { PiContextRow(usage: usage) }
                    }
                    if let limits = settings.usage?.limits, !limits.isEmpty {
                        Section("Weekly Usage") {
                            ForEach(limits, id: \.label) { PiLimitRow(limit: $0) }
                        }
                    }
                }
                if let host, let screen, showsScreen(screen, of: host) {
                    Section("Screen") {
                        RemoteScreenPreview(hostName: host.name, session: screen) {
                            screen.stop()
                            self.screen = nil
                            isScreenPresented = true
                            RemoteScreenPresenter.present(title: host.name) {
                                RemoteScreenSession(host: host, store: screenSettings, viewOnly: false)
                            } onClose: {
                                isScreenPresented = false
                                startPreview()
                            }
                        }
                        .listRowInsets(EdgeInsets())
                    }
                }
                if !actions.isEmpty {
                    Section {
                        ForEach(actions) { action in
                            Button(action.title, systemImage: action.systemImage) {
                                dismiss()
                                action.perform()
                            }
                        }
                    }
                }
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear(perform: startPreview)
        .onDisappear {
            screen?.stop()
            screen = nil
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func startPreview() {
        guard let host, screen == nil, !isScreenPresented else { return }
        screen = RemoteScreenSession(host: host, store: screenSettings, viewOnly: true)
    }

    /// Every Host is expected to have a screen, so its place shows at once;
    /// only a Host that turns out to have none drops it.
    private func showsScreen(_ screen: RemoteScreenSession, of host: Host) -> Bool {
        screen.phase != .unavailable
    }

    /// The session's scoped models, one inline section per provider.
    private func modelRow(_ settings: PiConversationSettings) -> some View {
        let providers = Dictionary(grouping: settings.models, by: \.provider)
            .sorted { $0.key < $1.key }
        return Menu {
            ForEach(providers, id: \.key) { provider, models in
                Section(provider) {
                    ForEach(models, id: \.self) { model in
                        Button {
                            store.send(.setModel(provider: model.provider, id: model.id))
                        } label: {
                            if model == settings.model {
                                Label(model.name, systemImage: "checkmark")
                            } else {
                                Text(verbatim: model.name)
                            }
                        }
                    }
                }
            }
        } label: {
            LabeledContent("Model") {
                HStack(spacing: 4) {
                    Text(verbatim: settings.model?.name ?? "—")
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(.secondary)
            }
        }
        .disabled(settings.models.isEmpty)
        .tint(.primary)
    }
}

/// A slider over the levels the current model supports. Pi hears only the
/// level the finger settles on.
private struct PiThinkingRow: View {
    let levels: [String]
    let current: String
    let onChange: (String) -> Void
    @State private var position: Double = 0
    @State private var isEditing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent("Thinking") {
                Text(verbatim: levels[index].capitalized)
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: $position,
                in: 0...Double(levels.count - 1),
                step: 1
            ) { editing in
                isEditing = editing
                if !editing, levels[index] != current { onChange(levels[index]) }
            }
            .accessibilityValue(Text(verbatim: levels[index]))
        }
        .onAppear { sync() }
        .onChange(of: current) { if !isEditing { sync() } }
        .onChange(of: levels) { if !isEditing { sync() } }
    }

    private var index: Int { min(max(Int(position.rounded()), 0), levels.count - 1) }

    private func sync() {
        position = Double(levels.firstIndex(of: current) ?? 0)
    }
}

/// How full the model's context is, as one slim bar.
private struct PiContextRow: View {
    let usage: PiConversationSettings.Usage

    var body: some View {
        if let window = usage.contextWindow, window > 0 {
            let fraction = usage.contextPercent.map { min(max($0 / 100, 0), 1) }
                ?? usage.contextTokens.map { min(Double($0) / Double(window), 1) }
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Context") {
                    Text(verbatim: fraction.map { "\(Int(($0 * 100).rounded()))% of \(compact(window))" }
                        ?? compact(window))
                }
                if let fraction {
                    ProgressView(value: fraction)
                        .tint(fraction > 0.8 ? .orange : .accentColor)
                }
            }
        }
    }

    private func compact(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName).precision(.significantDigits(1...3)))
    }
}

/// A provider's weekly allowance: what's left, and when it starts over.
private struct PiLimitRow: View {
    let limit: PiConversationSettings.Limit

    var body: some View {
        LabeledContent(limit.label) {
            Text(verbatim: "\(limit.left)% left · \(resetsIn)")
                .monospacedDigit()
                .foregroundStyle(limit.left < 15 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
        }
    }

    private var resetsIn: String {
        let hours = max(0, Int((limit.resetsAt / 1000 - Date.now.timeIntervalSince1970) / 3600 + 0.5))
        return hours >= 24 ? "\(Int((Double(hours) / 24).rounded()))d" : "\(hours)h"
    }
}
