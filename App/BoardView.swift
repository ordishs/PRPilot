import AppKit
import SwiftUI
import PRPilotModels
import AppCore

enum MainViewMode: String {
    case list
    case board
}

struct MainViewPicker: View {
    @Binding var mode: MainViewMode

    var body: some View {
        Picker("View", selection: $mode) {
            Label("List", systemImage: "list.bullet").tag(MainViewMode.list)
            Label("Board", systemImage: "rectangle.split.3x1").tag(MainViewMode.board)
        }
        .pickerStyle(.segmented)
        .help("Switch between the list and the kanban board")
    }
}

struct BoardView: View {
    @Bindable var model: AppModel
    let webViewCache: WebViewCache
    @Binding var viewMode: MainViewMode
    @State private var searchText = ""
    @AppStorage("boardColumnWidths") private var storedWidths = ""

    private static let minColumnWidth: CGFloat = 150
    private static let maxColumnWidth: CGFloat = 700
    private static let spacing: CGFloat = 12

    private var widths: [String: Double] {
        (try? JSONDecoder().decode([String: Double].self, from: Data(storedWidths.utf8))) ?? [:]
    }

    private func setWidth(_ width: CGFloat?, for column: BoardColumn) {
        var updated = widths
        updated[column.rawValue] = width.map { Double(min(max($0, Self.minColumnWidth), Self.maxColumnWidth)) }
        if let data = try? JSONEncoder().encode(updated), let text = String(data: data, encoding: .utf8) {
            storedWidths = text
        }
    }

    /// A column the user has not resized shares the window's width with the other such columns.
    private func width(for column: BoardColumn, available: CGFloat) -> CGFloat {
        if let stored = widths[column.rawValue] { return CGFloat(stored) }
        let count = CGFloat(BoardColumn.allCases.count)
        let fitted = (available - Self.spacing * (count + 1)) / count
        return max(190, fitted)
    }

    private func activity(_ item: WorkItem) -> Date {
        model.lastActivity(for: item)
    }

    var body: some View {
        let inputs = Dictionary(model.reviews.map { ($0.id, model.boardInput(for: $0)) }, uniquingKeysWith: { first, _ in first })
        let visible = model.reviews.filter {
            sidebarItemMatches($0, query: searchText, selection: SidebarFilterSelection(), facts: inputs[$0.id]?.facts ?? SidebarItemFacts())
        }
        let grouped = boardColumns(items: visible) { inputs[$0.id] ?? BoardInput(item: $0, myLogin: model.currentLogin) }
        GeometryReader { geometry in
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: Self.spacing) {
                    ForEach(BoardColumn.allCases, id: \.rawValue) { column in
                        let cards = (grouped[column] ?? []).sorted { activity($0) > activity($1) }
                        BoardColumnView(
                            column: column,
                            count: cards.count,
                            width: width(for: column, available: geometry.size.width),
                            onResize: { setWidth($0, for: column) },
                            onReset: { setWidth(nil, for: column) }
                        ) {
                            ForEach(cards) { item in
                                BoardCard(
                                    model: model,
                                    input: inputs[item.id] ?? BoardInput(item: item, myLogin: model.currentLogin),
                                    activity: activity(item)
                                )
                                .onTapGesture(count: 2) { open(item) }
                                .onTapGesture { preview(item) }
                            }
                        }
                    }
                }
                .padding(Self.spacing)
                .frame(minWidth: geometry.size.width, minHeight: geometry.size.height, alignment: .top)
            }
        }
        .searchable(text: $searchText, prompt: "Search")
        .navigationTitle("Board")
        .toolbar {
            ToolbarItem { MainViewPicker(mode: $viewMode) }
            ToolbarItem {
                Button {
                    Task { await model.refreshAllNow() }
                } label: {
                    Label("Refresh All", systemImage: "arrow.clockwise")
                }
                .help("Run discovery again and refresh every open item (⇧⌘R)")
            }
        }
    }

    private func open(_ item: WorkItem) {
        model.selection = item.id
        viewMode = .list
    }

    private func preview(_ item: WorkItem) {
        model.selection = item.id
        BoardPreviewPanel.shared.show(
            model: model,
            webViewCache: webViewCache,
            review: item,
            onOpenInList: { open(item) }
        )
    }
}

@MainActor
private final class BoardPreviewPanel {
    static let shared = BoardPreviewPanel()

    private var panel: NSPanel?

    func show(model: AppModel, webViewCache: WebViewCache, review: WorkItem, onOpenInList: @escaping () -> Void) {
        let content = BoardPreview(
            model: model,
            webViewCache: webViewCache,
            review: review,
            onOpenInList: { [weak self] in
                self?.close()
                onOpenInList()
            },
            onClose: { [weak self] in self?.close() }
        )
        if let panel, let host = panel.contentViewController as? NSHostingController<BoardPreview> {
            host.rootView = content
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let host = NSHostingController(rootView: content)
        let panel = NSPanel(contentViewController: host)
        panel.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        panel.title = "Details"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        panel.setContentSize(NSSize(width: 1100, height: 760))
        panel.minSize = NSSize(width: 700, height: 480)
        if !panel.setFrameUsingName("BoardPreviewPanel") { panel.center() }
        panel.setFrameAutosaveName("BoardPreviewPanel")
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
    }

    func close() {
        panel?.orderOut(nil)
    }
}

private struct BoardPreview: View {
    let model: AppModel
    let webViewCache: WebViewCache
    let review: WorkItem
    let onOpenInList: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(review.displayNumber.map { "#\($0) · \(review.title)" } ?? review.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button("Show in List", action: onOpenInList)
                    .help("Leave the board and select this item in the list")
                Button("Close", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.leading, 78)
            .padding(.trailing, 10)
            .padding(.vertical, 10)
            Divider()
            DetailView(model: model, webViewCache: webViewCache, review: review)
        }
        .frame(minWidth: 700, minHeight: 480)
    }
}

