import AppKit
import SwiftUI
import PRPilotModels
import AppCore
import ClaudeSessionKit

struct ContentView: View {
    @Bindable var model: AppModel
    let webViewCache: WebViewCache
    @State private var showingAdd = false

    var body: some View {
        NavigationSplitView {
            Group {
                if model.settings.sidebarGrouping == .none {
                    List(model.reviews.sorted { $0.addedAt > $1.addedAt }, selection: $model.selection) { review in
                        sidebarRow(for: review)
                    }
                } else {
                    List(selection: $model.selection) {
                        ForEach(groupedReviews(), id: \.title) { group in
                            Section(group.title) {
                                ForEach(group.reviews) { review in
                                    sidebarRow(for: review)
                                        .tag(review.id as String?)
                                }
                            }
                        }
                    }
                }
            }
            .onDeleteCommand {
                if let id = model.selection {
                    Task { await model.removeReview(id: id) }
                }
            }
            .navigationTitle("Reviews")
            .frame(minWidth: 260)
            .toolbar {
                ToolbarItem {
                    Menu {
                        Picker("Group by", selection: groupingBinding) {
                            ForEach(SidebarGrouping.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                    } label: {
                        Label("Group", systemImage: "rectangle.3.group")
                    }
                    .help("Group sidebar by category, date, author, status, or none")
                }
                ToolbarItem {
                    Button {
                        showingAdd = true
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAdd) {
                AddPRSheet(model: model, isPresented: $showingAdd)
            }
        } detail: {
            if let review = model.selectedReview() {
                DetailView(model: model, webViewCache: webViewCache, review: review)
            } else {
                Text("Select a review")
                    .foregroundStyle(.secondary)
                    .font(.title3)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .alert("Couldn't add PR", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.dismissError() } }
        )) {
            Button("OK") { model.dismissError() }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onChange(of: model.selection) { _, newSelection in
            guard let id = newSelection,
                  let review = model.reviews.first(where: { $0.id == id }) else { return }
            model.prefetch(for: review)
            _ = webViewCache.ensure(for: review)
            Task { await model.markReviewOpened(id) }
        }
    }

    @ViewBuilder
    private func sidebarRow(for review: WorkItem) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(review.number.map { "#\($0) · \(review.title)" } ?? review.title)
                        .lineLimit(1)
                    statusBadge(for: review)
                }
                Text("\(review.owner)/\(review.repo) · \(review.author ?? "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(relativeDateLabel(for: review.addedAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            StatusDot(status: model.claudeStatuses[review.id])
                .help(statusTooltip(model.claudeStatuses[review.id]))
        }
        .opacity(review.disabled ? 0.45 : 1.0)
        .contextMenu {
            Button {
                if let sessionID = review.claudeSessionID {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(sessionID, forType: .string)
                }
            } label: {
                Label("Copy Session ID", systemImage: "doc.on.clipboard")
            }
            .disabled(review.claudeSessionID == nil)
            Button {
                Task { await model.clearClaudeSession(for: review.id) }
            } label: {
                Label("Clear Claude Session", systemImage: "xmark.circle")
            }
            .disabled(review.claudeSessionID == nil)
            Divider()
            Button {
                Task { await model.setReviewDisabled(!review.disabled, for: review.id) }
            } label: {
                Label(review.disabled ? "Enable" : "Disable", systemImage: review.disabled ? "play.circle" : "pause.circle")
            }
            Divider()
            Button(role: .destructive) {
                Task { await model.removeReview(id: review.id) }
            } label: {
                Label("Remove from List", systemImage: "trash")
            }
        }
    }

    private struct ReviewGroup: Identifiable {
        let title: String
        let reviews: [WorkItem]
        var id: String { title }
    }

    private var groupingBinding: Binding<SidebarGrouping> {
        Binding(
            get: { model.settings.sidebarGrouping },
            set: { newValue in
                var updated = model.settings
                updated.sidebarGrouping = newValue
                Task { await model.updateSettings(updated) }
            }
        )
    }

    private func groupedReviews() -> [ReviewGroup] {
        switch model.settings.sidebarGrouping {
        case .byCategory:
            return groupByCategory()
        case .none:
            return [ReviewGroup(title: "", reviews: model.reviews.sorted { $0.addedAt > $1.addedAt })]
        case .byDate:
            return groupByDate()
        case .byAuthor:
            return groupByAuthor()
        case .byStatus:
            return groupByStatus()
        }
    }

    private func groupByCategory() -> [ReviewGroup] {
        let myLogin = model.currentLogin
        var myWork: [WorkItem] = []
        var reviewRequests: [WorkItem] = []
        for review in model.reviews {
            switch review.category(myLogin: myLogin) {
            case .task, .myPR:
                myWork.append(review)
            case .reviewRequest:
                reviewRequests.append(review)
            }
        }
        var groups: [ReviewGroup] = []
        if !myWork.isEmpty {
            groups.append(ReviewGroup(title: "My Work", reviews: myWork.sorted { $0.addedAt > $1.addedAt }))
        }
        if !reviewRequests.isEmpty {
            groups.append(ReviewGroup(title: "Review Requests", reviews: reviewRequests.sorted { $0.addedAt > $1.addedAt }))
        }
        return groups
    }

    private func groupByDate() -> [ReviewGroup] {
        let buckets: [(String, (WorkItem) -> Bool)] = [
            ("Today", { Calendar.current.isDateInToday($0.addedAt) }),
            ("Yesterday", { Calendar.current.isDateInYesterday($0.addedAt) }),
            ("This Week", { daysAgo($0.addedAt) < 7 }),
            ("Last Week", { daysAgo($0.addedAt) < 14 }),
            ("Older", { _ in true })
        ]
        var remaining = model.reviews
        var groups: [ReviewGroup] = []
        for (title, predicate) in buckets {
            let (match, rest) = remaining.partitioned(by: predicate)
            if !match.isEmpty {
                groups.append(ReviewGroup(title: title, reviews: match.sorted { $0.addedAt > $1.addedAt }))
            }
            remaining = rest
        }
        return groups
    }

    private func groupByAuthor() -> [ReviewGroup] {
        let byAuthor = Dictionary(grouping: model.reviews) { $0.author ?? "unknown" }
        return byAuthor.keys.sorted().map { author in
            ReviewGroup(title: author, reviews: byAuthor[author]!.sorted { $0.addedAt > $1.addedAt })
        }
    }

    private func groupByStatus() -> [ReviewGroup] {
        let order: [(PRState, String)] = [(.open, "Open"), (.draft, "Draft"), (.merged, "Merged"), (.closed, "Closed")]
        return order.compactMap { (state, title) in
            let matching = model.reviews.filter { $0.prState == state }
            guard !matching.isEmpty else { return nil }
            return ReviewGroup(title: title, reviews: matching.sorted { $0.addedAt > $1.addedAt })
        }
    }

    private func daysAgo(_ date: Date) -> Int {
        Calendar.current.dateComponents([.day], from: date, to: Date()).day ?? 0
    }

    @ViewBuilder
    private func statusBadge(for review: WorkItem) -> some View {
        switch review.sidebarStatus {
        case .merged:
            StateBadge(text: "Merged", color: .purple)
        case .closed:
            StateBadge(text: "Closed", color: .red)
        case .approved:
            StateBadge(text: "Approved", color: .green)
        case .new:
            StateBadge(text: "New", color: .orange)
        case .reviewed:
            StateBadge(text: "Reviewed", color: .blue)
        case .draft:
            StateBadge(text: "Draft", color: .gray)
        case .open:
            EmptyView()
        }
    }
}

private struct StateBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.5)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.22))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

private struct StatusDot: View {
    let status: ClaudeStatus?
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .opacity(isWorking && pulse ? 0.3 : 1.0)
            .onAppear {
                if isWorking {
                    withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulse = true }
                }
            }
            .onChange(of: isWorking) { _, working in
                if working {
                    withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulse = true }
                } else {
                    withAnimation(.default) { pulse = false }
                }
            }
    }

    private var isWorking: Bool { status == .working }

    private var color: Color {
        switch status {
        case .working:
            return .blue
        case .idle:
            return .gray
        case .ready(let code):
            return code == 0 ? .green : .orange
        case .failed:
            return .red
        case .starting, nil:
            return .clear
        }
    }
}

