import Foundation

/// One review the current user submitted, as GitHub reports it.
public struct MyReviewSubmission: Sendable, Equatable {
    public let state: String
    public let submittedAt: Date?

    public init(state: String, submittedAt: Date?) {
        self.state = state
        self.submittedAt = submittedAt
    }
}

/// What the current user has posted on a pull request. Drives the sidebar lifecycle badge.
public enum MyReviewState: String, Codable, Sendable, Equatable {
    case none
    case commented
    case changesRequested
    case approved

    private static let decisiveStates = ["APPROVED", "CHANGES_REQUESTED", "DISMISSED"]
    private static let countedStates = ["APPROVED", "CHANGES_REQUESTED", "DISMISSED", "COMMENTED"]

    /// - Parameter submissions: the user's own reviews, oldest first.
    /// - Returns: the resolved state, and when the user last posted anything.
    public static func resolve(
        from submissions: [MyReviewSubmission]
    ) -> (state: MyReviewState, lastSubmittedAt: Date?) {
        let counted = submissions.filter { countedStates.contains($0.state) }
        let lastSubmittedAt = counted.compactMap(\.submittedAt).max()

        // Mirrors the filter that has always produced approvedByMe, so that value cannot
        // drift. A DISMISSED review is the dismissed review itself, not a separate event,
        // so it must not fall back to whatever it replaced.
        guard let decisive = submissions.last(where: { decisiveStates.contains($0.state) }) else {
            return (counted.isEmpty ? .none : .commented, lastSubmittedAt)
        }

        switch decisive.state {
        case "APPROVED":
            return (.approved, lastSubmittedAt)
        case "CHANGES_REQUESTED":
            return (.changesRequested, lastSubmittedAt)
        default:
            return (.commented, lastSubmittedAt)
        }
    }
}
