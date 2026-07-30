import Foundation

/// Which detail pane an item was last viewed in, remembered per work item.
public enum PaneSelection: String, Codable, Sendable, CaseIterable {
    case claude
    case github

    public var displayName: String {
        switch self {
        case .claude: return "Claude Review"
        case .github: return "GitHub"
        }
    }
}

/// Pure rule for which pane to show when an item becomes the selection.
/// A disabled item has no Claude pane to offer, so it is pinned to GitHub and
/// its remembered choice is left untouched for when it is re-enabled. Otherwise
/// the pane it was last viewed in wins, and a first visit falls back to the type
/// default: PRs and issues have a web page → GitHub; freeform tasks have none →
/// Claude.
public func resolvedPane(for item: WorkItem) -> PaneSelection {
    if item.disabled { return .github }
    if let remembered = item.lastPane { return remembered }
    return (item.prRef == nil && item.issueRef == nil) ? .claude : .github
}
