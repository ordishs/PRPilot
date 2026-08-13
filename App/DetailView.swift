import SwiftUI
import PRPilotModels
import AppCore

struct DetailView: View {
    let model: AppModel
    let webViewCache: WebViewCache
    let review: WorkItem
    @State private var pane: PaneSelection = .github

    var body: some View {
        VStack(spacing: 0) {
            if case .conflicted(let files) = model.rebaseStates[review.id] {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Rebase paused — \(files.count) conflict\(files.count == 1 ? "" : "s")")
                        .font(.callout)
                    Spacer()
                    Button("Resolve in Claude") { if !review.disabled { pane = .claude } }
                    Button("Continue") { Task { await model.continueRebase(id: review.id) } }
                    Button("Abort") { Task { await model.abortRebase(id: review.id) } }
                }
                .padding(8)
                .background(Color.orange.opacity(0.12))
            }
            if case .failed(let message) = model.rebaseStates[review.id] {
                HStack(spacing: 8) {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    Text("Rebase failed: \(message)").font(.callout).lineLimit(2)
                    Spacer()
                    Button("Dismiss") { Task { await model.abortRebase(id: review.id) } }
                }
                .padding(8)
                .background(Color.red.opacity(0.12))
            }
            HStack(spacing: 8) {
                Picker("", selection: $pane) {
                    ForEach(PaneSelection.allCases, id: \.self) { pane in
                        Text(pane.displayName(for: effectiveAgent))
                            .tag(pane)
                            .disabled(pane == .claude && review.disabled)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if pane == .claude && !review.disabled {
                    agentMenu
                }
            }
            .padding(8)
            .background { paneShortcuts }
            Divider()
            switch pane {
            case .github:
                WebPane(cache: webViewCache, review: review)
                    .id(review.id)
            case .claude:
                ClaudePaneView(model: model, review: review)
                    .id(review.id)
            }
        }
        .navigationTitle(review.number.map { "#\($0) \(review.title)" } ?? review.title)
        .onAppear { restorePaneForSelection() }
        .onChange(of: review.id) { _, _ in restorePaneForSelection() }
        .onChange(of: review.disabled) { _, disabled in
            if disabled && pane == .claude {
                pane = .github
            }
        }
        .onChange(of: pane) { _, selected in
            guard !review.disabled else { return }
            Task { await model.setPane(selected, for: review.id) }
        }
    }

    private var effectiveAgent: AgentKind {
        review.effectiveAgent(default: model.settings.defaultAgent)
    }

    /// Per-item agent choice. "Default" leaves the item following the global setting, so
    /// changing that setting still moves it.
    private var agentMenu: some View {
        Menu {
            Button {
                Task { await model.setAgent(nil, for: review.id) }
            } label: {
                Label(
                    "Default (\(model.settings.defaultAgent.displayName))",
                    systemImage: review.agent == nil ? "checkmark" : ""
                )
            }
            Divider()
            ForEach(AgentKind.allCases, id: \.self) { kind in
                Button {
                    Task { await model.setAgent(kind, for: review.id) }
                } label: {
                    Label(kind.displayName, systemImage: review.agent == kind ? "checkmark" : "")
                }
            }
        } label: {
            Label(effectiveAgent.displayName, systemImage: "cpu")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Which agent runs this item. Switching keeps each agent's own session.")
    }

    private func restorePaneForSelection() {
        pane = resolvedPane(for: review)
    }

    private var paneShortcuts: some View {
        ZStack {
            Button("") { if !review.disabled { pane = .claude } }
                .keyboardShortcut("1", modifiers: .command)
            Button("") { pane = .github }
                .keyboardShortcut("2", modifiers: .command)
        }
        .opacity(0)
    }
}
