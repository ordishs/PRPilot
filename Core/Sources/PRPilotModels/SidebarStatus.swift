import Foundation

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

/// Whether Claude has produced output on a review request that the user has not answered.
///
/// Independent of `resolveSidebarStatus` on purpose: "did I approve this" and "is there
/// output I have not read" are different questions, and a PR can be both approved and
/// waiting. Author activity is not considered here — the "Updated" chip already reports it.
public func isAwaitingMyResponse(
    category: WorkItemCategory,
    prState: PRState?,
    claudeLastCompletedAt: Date?,
    myLastReviewAt: Date?
) -> Bool {
    guard category == .reviewRequest else { return false }
    guard prState != .merged, prState != .closed else { return false }
    guard let claudeLastCompletedAt else { return false }
    guard let myLastReviewAt else { return true }
    return claudeLastCompletedAt > myLastReviewAt
}

extension WorkItem {
    public func sidebarStatus(myLogin: String?) -> SidebarStatus {
        resolveSidebarStatus(
            category: category(myLogin: myLogin),
            prState: prState,
            myReviewState: myReviewState
        )
    }

    /// Named differently from the free function on purpose. `Schema.swift` declares a
    /// `PRPilotModels` enum that shadows the module name, so the usual
    /// `PRPilotModels.isAwaitingMyResponse(...)` disambiguation does not compile here.
    public func awaitsMyResponse(myLogin: String?) -> Bool {
        isAwaitingMyResponse(
            category: category(myLogin: myLogin),
            prState: prState,
            claudeLastCompletedAt: claudeLastCompletedAt,
            myLastReviewAt: myLastReviewAt
        )
    }
}
