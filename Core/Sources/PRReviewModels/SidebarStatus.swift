public enum SidebarStatus: Sendable, Equatable {
    case merged
    case closed
    case approved
    case new
    case reviewed
    case draft
    case open
}

extension Review {
    /// Single lifecycle tag for the sidebar, chosen by precedence:
    /// merged > closed > approved > new > reviewed > draft > open.
    public var sidebarStatus: SidebarStatus {
        switch prState {
        case .merged: return .merged
        case .closed: return .closed
        case .open, .draft: break  // non-terminal — resolved by the checks below
        }
        if approvedByMe { return .approved }
        if lastOpenedAt == nil { return .new }
        if claudeReviewedAt != nil { return .reviewed }
        if prState == .draft { return .draft }
        return .open
    }
}
