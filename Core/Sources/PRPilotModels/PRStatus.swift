import Foundation

public enum CIStatus: String, Codable, Sendable, Equatable {
    case passing, failing, pending, none
}

public enum ReviewReadiness: String, Codable, Sendable, Equatable {
    case draft, approved, changesRequested, reviewRequired, none
}

/// GitHub's `mergeStateStatus`, reduced to the states the sidebar acts on. One value at a
/// time, which is why this replaced a set of booleans: a PR cannot be both behind and
/// conflicted as far as GitHub is concerned.
public enum MergeState: String, Codable, Sendable, Equatable {
    /// Merges cleanly and passes every branch protection rule — GitHub's own merge button
    /// is green.
    case clean
    /// The merge has conflicts. Someone must resolve them by hand.
    case conflict
    /// The head branch is behind its base and the repo requires it to be current.
    case behind
    /// A branch protection rule blocks the merge — a missing review, most often.
    case blocked
    /// A required check is failing or still running, or a merge hook has yet to answer.
    case unstable
    /// Draft PRs, and anything GitHub has not computed yet.
    case unknown
}

/// One review GitHub reports on a pull request, by whoever posted it.
public struct ReviewSubmission: Sendable, Equatable {
    public let authorLogin: String
    public let state: String
    public let submittedAt: Date?

    public init(authorLogin: String, state: String, submittedAt: Date?) {
        self.authorLogin = authorLogin
        self.state = state
        self.submittedAt = submittedAt
    }
}

/// One entry from `gh pr view --json statusCheckRollup`. A CheckRun carries `status`
/// (+ `conclusion` once COMPLETED); a StatusContext carries `state`.
public struct CICheck: Sendable, Equatable {
    public var status: String?
    public var conclusion: String?
    public var state: String?
    public init(status: String? = nil, conclusion: String? = nil, state: String? = nil) {
        self.status = status
        self.conclusion = conclusion
        self.state = state
    }
}

public struct PRStatus: Codable, Sendable, Equatable {
    public var ci: CIStatus
    public var mergeState: MergeState
    public var readiness: ReviewReadiness
    /// How many reviewers approve of the head as it stands. Retracted approvals do not
    /// count — see `approvalCount(from:)`.
    public var approvalCount: Int
    /// Review threads nobody has resolved. Work waiting on the PR author, whether or not
    /// the repository requires resolution before a merge.
    public var unresolvedThreads: Int
    /// Newest thing the PR author did since your last review — nil when they have done
    /// nothing since, or when you have never reviewed the PR. Drives the "Updated" chip.
    public var authorUpdatedAt: Date?

    public var isBehind: Bool { mergeState == .behind }

    public init(
        ci: CIStatus,
        mergeState: MergeState,
        readiness: ReviewReadiness,
        approvalCount: Int = 0,
        unresolvedThreads: Int = 0,
        authorUpdatedAt: Date? = nil
    ) {
        self.ci = ci
        self.mergeState = mergeState
        self.readiness = readiness
        self.approvalCount = approvalCount
        self.unresolvedThreads = unresolvedThreads
        self.authorUpdatedAt = authorUpdatedAt
    }

    /// Tolerates a payload written before `mergeState`, `approvalCount` and
    /// `unresolvedThreads` existed.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ci = try container.decode(CIStatus.self, forKey: .ci)
        mergeState = try container.decodeIfPresent(MergeState.self, forKey: .mergeState) ?? .unknown
        readiness = try container.decode(ReviewReadiness.self, forKey: .readiness)
        approvalCount = try container.decodeIfPresent(Int.self, forKey: .approvalCount) ?? 0
        unresolvedThreads = try container.decodeIfPresent(Int.self, forKey: .unresolvedThreads) ?? 0
        authorUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .authorUpdatedAt)
    }

    /// Whether nothing but a click stands between this PR and a merge. GitHub computes the
    /// whole rule — protection, checks, conflicts — and reports it as CLEAN, so the app
    /// does not second-guess it.
    public func isReadyToMerge(prState: PRState?) -> Bool {
        prState == .open && mergeState == .clean && readiness != .draft
    }

    public static func mergeState(from reported: String?) -> MergeState {
        switch reported?.uppercased() {
        case "CLEAN": return .clean
        case "DIRTY": return .conflict
        case "BEHIND": return .behind
        case "BLOCKED": return .blocked
        case "UNSTABLE", "HAS_HOOKS": return .unstable
        default: return .unknown
        }
    }

    /// Counts the reviewers who currently approve. Each author gets one vote, resolved by
    /// the same rule that decides your own review state, so a dismissed or reversed
    /// approval stops counting.
    ///
    /// - Parameter submissions: every review on the PR, oldest first.
    public static func approvalCount(from submissions: [ReviewSubmission]) -> Int {
        Dictionary(grouping: submissions, by: \.authorLogin)
            .values
            .filter { authorReviews in
                MyReviewState.resolve(
                    from: authorReviews.map { MyReviewSubmission(state: $0.state, submittedAt: $0.submittedAt) }
                ).state == .approved
            }
            .count
    }

    public static func aggregateCI(_ checks: [CICheck]) -> CIStatus {
        var anyChecked = false
        var anyPending = false
        for c in checks {
            if let conclusion = c.conclusion, !conclusion.isEmpty {
                anyChecked = true
                switch conclusion.uppercased() {
                case "FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE", "STALE":
                    return .failing
                default:
                    break
                }
            } else if let status = c.status, !status.isEmpty {
                anyChecked = true
                if status.uppercased() != "COMPLETED" { anyPending = true }
            } else if let state = c.state, !state.isEmpty {
                anyChecked = true
                switch state.uppercased() {
                case "FAILURE", "ERROR":
                    return .failing
                case "PENDING", "EXPECTED":
                    anyPending = true
                default:
                    break
                }
            }
        }
        if !anyChecked { return .none }
        return anyPending ? .pending : .passing
    }

    public static func readiness(isDraft: Bool, reviewDecision: String?) -> ReviewReadiness {
        if isDraft { return .draft }
        switch reviewDecision?.uppercased() {
        case "APPROVED": return .approved
        case "CHANGES_REQUESTED": return .changesRequested
        case "REVIEW_REQUIRED": return .reviewRequired
        default: return .none
        }
    }
}
