import Foundation

public enum SidebarFilter: Sendable, Equatable, CaseIterable {
    case all
    case active
    case awaiting
}

/// Pure sidebar match predicate. The caller supplies the live Claude session
/// booleans, so this stays free of any ClaudeSessionKit dependency.
public func sidebarItemMatches(
    _ item: WorkItem,
    query: String,
    filter: SidebarFilter,
    isWorking: Bool,
    isAwaiting: Bool
) -> Bool {
    let matchesFilter: Bool
    switch filter {
    case .all: matchesFilter = true
    case .active: matchesFilter = isWorking || isAwaiting
    case .awaiting: matchesFilter = isAwaiting
    }
    guard matchesFilter else { return false }

    let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !q.isEmpty else { return true }
    let numberStr = item.displayNumber.map { "#\($0)" } ?? ""
    let haystacks = [
        item.title,
        "\(item.owner)/\(item.repo)",
        item.author ?? "",
        item.headBranch ?? "",
        numberStr,
    ]
    return haystacks.contains { $0.lowercased().contains(q) }
}
