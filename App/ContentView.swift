import AppKit
import SwiftUI
import PRPilotModels
import AppCore
import ClaudeSessionKit

struct ContentView: View {
    @Bindable var model: AppModel
    let webViewCache: WebViewCache
    @State private var showingAdd = false
    @State private var showingNewTask = false

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selection) {
                let sections = sidebarSections(
                    items: model.reviews,
                    myLogin: model.currentLogin,
                    sort: model.settings.sidebarSort
                )
                Section(isExpanded: myWorkExpandedBinding()) {
                    sectionBody(sections.myWork)
                } header: {
                    sectionHeader(title: "My Work", count: sections.myWork.count, accent: .blue)
                }
                Section(isExpanded: reviewsExpandedBinding()) {
                    sectionBody(sections.reviewRequests)
                } header: {
                    sectionHeader(title: "Review Requests", count: sections.reviewRequests.count, accent: .purple)
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
                        Picker("Sort", selection: sortBinding) {
                            ForEach(SidebarSort.allCases, id: \.self) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                    } label: {
                        Label("Sort", systemImage: "arrow.up.arrow.down")
                    }
                    .help("Sort items within each section by recency, status, or author")
                }
                ToolbarItem {
                    Menu {
                        Button { showingNewTask = true } label: { Label("New Task…", systemImage: "hammer") }
                        Button { showingAdd = true } label: { Label("Add PR by URL…", systemImage: "link") }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAdd) {
                AddPRSheet(model: model, isPresented: $showingAdd)
            }
            .sheet(isPresented: $showingNewTask) {
                NewTaskSheet(model: model, isPresented: $showingNewTask)
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

    private var sortBinding: Binding<SidebarSort> {
        Binding(
            get: { model.settings.sidebarSort },
            set: { newValue in
                var updated = model.settings
                updated.sidebarSort = newValue
                Task { await model.updateSettings(updated) }
            }
        )
    }

    private func myWorkExpandedBinding() -> Binding<Bool> {
        Binding(
            get: { !model.settings.myWorkCollapsed },
            set: { expanded in
                var updated = model.settings
                updated.myWorkCollapsed = !expanded
                Task { await model.updateSettings(updated) }
            }
        )
    }

    private func reviewsExpandedBinding() -> Binding<Bool> {
        Binding(
            get: { !model.settings.reviewsCollapsed },
            set: { expanded in
                var updated = model.settings
                updated.reviewsCollapsed = !expanded
                Task { await model.updateSettings(updated) }
            }
        )
    }

    @ViewBuilder
    private func sectionBody(_ items: [WorkItem]) -> some View {
        if items.isEmpty {
            Text("Nothing here yet")
                .font(.callout)
                .foregroundStyle(.tertiary)
        } else {
            ForEach(items) { review in
                sidebarRow(for: review)
                    .tag(review.id as String?)
            }
        }
    }

    private func sectionHeader(title: String, count: Int, accent: Color) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(accent)
                .frame(width: 3, height: 14)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.5)
            Spacer()
            Text("\(count)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
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
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let status = model.prStatuses[review.id] {
                    HStack(spacing: 4) {
                        switch status.ci {
                        case .passing: StateBadge(text: "✓ CI", color: .green)
                        case .failing: StateBadge(text: "✗ CI", color: .red)
                        case .pending: StateBadge(text: "◷ CI", color: .orange)
                        case .none: EmptyView()
                        }
                        if status.isBehind { StateBadge(text: "behind", color: .orange) }
                        if status.readiness == .changesRequested { StateBadge(text: "changes", color: .red) }
                    }
                }
                Text(relativeDateLabel(for: review.addedAt))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            StatusDot(status: model.claudeStatuses[review.id])
                .help(statusTooltip(model.claudeStatuses[review.id]))
        }
        .opacity(review.disabled ? 0.45 : 1.0)
        .contextMenu {
            if review.category(myLogin: model.currentLogin) != .reviewRequest, review.headBranch != nil {
                Button {
                    Task { await model.rebase(id: review.id) }
                } label: { Label("Rebase on \(review.baseBranch)", systemImage: "arrow.triangle.merge") }
                Button {
                    Task { await model.push(id: review.id) }
                } label: { Label("Push", systemImage: "arrow.up.circle") }
                .disabled(!(model.pushability[review.id]?.canPush ?? false))
                Divider()
            }
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
            .font(.system(size: 11, weight: .semibold))
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
