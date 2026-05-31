import SwiftUI
import PRReviewModels
import AppCore

struct DetailView: View {
    let model: AppModel
    let webViewCache: WebViewCache
    let review: Review
    @State private var pane: Pane = .github

    enum Pane: String, CaseIterable, Identifiable {
        case claude = "Claude Review"
        case github = "GitHub"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
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
        .navigationTitle("#\(review.number) \(review.title)")
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
