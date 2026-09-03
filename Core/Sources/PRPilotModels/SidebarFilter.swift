import Foundation

/// One "this item wants something from you" condition a sidebar row can carry.
///
/// Each case maps to exactly one field of `SidebarItemFacts`, and to one badge or status
/// dot the row already draws. The filter therefore never invents a state the row cannot
/// show, and a row the filter keeps always explains itself.
public struct SignalFilter: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }

    /// The agent finished a turn that the user has not answered — the AGENT badge.
    public static let agent = SignalFilter(rawValue: 1 << 0)
    /// The agent stopped and put a question to the user.
    public static let needsInput = SignalFilter(rawValue: 1 << 1)
    /// The agent is running right now.
    public static let working = SignalFilter(rawValue: 1 << 2)
    /// The PR author did something since the user's last review — the AUTHOR badge.
    public static let author = SignalFilter(rawValue: 1 << 3)
    public static let ciFailing = SignalFilter(rawValue: 1 << 4)
    public static let behind = SignalFilter(rawValue: 1 << 5)
    /// A review worktree holds local edits, so it cannot be fast-forwarded to the PR head.
    public static let dirty = SignalFilter(rawValue: 1 << 6)
    /// The merge has conflicts — the CONFLICT badge.
    public static let conflict = SignalFilter(rawValue: 1 << 7)
    /// Nothing but a click stands between the PR and a merge — the READY badge.
    public static let ready = SignalFilter(rawValue: 1 << 8)

    /// Display order of the filter pills. Also the list the counts are built from.
    public static let ordered: [SignalFilter] = [
        .agent, .needsInput, .working, .author, .ciFailing, .behind, .dirty, .conflict, .ready,
    ]

    public var displayName: String {
        switch self {
        case .agent: return "Agent"
        case .needsInput: return "Needs input"
        case .working: return "Working"
        case .author: return "Author"
        case .ciFailing: return "CI ✗"
        case .behind: return "Rebase"
        case .dirty: return "Dirty"
        case .conflict: return "Conflict"
        case .ready: return "Ready"
        default: return ""
        }
    }

    public var help: String {
        switch self {
        case .agent: return "The agent finished a turn that you have not answered"
        case .needsInput: return "The agent stopped and asked you a question"
        case .working: return "The agent is running right now"
        case .author: return "The PR author pushed or replied since your last review"
        case .ciFailing: return "CI is failing"
        case .behind: return "The branch is behind its base, so it needs a rebase"
        case .dirty: return "This review worktree has local edits, so it was not refreshed to the PR head"
        case .conflict: return "The merge has conflicts that someone must resolve by hand"
        case .ready: return "The PR merges cleanly and passes every branch protection rule"
        default: return ""
        }
    }
}

/// A live, capped resource an item holds. Each one costs disk or memory, so the sidebar
/// shows who holds what and the filter can list them.
public struct ResourceFilter: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let worktree = ResourceFilter(rawValue: 1 << 0)
    public static let session = ResourceFilter(rawValue: 1 << 1)
    public static let web = ResourceFilter(rawValue: 1 << 2)

    public static let ordered: [ResourceFilter] = [.worktree, .session, .web]

    public var displayName: String {
        switch self {
        case .worktree: return "Worktree"
        case .session: return "Session"
        case .web: return "Web"
        default: return ""
        }
    }

    /// SF Symbol drawn in the row's indicator strip.
    public var symbolName: String {
        switch self {
        case .worktree: return "folder.badge.gearshape"
        case .session: return "terminal"
        case .web: return "globe"
        default: return ""
        }
    }

    public var help: String {
        switch self {
        case .worktree: return "A git worktree is checked out on disk for this item"
        case .session: return "An agent session is live for this item"
        case .web: return "A GitHub web view is loaded for this item"
        default: return ""
        }
    }
}

/// Everything the sidebar knows about one item that is not on the item itself.
///
/// The live facts come from `AppModel` and the web view cache. Passing them in keeps this
/// module free of any AgentKit or WebKit dependency, and keeps the match rule testable.
public struct SidebarItemFacts: Sendable, Equatable {
    public var awaitsMyResponse: Bool
    public var needsInput: Bool
    public var isWorking: Bool
    public var hasAuthorUpdate: Bool
    public var ciFailing: Bool
    public var isBehind: Bool
    public var hasConflict: Bool
    public var isReady: Bool
    /// Local edits in a review worktree. Only meaningful where the app never writes: an
    /// editable worktree is the user's own branch, and edits there are the point.
    public var hasLocalChanges: Bool
    public var hasWorktree: Bool
    public var hasSession: Bool
    public var hasWebView: Bool
    /// You approved this PR and nothing has happened since — see `isParkedReview`.
    public var isParked: Bool

