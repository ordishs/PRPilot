import SwiftUI
import AppKit
import PRPilotModels
import AppCore
import ClaudeSessionKit
import SwiftTerm

private let prepLogTimeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
}()

struct ClaudePaneView: View {
    let model: AppModel
    let review: Review
    @State private var showPrepDetails = false

    var body: some View {
        Group {
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
                        TerminalHost(session: session)
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task(id: review.id) {
            await model.ensureClaudeSession(for: review)
        }
        .onChange(of: review.id) {
            showPrepDetails = false
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
                        .font(.system(.caption, design: .monospaced))
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
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Button("Retry") {
                Task { await model.ensureClaudeSession(for: review) }
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
                Task { await model.ensureClaudeSession(for: review) }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func exitOverlay(for session: ClaudeSession) -> some View {
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
    let session: ClaudeSession

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
