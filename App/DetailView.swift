import SwiftUI
import PRPilotModels
import AppCore

struct DetailView: View {
    let model: AppModel
    let webViewCache: WebViewCache
    let review: WorkItem
    @State private var pane: Pane = .github

    enum Pane: String, CaseIterable, Identifiable {
        case claude = "Claude Review"
        case github = "GitHub"
        var id: String { rawValue }
    }

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
            Picker("", selection: $pane) {
                ForEach(Pane.allCases) { pane in
                    Text(pane.rawValue)
                        .tag(pane)
                        .disabled(pane == .claude && review.disabled)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
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
        .onChange(of: review.disabled) { _, disabled in
            if disabled && pane == .claude {
                pane = .github
            }
        }
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
