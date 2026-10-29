import Foundation

/// Which detail pane an item was last viewed in, remembered per work item.
public enum PaneSelection: String, Codable, Sendable, CaseIterable {
    case claude
    case github

    /// Raw value stays `claude` because it is persisted in `WorkItem.lastPane`. The label is
    /// resolved against the item's agent instead, so the tab reads "pi Review" when pi drives it.
    public func displayName(for agent: AgentKind) -> String {
        switch self {
        case .claude: return "\(agent.displayName) Review"
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

/// Agents that get a tab beside GitHub: the ones holding a stored session for the item,
/// plus the one running right now, whose session may not be written down yet. Order is
/// the fixed `AgentKind` order so tabs never shuffle between visits. A disabled item has
/// no agent pane, so it has none.
public func agentTabs(for item: WorkItem, defaultAgent: AgentKind, isLive: Bool) -> [AgentKind] {
    guard !item.disabled else { return [] }
    let running = isLive ? item.effectiveAgent(default: defaultAgent) : nil
    return AgentKind.allCases.filter { item.sessionID(for: $0) != nil || $0 == running }
}

/// Agents the "+" menu offers: every one without a tab yet.
public func addableAgents(for item: WorkItem, defaultAgent: AgentKind, isLive: Bool) -> [AgentKind] {
    let present = Set(agentTabs(for: item, defaultAgent: defaultAgent, isLive: isLive))
    return item.disabled ? [] : AgentKind.allCases.filter { !present.contains($0) }
}