private struct BoardColumnView<Content: View>: View {
    let column: BoardColumn
    let count: Int
    let width: CGFloat
    let onResize: (CGFloat) -> Void
    let onReset: () -> Void
    @ViewBuilder let content: Content
    @State private var widthAtDragStart: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(column.title).font(.system(size: 14, weight: .semibold))
                Text("\(count)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(Capsule())
            }
            .help(column.help)
            .padding(.horizontal, 4)
            ScrollView {
                LazyVStack(spacing: 8) { content }
                    .padding(.bottom, 8)
            }
            .scrollIndicators(.hidden)
        }
        .padding(8)
        .frame(width: width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.secondary.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .trailing) { resizeHandle }
    }

    private var resizeHandle: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 8)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let start = widthAtDragStart ?? width
                        widthAtDragStart = start
                        onResize(start + drag.translation.width)
                    }
                    .onEnded { _ in widthAtDragStart = nil }
            )
            .onTapGesture(count: 2, perform: onReset)
            .help("Drag to resize. Double-click to reset.")
    }
}

private struct BoardCard: View {
    let model: AppModel
    let input: BoardInput
    let activity: Date

    private var item: WorkItem { input.item }
    private var facts: SidebarItemFacts { input.facts }
    private var status: PRStatus? { input.prStatus }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Text(item.displayNumber.map { "#\($0) · \(item.title)" } ?? item.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(3)
                Spacer(minLength: 0)
                StatusDot(status: model.claudeStatuses[item.id])
                    .padding(.top, 4)
            }
            Text("\(item.owner)/\(item.repo) · \(item.author ?? "")")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let closes = item.closingIssueNumber {
                Text("closes #\(closes)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            if let label = item.label {
                HStack(spacing: 3) {
                    Image(systemName: "bookmark.fill").font(.system(size: 9))
                    Text(label).lineLimit(2)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            }
            WrappingHStack(spacing: 4, lineSpacing: 4) { badges }
            Text(sidebarDateLabel(for: activity))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(facts.wantsAttention ? Color.orange.opacity(0.8) : Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .opacity(item.disabled ? 0.5 : 1)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var badges: some View {
        if facts.needsInput {
            StateBadge(text: "Input", color: .orange, help: "The agent stopped and asked you a question")
        }
        if facts.awaitsMyResponse {
            StateBadge(text: "Agent", color: .yellow, help: "The agent finished a turn that you have not answered")
        }
        if let update = model.unseenReviewerUpdate(item) {
            ReviewerUpdateBadge(update: update)
        }
        if facts.hasAuthorUpdate {
            StateBadge(text: "Author", color: .teal, help: "The author pushed or replied since your last review")
        }
        if item.prState == .draft {
            StateBadge(text: "Draft", color: .gray, help: "The PR is still a draft")
        }
        if let status {
            switch status.ci {
            case .failing: StateBadge(text: "✗ CI", color: .red, help: "CI is failing")
            case .pending: StateBadge(text: "◷ CI", color: .orange, help: "CI is still running")
            case .passing: StateBadge(text: "✓ CI", color: .green, help: "CI is passing")
            case .none: EmptyView()
            }
            if status.mergeState == .conflict {
                StateBadge(text: "Conflict", color: .red, help: "The merge has conflicts")
            }
            if status.isBehind {
                StateBadge(text: "Rebase", color: .orange, help: "The branch is behind its base")
            }
            if status.readiness == .changesRequested {
                ChangeRequestBadge(
                    changeRequests: status.changeRequests,
                    isOnMyPR: item.category(myLogin: model.currentLogin) != .reviewRequest
                )
            }
            if status.approvalCount > 0 {
                StateBadge(text: "\(status.approvalCount) ✓", color: .green, help: "Approvals on this PR")
            }
            if status.isReadyToMerge(prState: item.prState) {
                StateBadge(text: "Ready", color: .green, help: "Nothing but a click stands between this PR and a merge")
            }
        }
    }
}

/// A reviewer acted on your own PR since you last pushed or replied. Shared by the list and
/// the board, so the two always say the same thing.
struct ReviewerUpdateBadge: View {
    let update: ReviewerUpdate
    var extraHelp = ""

    var body: some View {
        StateBadge(
            text: update.requestedChanges ? "Changes asked" : "Reply",
            color: update.requestedChanges ? .red : .blue,
            help: "A reviewer \(update.requestedChanges ? "asked for changes" : "replied") since you last pushed or replied.\(extraHelp)"
        )
    }
}

/// GitHub says changes are requested. On your own PR, when every request predates your latest
/// push, the ball is with the reviewer, so the badge says so instead of alarming.
struct ChangeRequestBadge: View {
    let changeRequests: ChangeRequestTally
    let isOnMyPR: Bool

    var body: some View {
        if changeRequests.isOutdatedOnly, isOnMyPR {
            StateBadge(
                text: "Re-review",
                color: .orange,
                help: "A reviewer asked for changes on an older commit. You have pushed since, "
                    + "so it waits for them to look again."
            )
        } else {
            StateBadge(text: "changes", color: .red, help: "A reviewer requested changes")
        }
    }
}
