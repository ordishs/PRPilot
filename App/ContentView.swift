import AppKit
import SwiftUI
import PRPilotModels
import AppCore
import AgentKit
import CommandSupport

struct ContentView: View {
    @Bindable var model: AppModel
    let webViewCache: WebViewCache
    @State private var showingAdd = false
    @State private var showingAddIssue = false
    @State private var showingNewTask = false
    @State private var labelTarget: WorkItem?
    @State private var discardTarget: WorkItem?
    @State private var searchText = ""
    @State private var filterSelection = SidebarFilterSelection()
    @Environment(\.colorScheme) private var colorScheme

    /// Everything the filter and the row indicators need that is not on the item itself.
    /// Built here because only the view layer can see the live agent sessions and web views.
    private func facts(for review: WorkItem) -> SidebarItemFacts {
        let status = model.claudeStatuses[review.id]
        var needsInput = false
        if case .awaitingInput = status { needsInput = true }
        let prStatus = model.prStatuses[review.id]
        return SidebarItemFacts(
            awaitsMyResponse: review.awaitsMyResponse(myLogin: model.currentLogin),
            needsInput: needsInput,
            isWorking: status == .working,
            hasAuthorUpdate: model.hasUnseenAuthorUpdate(review),
            ciFailing: prStatus?.ci == .failing,
            isBehind: prStatus?.isBehind ?? false,
            hasLocalChanges: (model.worktreeLocalChanges[review.id] ?? 0) > 0,
            hasWorktree: review.worktreePath != nil,
            hasSession: model.claudeSessions[review.id] != nil,
            hasWebView: webViewCache.isLive(review.id),
            isParked: isParkedReview(review, hasUnseenAuthorUpdate: model.hasUnseenAuthorUpdate(review))
        )
    }

    /// The pills the user pressed this launch, plus the one filter that is a stored
    /// preference. Merged here so the match rule still sees one whole selection.
    private var activeSelection: SidebarFilterSelection {
        var selection = filterSelection
        selection.hideParked = model.settings.hideParked
        return selection
    }

    private var filteredReviews: [WorkItem] {
        model.reviews.filter {
            sidebarItemMatches($0, query: searchText, selection: activeSelection, facts: facts(for: $0))
        }
    }

    private func count(_ signal: SignalFilter) -> Int {
        model.reviews.reduce(0) { $0 + (facts(for: $1).has(signal) ? 1 : 0) }
    }

    private func count(_ resource: ResourceFilter) -> Int {
        model.reviews.reduce(0) { $0 + (facts(for: $1).has(resource) ? 1 : 0) }
    }

    private var parkedCount: Int {
        model.reviews.reduce(0) { $0 + (facts(for: $1).isParked ? 1 : 0) }
    }

    private func setHideParked(_ hide: Bool) {
        var updated = model.settings
        updated.hideParked = hide
        Task { await model.updateSettings(updated) }
    }

