import SwiftUI

/// Pi's question, asked natively. Answering here answers Pi, and the
/// terminal's own dialog closes with it; answering there closes this sheet.
struct PiDialogSheet: View {
    let dialog: PiConversationDialog
    let onAnswer: (PiDialogAnswer) -> Void
    @State private var text = ""
    @FocusState private var isTextFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                switch dialog.kind {
                case .select: select
                case .confirm: confirm
                case .input: input
                case .questions:
                    PiQuestionnaire(questions: dialog.questions ?? []) { onAnswer(.answers($0)) }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { onAnswer(.cancel) }
                }
                if dialog.kind == .input {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Send") { onAnswer(.text(text)) }
                    }
                }
            }
        }
        // Pi waits for an answer: Cancel is one, a swipe away is not.
        .interactiveDismissDisabled()
        .presentationDetents(dialog.kind == .questions ? [.medium, .large] : [.medium])
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        // Solid, so the transcript behind never runs through the question.
        .presentationBackground(Color(uiColor: .systemGroupedBackground))
    }

    private var title: some View {
        Text(verbatim: dialog.title ?? "")
            .font(.headline)
            .foregroundStyle(.primary)
            .textCase(nil)
    }

    private var select: some View {
        List {
            Section {
                ForEach(Array((dialog.options ?? []).enumerated()), id: \.offset) { index, option in
                    Button { onAnswer(.option(index)) } label: {
                        Text(verbatim: option)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            } header: { title }
        }
    }

    private var confirm: some View {
        VStack(alignment: .leading, spacing: 12) {
            title
            if let message = dialog.message, !message.isEmpty {
                Text(verbatim: message).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button { onAnswer(.confirmed(true)) } label: {
                Text("Yes").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            Button { onAnswer(.confirmed(false)) } label: {
                Text("No").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.large)
        .padding(20)
    }

    private var input: some View {
        Form {
            Section {
                TextField(dialog.placeholder ?? "", text: $text, axis: .vertical)
                    .focused($isTextFocused)
                    .submitLabel(.send)
                    .onSubmit { onAnswer(.text(text)) }
            } header: { title }
        }
        .onAppear { isTextFocused = true }
    }
}

/// ask_user_question's questions, one page each. A single pick moves on by
/// itself; several picks or typed text move on with Next.
private struct PiQuestionnaire: View {
    let questions: [PiConversationDialog.Question]
    let onSubmit: ([PiQuestionAnswer]) -> Void
    @State private var page = 0
    @State private var picks: [Int: Set<Int>] = [:]
    @State private var typed: [Int: String] = [:]
    @FocusState private var isTypingFocused: Bool

    var body: some View {
        if questions.indices.contains(page) {
            questionPage(questions[page])
                .toolbar {
                    if page > 0 {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Back", systemImage: "chevron.backward") { page -= 1 }
                        }
                    }
                    if questions.count > 1 {
                        ToolbarItem(placement: .principal) {
                            Text("\(page + 1) of \(questions.count)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(page == questions.count - 1 ? "Submit" : "Next") { advance() }
                            .disabled(!isAnswered(page))
                    }
                }
        }
    }

    private func questionPage(_ question: PiConversationDialog.Question) -> some View {
        let multiple = question.multiSelect == true
        return List {
            Section {
                ForEach(Array((question.options ?? []).enumerated()), id: \.offset) { index, option in
                    Button { pick(index, multiple: multiple) } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(verbatim: option.label)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.primary)
                                if let description = option.description, !description.isEmpty {
                                    Text(verbatim: description)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                            if picks[page]?.contains(index) == true {
                                Image(systemName: "checkmark")
                                    .font(.body.weight(.semibold))
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                TextField("Type something", text: typedText, axis: .vertical)
                    .focused($isTypingFocused)
                    .submitLabel(.next)
                    .onSubmit { if isAnswered(page) { advance() } }
            } header: {
                VStack(alignment: .leading, spacing: 6) {
                    if let header = question.header, !header.isEmpty {
                        Text(verbatim: header.uppercased())
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    Text(verbatim: question.question)
                        .font(.headline)
                        .foregroundStyle(.primary)
                }
                .textCase(nil)
                .padding(.bottom, 4)
            } footer: {
                if multiple { Text("Pick any that apply.") }
            }
        }
    }

    /// Typing replaces the picks: the answer is one or the other.
    private var typedText: Binding<String> {
        Binding {
            typed[page] ?? ""
        } set: { value in
            typed[page] = value
            if !value.isEmpty { picks[page] = nil }
        }
    }

    private func pick(_ index: Int, multiple: Bool) {
        typed[page] = nil
        isTypingFocused = false
        if multiple {
            picks[page, default: []].formSymmetricDifference([index])
        } else {
            picks[page] = [index]
            advance()
        }
    }

    private func isAnswered(_ index: Int) -> Bool {
        !(picks[index] ?? []).isEmpty
            || !(typed[index] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func advance() {
        if let next = questions.indices.first(where: { $0 > page && !isAnswered($0) })
            ?? (page + 1 < questions.count ? page + 1 : nil)
        {
            page = next
        } else if questions.indices.allSatisfy(isAnswered) {
            onSubmit(questions.indices.map { index in
                let text = (typed[index] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty
                    ? PiQuestionAnswer(questionIndex: index, optionIndexes: (picks[index] ?? []).sorted())
                    : PiQuestionAnswer(questionIndex: index, text: text)
            })
        } else if let missing = questions.indices.first(where: { !isAnswered($0) }) {
            page = missing
        }
    }
}
