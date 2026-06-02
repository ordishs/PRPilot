import Foundation

public enum CIStatus: String, Codable, Sendable, Equatable {
    case passing, failing, pending, none
}

public enum ReviewReadiness: String, Codable, Sendable, Equatable {
    case draft, approved, changesRequested, reviewRequired, none
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
    public var isBehind: Bool
    public var readiness: ReviewReadiness

    public init(ci: CIStatus, isBehind: Bool, readiness: ReviewReadiness) {
        self.ci = ci
        self.isBehind = isBehind
        self.readiness = readiness
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