    private var sidebarHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            searchField
            WrappingHStack(spacing: 4, lineSpacing: 4) {
                ForEach(SignalFilter.ordered, id: \.rawValue) { signal in
                    filterPill(
                        label: signal.displayName,
                        systemImage: nil,
                        count: count(signal),
                        isOn: filterSelection.signals.contains(signal),
                        help: signal.help
                    ) { filterSelection.toggle(signal) }
                }
            }
            WrappingHStack(spacing: 4, lineSpacing: 4) {
                ForEach(ResourceFilter.ordered, id: \.rawValue) { resource in
                    filterPill(
                        label: resource.displayName,
                        systemImage: resource.symbolName,
                        count: count(resource),
                        isOn: filterSelection.resources.contains(resource),
                        help: resource.help
                    ) { filterSelection.toggle(resource) }
                }
                filterPill(
                    label: "Hide parked",
                    systemImage: "eye.slash",
                    count: parkedCount,
                    isOn: model.settings.hideParked,
                    help: "Hide PRs you approved that are now waiting on somebody else. One "
                        + "comes back as soon as the author pushes, replies, or asks you for "
                        + "another review."
                ) { setHideParked(!model.settings.hideParked) }
                if !activeSelection.isEmpty {
                    clearFiltersButton
                }
            }
        }
        .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
    }

    private var searchField: some View {
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
    }

    private var clearFiltersButton: some View {
        Button {
            filterSelection.clear()
            setHideParked(false)
        } label: {
            Text("Clear")
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.secondary.opacity(0.12))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Switch every filter off and show the whole list")
    }

    /// One filter toggle. Nothing switched on means no filtering at all, so the bar needs
    /// no All pill: Clear does that job and only appears when it has something to do.
    @ViewBuilder
    private func filterPill(
        label: String,
        systemImage: String?,
        count: Int,
        isOn: Bool,
        help: String,
        toggle: @escaping () -> Void
    ) -> some View {
        Button(action: toggle) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 10))
                }
                Text(label)
                Text("\(count)").opacity(0.7)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(isOn ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("\(help) · \(count) item\(count == 1 ? "" : "s")")
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
            .confirmationDialog(
                "Discard local changes?",
                isPresented: Binding(get: { discardTarget != nil }, set: { if !$0 { discardTarget = nil } }),
                presenting: discardTarget
            ) { item in
                Button("Discard and Refresh", role: .destructive) {
                    let id = item.id
                    discardTarget = nil
                    Task { await model.discardLocalChanges(id: id) }
                }
                Button("Cancel", role: .cancel) { discardTarget = nil }
            } message: { item in
                let changes = model.worktreeLocalChanges[item.id] ?? 0
                Text(
                    "This throws away \(changes) local change\(changes == 1 ? "" : "s") in the review worktree "
                        + "for \(item.number.map { "#\($0)" } ?? item.title) and fast-forwards it to the PR head. "
                        + "The changes cannot be recovered."
                )
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
                Text(review.number.map { "#\($0) · \(review.title)" } ?? review.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)

                badgeLine(for: review)
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
                footerLine(for: review)
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
            if review.awaitsMyResponse(myLogin: model.currentLogin) {
                Button {
                    Task { await model.clearWaiting(id: review.id) }
                } label: {
                    Label("Clear Agent Badge", systemImage: "clock.badge.checkmark")
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
                    NSPasteboard.general.setString(ShellQuoting.quote(worktreePath), forType: .string)
                }
            } label: {
                Label("Copy Worktree Path", systemImage: "folder")
            }
            .disabled(review.worktreePath == nil)
            if let changes = model.worktreeLocalChanges[review.id], changes > 0 {
                Button(role: .destructive) {
                    discardTarget = review
                } label: {
                    Label("Discard Local Changes & Refresh…", systemImage: "arrow.uturn.backward")
                }
                Divider()
            }
            Button {
                Task { await model.clearAgentSession(for: review.id) }
            } label: {
                Label("Clear Claude Session", systemImage: "xmark.circle")
            }
            .disabled(review.claudeSessionID == nil)
            if review.prRef != nil {
                Button {
                    Task { await model.markAuthorUpdateSeen(id: review.id) }
                } label: {
                    Label("Clear Author Badge", systemImage: "bell.slash")
                }
                .disabled(!model.hasUnseenAuthorUpdate(review))
            }
            Button {
                Task { await model.clearAgentLimit(for: review.id) }
            } label: {
                Label("Clear Limit Badge", systemImage: "creditcard.trianglebadge.exclamationmark")
            }
            .disabled(review.agentLimitedAt == nil)
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

    /// Resource icons plus the item's last-activity stamp. A solid icon means the item holds
    /// that resource right now; a faint one means it does not. Every icon carries a tooltip,
    /// because an icon alone cannot say which agent or which path it stands for.
    @ViewBuilder
    private func footerLine(for review: WorkItem) -> some View {
        let itemFacts = facts(for: review)
        let activity = lastActivityAt(review, authorUpdatedAt: model.prStatuses[review.id]?.authorUpdatedAt)
        HStack(spacing: 6) {
            ForEach(ResourceFilter.ordered, id: \.rawValue) { resource in
                Image(systemName: resource.symbolName)
                    .font(.system(size: 10))
                    .foregroundStyle(itemFacts.has(resource) ? Color.accentColor : Color.secondary.opacity(0.3))
                    .help(resourceTooltip(resource, review: review, present: itemFacts.has(resource)))
            }
            Text(sidebarDateLabel(for: activity))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .help("Last activity: \(sidebarDateTooltip(for: activity))")
        }
    }

    private func agentName(for review: WorkItem) -> String {
        review.effectiveAgent(default: model.settings.defaultAgent).displayName
    }

    private func resourceTooltip(_ resource: ResourceFilter, review: WorkItem, present: Bool) -> String {
        guard present else { return "No \(resource.displayName.lowercased()) for this item" }
        switch resource {
        case .session:
            let agent = review.effectiveAgent(default: model.settings.defaultAgent)
            return "\(agent.displayName) session is live"
        case .worktree:
            return review.worktreePath.map { "Worktree: \($0)" } ?? resource.help
        default:
            return resource.help
        }
    }

    @ViewBuilder
    private func badgeLine(for review: WorkItem) -> some View {
        WrappingHStack(spacing: 4, lineSpacing: 4) {
            if review.category(myLogin: model.currentLogin) == .issue {
                issueStatusBadge(for: review)
            } else {
                switch review.sidebarStatus(myLogin: model.currentLogin) {
                case .merged:
                    StateBadge(text: "Merged", color: .purple, help: "The PR is merged")
                case .closed:
                    StateBadge(text: "Closed", color: .red, help: "The PR is closed without merging")
                case .approved:
                    StateBadge(text: "Approved", color: .green, help: "You approved this PR")
                case .new:
                    StateBadge(text: "New", color: .orange, help: "You have not reviewed this PR yet")
                case .reviewed:
                    StateBadge(text: "Reviewed", color: .blue, help: "You commented or requested changes")
                case .draft:
                    StateBadge(text: "Draft", color: .gray, help: "The PR is still a draft")
                case .open:
                    EmptyView()
                }

                if review.awaitsMyResponse(myLogin: model.currentLogin) {
                    StateBadge(
                        text: "Agent",
                        color: .yellow,
                        help: "\(agentName(for: review)) finished a turn that you have not answered. "
                            + "Clear it from the context menu."
                    )
                }

                if model.queuedReviewIDs.contains(review.id) {
                    StateBadge(text: "Queued", color: .gray, help: "Waiting for a free agent session slot")
                }
            }

            if let status = model.prStatuses[review.id] {
                switch status.ci {
                case .passing: StateBadge(text: "✓ CI", color: .green, help: "CI is passing")
                case .failing: StateBadge(text: "✗ CI", color: .red, help: "CI is failing")
                case .pending: StateBadge(text: "◷ CI", color: .orange, help: "CI is still running")
                case .none: EmptyView()
                }
                if status.isBehind {
                    StateBadge(text: "behind", color: .orange, help: "The branch is behind \(review.baseBranch)")
                }
                if status.readiness == .changesRequested {
                    StateBadge(text: "changes", color: .red, help: "A reviewer requested changes")
                }
                if model.hasUnseenAuthorUpdate(review) {
                    StateBadge(
                        text: "Author",
                        color: .teal,
                        help: "\(review.author ?? "The author") pushed or replied since your last review. "
                            + "Clear it from the context menu."
                    )
                }
            }

            if let message = review.agentLimitMessage {
                StateBadge(
                    text: "Limit",
                    color: .pink,
                    help: "\(agentName(for: review)) stopped: \(message). "
                        + "Clear it from the context menu."
                )
            }

            // Only shown once the allowance is worth watching. Below the threshold the figure
            // is noise, and a row carrying a badge per agent per item would drown the states
            // that need acting on.
            if let usage = model.usageToShow(for: review),
               usage.hasReached(model.settings.usageWarningPercent) {
                StateBadge(
                    text: "\(usage.displayPercent)%",
                    color: usage.displayPercent >= 99 ? .pink : .orange,
                    help: usageHelp(usage, for: review)
                )
            }

            if let changes = model.worktreeLocalChanges[review.id], changes > 0 {
                StateBadge(
                    text: "Dirty",
                    color: .brown,
                    help: "\(changes) local change\(changes == 1 ? "" : "s") in this review worktree, so it was "
                        + "not refreshed to the PR head. Discard them from the context menu."
                )
            }

            if let push = model.pushability[review.id] {
                if push.ahead > 0 {
                    StateBadge(text: "↑\(push.ahead)", color: .green,
                               help: "\(push.ahead) commit(s) to push")
                }
                if push.behind > 0 {
                    StateBadge(text: "↓\(push.behind)", color: .orange,
                               help: "\(push.behind) commit(s) to pull")
                }
            }
        }
    }

    /// Says which agent, how much of which window, and when it resets. All three matter: the
    /// percentage alone does not tell the user whether they have an hour or a week.
    private func usageHelp(_ usage: AgentUsage, for review: WorkItem) -> String {
        var parts = ["\(usage.agent.displayName) has spent \(usage.displayPercent)%"]
        if let window = usage.windowDescription {
            parts[0] += " of its \(window) allowance"
        } else {
            parts[0] += " of its allowance"
        }
        if let resetsAt = usage.resetsAt {
            parts.append("Resets \(resetsAt.formatted(date: .abbreviated, time: .shortened))")
        }
        if model.settings.failoverAgent != review.effectiveAgent(default: model.settings.defaultAgent) {
            parts.append("Hand it to \(model.settings.failoverAgent.displayName) from the agent menu before it stops")
        }
        return parts.joined(separator: ". ") + "."
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
        StateBadge(text: status.displayName, color: issueStatusColor(status),
                   help: "Issue status: \(status.displayName)")
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
    /// Every badge explains itself on hover. A five-letter chip cannot say which actor it
    /// reports, and that is exactly what AGENT and AUTHOR differ on.
    var help: String = ""

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
            .help(help)
    }
}

/// Bridges `StatusDotView` into SwiftUI. The pulse lives in Core Animation, so a working
/// session no longer holds the sidebar in a per-frame render and layout cycle.
private struct PulsingStatusDot: NSViewRepresentable {
    let color: Color
    let isPulsing: Bool

    func makeNSView(context: Context) -> StatusDotView {
        let view = StatusDotView()
        view.dotColor = NSColor(color)
        view.isPulsing = isPulsing
        return view
    }

    func updateNSView(_ view: StatusDotView, context: Context) {
        view.dotColor = NSColor(color)
        view.isPulsing = isPulsing
    }
}

private struct StatusDot: View {
    let status: AgentStatus?

    var body: some View {
        PulsingStatusDot(color: color, isPulsing: isWorking)
            .frame(width: 8, height: 8)
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
        case .limited:
            return .pink
        case .ready(let code):
            return code == 0 ? .green : .orange
        case .failed:
            return .red
        case .starting, nil:
            return .clear
        }
    }
}

private func statusTooltip(_ status: AgentStatus?) -> String {
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
    case .limited(let since, let message):
        let mins = max(Int(Date().timeIntervalSince(since)) / 60, 0)
        return mins > 0 ? "Blocked \(mins)m · \(message)" : "Blocked · \(message)"
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
