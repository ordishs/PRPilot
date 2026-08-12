public enum SidebarStatus: Sendable, Equatable {
    case merged
    case closed
    case approved
    case new
    case reviewed
    case draft
    case open
}

/// Resolves the single lifecycle badge. It answers one question: how far has the user's
/// own review got? Whether Claude has produced unread output is a separate signal —
/// see `isAwaitingMyResponse`.
///
/// `lastOpenedAt` and `claudeReviewedAt` are deliberately absent. Neither describes what
/// the user posted, and keying NEW and REVIEWED on them made the badge report progress
/// the user had not made.
public func resolveSidebarStatus(
    category: WorkItemCategory,
    prState: PRState?,
    myReviewState: MyReviewState?
) -> SidebarStatus {
    switch prState {
    case .merged: return .merged
    case .closed: return .closed
    case .open, .draft, .none: break  // non-terminal — resolved by the checks below
    }

    guard category == .reviewRequest else {
        return prState == .draft ? .draft : .open
    }

    switch myReviewState {
    case .approved: return .approved
    case .commented, .changesRequested: return .reviewed
    case .none, .some(.none): break
    }

    if prState == .draft { return .draft }
    return .new
}

extension WorkItem {
    public func sidebarStatus(myLogin: String?) -> SidebarStatus {
        resolveSidebarStatus(
            category: category(myLogin: myLogin),
            prState: prState,
            myReviewState: myReviewState
        )
    }
}
