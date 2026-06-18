import Foundation

public enum IssueWorkStatus: String, Codable, Sendable, Equatable, CaseIterable {
    case new
    case inReview
    case reviewed
    case onHold
    case done
    case closed

    public var displayName: String {
        switch self {
        case .new: return "New"
        case .inReview: return "In Review"
        case .reviewed: return "Reviewed"
        case .onHold: return "On Hold"
        case .done: return "Done"
        case .closed: return "Closed"
        }
    }
}

/// Resolves the status shown for an issue work item. Precedence: a GitHub-closed
/// issue always shows `.closed`; otherwise a manual override wins; otherwise the
/// status is derived from the Claude session (`.inReview` while working,
/// `.reviewed` once a turn has completed, else `.new`).
public func resolveIssueStatus(
    manual: IssueWorkStatus?,
    prState: PRState?,
    claudeReviewedAt: Date?,
    claudeWorking: Bool
) -> IssueWorkStatus {
    if prState == .closed { return .closed }
    if let manual { return manual }
    if claudeWorking { return .inReview }
    if claudeReviewedAt != nil { return .reviewed }
    return .new
}