    public init(
        awaitsMyResponse: Bool = false,
        needsInput: Bool = false,
        isWorking: Bool = false,
        hasAuthorUpdate: Bool = false,
        ciFailing: Bool = false,
        isBehind: Bool = false,
        hasConflict: Bool = false,
        isReady: Bool = false,
        hasLocalChanges: Bool = false,
        hasWorktree: Bool = false,
        hasSession: Bool = false,
        hasWebView: Bool = false,
        isParked: Bool = false
    ) {
        self.awaitsMyResponse = awaitsMyResponse
        self.needsInput = needsInput
        self.isWorking = isWorking
        self.hasAuthorUpdate = hasAuthorUpdate
        self.ciFailing = ciFailing
        self.isBehind = isBehind
        self.hasConflict = hasConflict
        self.isReady = isReady
        self.hasLocalChanges = hasLocalChanges
        self.hasWorktree = hasWorktree
        self.hasSession = hasSession
        self.hasWebView = hasWebView
        self.isParked = isParked
    }

    public func has(_ signal: SignalFilter) -> Bool {
        switch signal {
        case .agent: return awaitsMyResponse
        case .needsInput: return needsInput
        case .working: return isWorking
        case .author: return hasAuthorUpdate
        case .ciFailing: return ciFailing
        case .behind: return isBehind
        case .dirty: return hasLocalChanges
        case .conflict: return hasConflict
        case .ready: return isReady
        default: return false
        }
    }

    public func has(_ resource: ResourceFilter) -> Bool {
        switch resource {
        case .worktree: return hasWorktree
        case .session: return hasSession
        case .web: return hasWebView
        default: return false
        }
    }

    /// Whether this item wants the user's eye at all, whichever way it asks.
    public var wantsAttention: Bool { awaitsMyResponse || needsInput }
}

/// What the user has switched on in the sidebar filter bar.
///
/// Nothing selected means "show everything", so the bar needs no explicit All pill.
public struct SidebarFilterSelection: Sendable, Equatable {
    public var signals: SignalFilter
    public var resources: ResourceFilter
    /// The one exclusion in the bar. The other pills say what to keep; this one says what
    /// to drop, so it lives apart from both option sets rather than inside either.
    public var hideParked: Bool

    public init(
        signals: SignalFilter = [],
        resources: ResourceFilter = [],
        hideParked: Bool = false
    ) {
        self.signals = signals
        self.resources = resources
        self.hideParked = hideParked
    }

    public var isEmpty: Bool { signals.isEmpty && resources.isEmpty && !hideParked }

    public mutating func toggle(_ signal: SignalFilter) {
        if signals.contains(signal) {
            signals.remove(signal)
        } else {
            signals.insert(signal)
        }
    }

    public mutating func toggle(_ resource: ResourceFilter) {
        if resources.contains(resource) {
            resources.remove(resource)
        } else {
            resources.insert(resource)
        }
    }

    public mutating func clear() {
        signals = []
        resources = []
        hideParked = false
    }
}

/// Whether an item is waiting on somebody other than you.
///
/// You approved the PR, so your part is done, and the author has done nothing since. The
/// PR now sits on a second reviewer or on the author's own merge, and neither is your
/// work. Hiding it clears the list of rows you can do nothing about.
///
/// Your own approval is the test, not the PR's overall `reviewDecision`. A PR that still
/// needs a second reviewer never reads APPROVED overall, and that is exactly the case this
/// serves. `myReviewState` is persisted on the item, so the answer is right at launch,
/// before the first poll, and while offline.
///
/// `hasUnseenAuthorUpdate` is the release. It covers a new head commit, a reply in one of
/// your threads, a thread the author resolved, and a re-review request naming you — the
/// same signal the Author pill reads, so the two can never disagree.
public func isParkedReview(_ item: WorkItem, hasUnseenAuthorUpdate: Bool) -> Bool {
    guard item.prRef != nil else { return false }
    guard item.prState == .open || item.prState == .draft else { return false }
    guard item.myReviewState == .approved else { return false }
    return !hasUnseenAuthorUpdate
}

/// Pure sidebar match predicate.
///
/// Selections inside one group widen the result; the two groups narrow each other. So
/// "Agent + Author" shows items with either signal, and adding "Session" then keeps only
/// those of them that also hold a live session. An empty group imposes no condition.
///
/// Hide parked is an exclusion, so it runs last and it wins. A parked row that a selected
/// signal would otherwise keep stays hidden — that is what asking to hide something means.
public func sidebarItemMatches(
    _ item: WorkItem,
    query: String,
    selection: SidebarFilterSelection,
    facts: SidebarItemFacts
) -> Bool {
    if selection.hideParked, facts.isParked { return false }
    if !selection.signals.isEmpty {
        let anySignal = SignalFilter.ordered.contains { selection.signals.contains($0) && facts.has($0) }
        guard anySignal else { return false }
    }
    if !selection.resources.isEmpty {
        let anyResource = ResourceFilter.ordered.contains { selection.resources.contains($0) && facts.has($0) }
        guard anyResource else { return false }
    }

    let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !q.isEmpty else { return true }
    let numberStr = item.displayNumber.map { "#\($0)" } ?? ""
    let haystacks = [
        item.title,
        "\(item.owner)/\(item.repo)",
        item.author ?? "",
        item.headBranch ?? "",
        item.label ?? "",
        numberStr,
    ]
    return haystacks.contains { $0.lowercased().contains(q) }
}
