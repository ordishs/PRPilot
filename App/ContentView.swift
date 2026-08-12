import AppKit
import SwiftUI
import PRPilotModels
import AppCore
import ClaudeSessionKit

struct ContentView: View {
    @Bindable var model: AppModel
    let webViewCache: WebViewCache
    @State private var showingAdd = false
    @State private var showingAddIssue = false
    @State private var showingNewTask = false
    @State private var labelTarget: WorkItem?
    @State private var searchText = ""
    @State private var sidebarFilter: SidebarFilter = .all
    @Environment(\.colorScheme) private var colorScheme

    private func isWorking(_ id: String) -> Bool { model.claudeStatuses[id] == .working }
    private func isAwaiting(_ id: String) -> Bool {
        if case .awaitingInput = model.claudeStatuses[id] { return true }
        return false
    }
    private var filteredReviews: [WorkItem] {
        model.reviews.filter {
            sidebarItemMatches($0, query: searchText, filter: sidebarFilter,
                               isWorking: isWorking($0.id), isAwaiting: isAwaiting($0.id))
        }
    }
    private var activeCount: Int { model.reviews.filter { isWorking($0.id) || isAwaiting($0.id) }.count }
    private var awaitingCount: Int { model.reviews.filter { isAwaiting($0.id) }.count }

