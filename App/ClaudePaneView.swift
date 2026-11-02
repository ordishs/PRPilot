import SwiftUI
import AppKit
import PRPilotModels
import AppCore
import AgentKit
import SwiftTerm

private let prepLogTimeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
}()

struct ClaudePaneView: View {
    let model: AppModel
    let review: WorkItem
    @State private var showPrepDetails = false
    @State private var showPrepLog = false

    var body: some View {
        Group {
            if review.disabled {
                disabledView()
            } else {
                switch model.claudePaneState[review.id] ?? .idle {
                case .idle, .preparingWorktree:
                    prepProgressView()
            case .worktreeFailed(let message):
                worktreeFailureView(message: message)
            case .claudeUnavailable(let message):
                claudeUnavailableView(message: message)
            case .sessionLive:
                if let session = model.claudeSessions[review.id] {
                    VStack(spacing: 0) {
                        exitOverlay(for: session)
                        if let questions = model.unansweredQuestions[review.id] {
                            ForEach(questions) { question in
                                UnansweredQuestionBar(
                                    question: question,
                                    onAnswer: { choices in
                                        model.answerUnansweredQuestion(question, choices: choices, for: review.id)
                                    },
                                    onDismiss: {
                                        model.removeUnansweredQuestion(question, for: review.id)
                                    }
                                )
                            }
                        }
                        TerminalHost(session: session)
                    }
                    .overlay(alignment: .topTrailing) {
                        if !prepEntries.isEmpty {
                            prepLogToggle()
                        }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                }
            }
        }
        .task(id: review.id) {
            await model.reconcileTerminalAppearance(for: review)
            await model.ensureAgentSession(for: review)
        }
        .onChange(of: review.id) {
            showPrepDetails = false
            showPrepLog = false
        }
        .onChange(of: review.disabled) {
            if !review.disabled {
                Task { await model.ensureAgentSession(for: review) }
            }
        }
    }

    @ViewBuilder
    private func disabledView() -> some View {
        VStack(spacing: 10) {
            Image(systemName: "pause.circle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Claude review is disabled for this PR")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Enable it from the PR’s context menu to start a review.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    @ViewBuilder
    private func prepLogToggle() -> some View {
        Button {
            showPrepLog.toggle()
        } label: {
            Image(systemName: "list.bullet.rectangle")
        }
        .buttonStyle(.borderless)
        .help("Show preparation log")
        .padding(6)
        .popover(isPresented: $showPrepLog, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Preparation log")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                prepLogList()
            }
            .padding(10)
            .frame(width: 380, height: 260)
        }
    }

    private var prepEntries: [PrepLogEntry] {
        model.claudePrepLog[review.id] ?? []
    }

    @ViewBuilder
    private func prepProgressView() -> some View {
        VStack(spacing: 10) {
            ProgressView()
            Text(prepEntries.last?.message ?? "Preparing…")
                .font(.callout)
                .foregroundStyle(.secondary)
            if !prepEntries.isEmpty {
                DisclosureGroup("Show details", isExpanded: $showPrepDetails) {
                    prepLogList()
                        .frame(maxHeight: 180)
                }
                .font(.caption)
                .frame(maxWidth: 360)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func prepLogList() -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(prepEntries) { entry in
                    Text("\(prepLogTimeFormatter.string(from: entry.date))  \(entry.message)")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func worktreeFailureView(message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Couldn't prepare the worktree")
                .font(.headline)
            if !prepEntries.isEmpty {
                prepLogList()
                    .frame(maxHeight: 140)
            }
            ScrollView {
                Text(message)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("Retry") {
                Task { await model.ensureAgentSession(for: review) }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func claudeUnavailableView(message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("claude not found")
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Retry") {
                Task { await model.ensureAgentSession(for: review) }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func exitOverlay(for session: AgentSession) -> some View {
        switch session.state {
        case .exited(let code):
            ExitBanner(
                title: "claude exited",
                subtitle: "code \(code)",
                isError: false,
                onRestart: { session.restart() }
            )
        case .failedToLaunch(let message):
            ExitBanner(
                title: message.contains("not found") ? "claude not found" : "claude failed to launch",
                subtitle: message,
                isError: true,
                onRestart: { session.restart() }
            )
        case .starting, .running:
            EmptyView()
        }
    }
}

private struct UnansweredQuestionBar: View {
    let question: AskedQuestion
    let onAnswer: ([String]) -> Void
    let onDismiss: () -> Void
    @State private var selected: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("The agent asked this before it stopped")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(question.question).font(.callout).bold()
                }
                Spacer(minLength: 8)
                Button("Dismiss", action: onDismiss)
                    .buttonStyle(.borderless)
                    .help("Hide these options and answer in the terminal instead")
            }
            WrappingHStack(spacing: 6) {
                ForEach(question.options, id: \.label) { option in
                    optionButton(option)
                }
            }
            if question.multiSelect {
                Button("Send answer") { onAnswer(selected) }
                    .disabled(selected.isEmpty)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.accentColor.opacity(0.6), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(8)
    }

    @ViewBuilder
    private func optionButton(_ option: AskedQuestion.Option) -> some View {
        let isSelected = selected.contains(option.label)
        Button {
            if question.multiSelect {
                if isSelected {
                    selected.removeAll { $0 == option.label }
                } else {
                    selected.append(option.label)
                }
            } else {
                onAnswer([option.label])
            }
        } label: {
            Text(option.label)
        }
        .buttonStyle(.bordered)
        .tint(isSelected ? .accentColor : nil)
        .help(option.detail)
    }
}

private struct ExitBanner: View {
    let title: String
    let subtitle: String
    let isError: Bool
    let onRestart: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout).bold()
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            Button("Restart", action: onRestart)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isError ? Color.red.opacity(0.6) : Color.secondary.opacity(0.4), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(8)
    }
}

private struct TerminalHost: NSViewRepresentable {
    let session: AgentSession

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let terminal = session.terminalView
        terminal.removeFromSuperview()
        terminal.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.topAnchor.constraint(equalTo: container.topAnchor),
            terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        DispatchQueue.main.async {
            container.layoutSubtreeIfNeeded()
            terminal.window?.makeFirstResponder(terminal)
        }
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