private func statusTooltip(_ status: ClaudeStatus?) -> String {
    switch status {
    case .working:
        return "Working"
    case .idle(let since, let snippet):
        let elapsed = Int(Date().timeIntervalSince(since))
        let mins = max(elapsed / 60, 0)
        let base = mins > 0 ? "Idle \(mins)m" : "Idle"
        if let snippet, !snippet.isEmpty {
            return "\(base) · \(snippet)"
        }
        return base
    case .ready(let code):
        return code == 0 ? "Review ready" : "Exited · code \(code)"
    case .failed(let reason):
        return reason
    case .starting:
        return "Starting…"
    case nil:
        return ""
    }
}

private func relativeDateLabel(for date: Date) -> String {
    let calendar = Calendar.current
    let now = Date()
    if calendar.isDateInToday(date) { return "Today" }
    if calendar.isDateInYesterday(date) { return "Yesterday" }
    let daysAgo = calendar.dateComponents([.day], from: date, to: now).day ?? 0
    if daysAgo < 7 { return "This Week" }
    if daysAgo < 14 { return "Last Week" }
    return "Older"
}

private extension Array {
    func partitioned(by predicate: (Element) -> Bool) -> (matching: [Element], rest: [Element]) {
        var matching: [Element] = []
        var rest: [Element] = []
        for element in self {
            if predicate(element) {
                matching.append(element)
            } else {
                rest.append(element)
            }
        }
        return (matching, rest)
    }
}