    private var sidebarHeader: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary).font(.system(size: 12))
                TextField("Search", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Color.secondary.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            HStack(spacing: 6) {
                filterPill(.all, label: "All", count: nil)
                filterPill(.active, label: "Active", count: activeCount)
                filterPill(.awaiting, label: "Awaiting", count: awaitingCount)
                Spacer()
            }
        }
        .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
    }

    @ViewBuilder
    private func filterPill(_ f: SidebarFilter, label: String, count: Int?) -> some View {
        Button { sidebarFilter = f } label: {
            HStack(spacing: 4) {
                Text(label)
                if let count { Text("\(count)").opacity(0.7) }
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(sidebarFilter == f ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                sidebarHeader
                List(selection: $model.selection) {
                let sections = sidebarSections(
                    items: filteredReviews,
                    myLogin: model.currentLogin,
                    sort: model.settings.sidebarSort
                )
                Section(isExpanded: myWorkExpandedBinding()) {
                    sectionBody(sections.myWork)
                } header: {
                    SidebarSectionHeader(title: "My Work", count: sections.myWork.count, kind: .myWork)
                }
                Section(isExpanded: reviewsExpandedBinding()) {
                    sectionBody(sections.reviewRequests)
                } header: {
                    SidebarSectionHeader(title: "Review Requests", count: sections.reviewRequests.count, kind: .reviewRequests)
                }
                Section(isExpanded: issuesExpandedBinding()) {
                    sectionBody(sections.issues)
                } header: {
                    SidebarSectionHeader(title: "Issues", count: sections.issues.count, kind: .issues)
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
                        Button { showingAddIssue = true } label: { Label("Add Issue by URL…", systemImage: "exclamationmark.circle") }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAdd) {
                AddPRSheet(model: model, isPresented: $showingAdd)
            }
            .sheet(isPresented: $showingAddIssue) {
                AddIssueSheet(model: model, isPresented: $showingAddIssue)
            }
            .sheet(isPresented: $showingNewTask) {
                NewTaskSheet(model: model, isPresented: $showingNewTask)
            }
            .sheet(item: $labelTarget) { item in
                LabelSheet(item: item) { newLabel in
                    Task { await model.setLabel(newLabel, for: item.id) }
                }
            }
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
            webViewCache.selectedID = id
            webViewCache.cap = model.settings.maxLiveWebViews
            _ = webViewCache.ensure(for: review)
            Task { await model.markReviewOpened(id) }
        }
        .onAppear {
            Task { await model.setTerminalAppearance(isDark: colorScheme == .dark) }
        }
        .onChange(of: colorScheme) { _, newValue in
            Task { await model.setTerminalAppearance(isDark: newValue == .dark) }
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

    private func issuesExpandedBinding() -> Binding<Bool> {
        Binding(
            get: { !model.settings.issuesCollapsed },
            set: { expanded in
                var updated = model.settings
                updated.issuesCollapsed = !expanded
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

    @ViewBuilder
    private func sidebarRow(for review: WorkItem) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(review.number.map { "#\($0) · \(review.title)" } ?? review.title)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                    statusBadge(for: review)
                }
                if let label = review.label {
                    HStack(spacing: 3) {
                        Image(systemName: "bookmark.fill").font(.system(size: 9))
                        Text(label).lineLimit(2)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                Text("\(review.owner)/\(review.repo) · \(review.author ?? "")")
                    .font(.system(size: 13))
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
                        if model.hasUnseenAuthorUpdate(review) { StateBadge(text: "Updated", color: .teal) }
                    }
                }
                if let push = model.pushability[review.id], push.ahead > 0 || push.behind > 0 {
                    HStack(spacing: 4) {
                        if push.ahead > 0 { StateBadge(text: "↑\(push.ahead)", color: .green) }
                        if push.behind > 0 { StateBadge(text: "↓\(push.behind)", color: .orange) }
                    }
                }
                Text(relativeDateLabel(for: review.addedAt))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            StatusDot(status: model.claudeStatuses[review.id])
                .help(statusTooltip(model.claudeStatuses[review.id]))
        }
        .opacity(review.disabled ? 0.45 : 1.0)
        .contextMenu {
            Button {
                labelTarget = review
            } label: {
                Label(review.label == nil ? "Add Label…" : "Edit Label…", systemImage: "bookmark")
            }
            if review.label != nil {
                Button {
                    Task { await model.setLabel(nil, for: review.id) }
                } label: {
                    Label("Clear Label", systemImage: "bookmark.slash")
                }
            }
            Divider()
            if review.category(myLogin: model.currentLogin) == .issue {
                Menu {
                    Button(IssueWorkStatus.onHold.displayName) { Task { await model.setIssueStatus(.onHold, for: review.id) } }
                    Button(IssueWorkStatus.done.displayName) { Task { await model.setIssueStatus(.done, for: review.id) } }
                    Button(IssueWorkStatus.inReview.displayName) { Task { await model.setIssueStatus(.inReview, for: review.id) } }
                    Button(IssueWorkStatus.reviewed.displayName) { Task { await model.setIssueStatus(.reviewed, for: review.id) } }
                    Button(IssueWorkStatus.new.displayName) { Task { await model.setIssueStatus(.new, for: review.id) } }
                    Divider()
                    Button("Clear (Auto)") { Task { await model.setIssueStatus(nil, for: review.id) } }
                } label: {
                    Label("Set Status", systemImage: "tag")
                }
                Divider()
            }
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
                if let worktreePath = review.worktreePath {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(worktreePath, forType: .string)
                }
            } label: {
                Label("Copy Worktree Path", systemImage: "folder")
            }
            .disabled(review.worktreePath == nil)
            Button {
                Task { await model.clearClaudeSession(for: review.id) }
            } label: {
                Label("Clear Claude Session", systemImage: "xmark.circle")
            }
            .disabled(review.claudeSessionID == nil)
            if review.prRef != nil {
                Button {
                    Task { await model.markAuthorUpdateSeen(id: review.id) }
                } label: {
                    Label("Clear Updated Badge", systemImage: "bell.slash")
                }
                .disabled(!model.hasUnseenAuthorUpdate(review))
            }
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
        if review.category(myLogin: model.currentLogin) == .issue {
            issueStatusBadge(for: review)
        } else {
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

    private func issueStatusColor(_ status: IssueWorkStatus) -> Color {
        switch status {
        case .new: return .orange
        case .inReview: return .blue
        case .reviewed: return .teal
        case .onHold: return .gray
        case .done: return .purple
        case .closed: return .red
        }
    }

    @ViewBuilder
    private func issueStatusBadge(for review: WorkItem) -> some View {
        let status = resolveIssueStatus(
            manual: review.manualIssueStatus,
            prState: review.prState,
            claudeReviewedAt: review.claudeReviewedAt,
            claudeWorking: model.claudeStatuses[review.id] == .working
        )
        StateBadge(text: status.displayName, color: issueStatusColor(status))
    }
}

private struct LabelSheet: View {
    let item: WorkItem
    let onSave: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Label")
                .font(.headline)
            Text(item.number.map { "#\($0) · \(item.title)" } ?? item.title)
                .font(.callout).foregroundStyle(.secondary)
                .lineLimit(2).frame(width: 380, alignment: .leading)
            TextField("what this item is about", text: $text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 380)
                .focused($focused)
                .onSubmit { save() }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .onAppear {
            text = item.label ?? ""
            focused = true
        }
    }

    private func save() {
        onSave(text)
        dismiss()
    }
}

private enum SidebarSectionKind {
    case myWork
    case reviewRequests
    case issues
}

private struct SectionStyle {
    let band: Color
    let border: Color
    let text: Color

    static func myWork(_ scheme: ColorScheme) -> SectionStyle {
        scheme == .dark
            ? SectionStyle(
                band: Color(red: 0.165, green: 0.208, blue: 0.314),
                border: Color(red: 0.424, green: 0.549, blue: 1.0),
                text: Color(red: 0.616, green: 0.706, blue: 1.0)
            )
            : SectionStyle(
                band: Color(red: 0.910, green: 0.933, blue: 1.0),
                border: Color(red: 0.275, green: 0.431, blue: 0.941),
                text: Color(red: 0.157, green: 0.275, blue: 0.667)
            )
    }

    static func reviewRequests(_ scheme: ColorScheme) -> SectionStyle {
        scheme == .dark
            ? SectionStyle(
                band: Color(red: 0.227, green: 0.165, blue: 0.314),
                border: Color(red: 0.690, green: 0.424, blue: 1.0),
                text: Color(red: 0.831, green: 0.627, blue: 1.0)
            )
            : SectionStyle(
                band: Color(red: 0.957, green: 0.925, blue: 1.0),
                border: Color(red: 0.588, green: 0.314, blue: 0.902),
                text: Color(red: 0.431, green: 0.176, blue: 0.667)
            )
    }

    static func issues(_ scheme: ColorScheme) -> SectionStyle {
        scheme == .dark
            ? SectionStyle(
                band: Color(red: 0.149, green: 0.247, blue: 0.243),
                border: Color(red: 0.298, green: 0.686, blue: 0.620),
                text: Color(red: 0.486, green: 0.831, blue: 0.769)
            )
            : SectionStyle(
                band: Color(red: 0.890, green: 0.965, blue: 0.953),
                border: Color(red: 0.118, green: 0.533, blue: 0.451),
                text: Color(red: 0.063, green: 0.396, blue: 0.333)
            )
    }
}

private struct SidebarSectionHeader: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let count: Int
    let kind: SidebarSectionKind

    private var style: SectionStyle {
        switch kind {
        case .myWork: return .myWork(colorScheme)
        case .reviewRequests: return .reviewRequests(colorScheme)
        case .issues: return .issues(colorScheme)
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 13, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(style.text)
            Spacer()
            Text("\(count)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(style.text.opacity(0.75))
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.band)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(style.border)
                .frame(width: 3)
        }
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 2, trailing: 8))
        .textCase(nil)
    }
}

private struct StateBadge: View {
    @Environment(\.colorScheme) private var colorScheme
    let text: String
    let color: Color

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 12, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(color)
            .brightness(colorScheme == .dark ? 0.12 : 0)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(colorScheme == .dark ? 0.30 : 0.18))
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
        case .awaitingInput:
            return Color(red: 0.95, green: 0.61, blue: 0.07)
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
    case .awaitingInput(let since, let snippet):
        let elapsed = Int(Date().timeIntervalSince(since))
        let mins = max(elapsed / 60, 0)
        let base = mins > 0 ? "Awaiting input \(mins)m" : "Awaiting input"
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
