import Foundation

public struct WorkItem: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public var title: String
    public var repoKey: String
    public var baseBranch: String
    public var headBranch: String?
    public var worktreePath: String?
    public var prRef: PRRef?
    public var prState: PRState?
    public var issueRef: IssueRef?
    public var origin: ReviewOrigin
    public var closingIssueNumber: Int?
    public var notes: String?
    /// Extra arguments for this item's session, whichever agent runs it. The stored key is
    /// still `claudeFlags` because it shipped that way.
    public var agentFlags: [String]?
    /// Claude Code's session for this item. pi keeps its own in `piSessionID`, so switching an
    /// item between agents resumes each conversation instead of destroying one.
    public var claudeSessionID: String?
    public var piSessionID: String?
    /// Agent this item uses. Nil means follow `Settings.defaultAgent`, so changing the global
    /// default moves every item that has made no choice of its own.
    public var agent: AgentKind?
    public var autoReview: Bool
    public var addedAt: Date
    public var lastOpenedAt: Date?
    public var disabled: Bool
    public var viewedFiles: [String]
    public var claudeReviewedAt: Date?
    public var approvedByMe: Bool
    public var manualIssueStatus: IssueWorkStatus?
    /// Short user-authored reminder of what this item is about.
    public var label: String?
    /// Detail pane this item was last viewed in, so selection is restored on return.
    public var lastPane: PaneSelection?
    /// Author activity the user has dismissed by hand, so the "Updated" chip stays off
    /// until the author does something newer.
    public var authorUpdateSeenAt: Date?
    /// What the user has posted on this PR, from the last poll. Persisted so the sidebar
    /// badge is right at launch, before the first refresh, and while offline.
    public var myReviewState: MyReviewState?
    /// When the user last submitted a review of any kind.
    public var myLastReviewAt: Date?
    /// When Claude last completed a turn. Unlike `claudeReviewedAt`, which is stamped once
    /// and then frozen, this updates every time, so the Waiting chip can return after the
    /// user responds and Claude runs again.
    public var claudeLastCompletedAt: Date?
    /// Claude output the user has waved off by hand, so the Waiting chip stays off until
    /// Claude completes a newer turn. Kept apart from `myLastReviewAt`, which every poll
    /// overwrites from GitHub.
    public var waitingSeenAt: Date?
    /// When the current agent run began — the launch that started this review or fix.
    /// Only a fresh launch stamps it; a resume keeps the original moment, so the detail
    /// pane reports how long the work has been going rather than when the app last
    /// reattached. Clearing the session clears it.
    public var agentRunStartedAt: Date?
    /// When the agent last stopped because it ran out of allowance. Persisted so the badge
    /// survives an eviction, a quit, and the cap reclaiming the slot — the moments when the
    /// live status is gone but the user still needs to know why the work stopped.
    public var agentLimitedAt: Date?
    /// What the agent said when it hit the limit, verbatim, so the tooltip can tell a spend
    /// limit apart from a five-hour one with a reset time.
    public var agentLimitMessage: String?

    enum CodingKeys: String, CodingKey {
        case id, title, repoKey, baseBranch, headBranch, worktreePath, prRef, prState, issueRef
        case origin, closingIssueNumber, notes, claudeSessionID, autoReview
        case addedAt, lastOpenedAt, disabled, viewedFiles, claudeReviewedAt, approvedByMe, manualIssueStatus
        case label, lastPane, authorUpdateSeenAt
        case myReviewState, myLastReviewAt, claudeLastCompletedAt, waitingSeenAt
        case agentRunStartedAt
        case agentLimitedAt, agentLimitMessage
        case piSessionID, agent
        /// Renamed in Swift when the session layer stopped being Claude-specific. The stored
        /// key must not change, or existing items lose their configured flags.
        case agentFlags = "claudeFlags"
    }

    /// Agent that will actually run this item, given the global default.
    public func effectiveAgent(default defaultAgent: AgentKind) -> AgentKind {
        agent ?? defaultAgent
    }

    /// Session ID this item holds for `kind`, if any. Each agent has its own slot because
    /// their transcripts are mutually unreadable.
    public func sessionID(for kind: AgentKind) -> String? {
        switch kind {
        case .claudeCode: return claudeSessionID
        case .pi: return piSessionID
        }
    }

    public mutating func setSessionID(_ id: String?, for kind: AgentKind) {
        switch kind {
        case .claudeCode: claudeSessionID = id
        case .pi: piSessionID = id
        }
    }

    private enum LegacyKeys: String, CodingKey {
        case owner, repo, number, url, author
    }

    public init(
        id: String = UUID().uuidString,
        title: String,
        repoKey: String,
        baseBranch: String,
        headBranch: String? = nil,
        worktreePath: String? = nil,
        prRef: PRRef? = nil,
        issueRef: IssueRef? = nil,
        prState: PRState? = nil,
        origin: ReviewOrigin,
        closingIssueNumber: Int? = nil,
        notes: String? = nil,
        agentFlags: [String]? = nil,
        claudeSessionID: String? = nil,
        piSessionID: String? = nil,
        agent: AgentKind? = nil,
        autoReview: Bool = false,
        addedAt: Date,
        lastOpenedAt: Date? = nil,
        disabled: Bool = false,
        viewedFiles: [String] = [],
        claudeReviewedAt: Date? = nil,
        approvedByMe: Bool = false,
        manualIssueStatus: IssueWorkStatus? = nil,
        label: String? = nil,
        lastPane: PaneSelection? = nil,
        authorUpdateSeenAt: Date? = nil,
        waitingSeenAt: Date? = nil,
        agentRunStartedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.repoKey = repoKey
        self.baseBranch = baseBranch
        self.headBranch = headBranch
        self.worktreePath = worktreePath
        self.prRef = prRef
        self.issueRef = issueRef
        self.prState = prState
        self.origin = origin
        self.closingIssueNumber = closingIssueNumber
        self.notes = notes
        self.agentFlags = agentFlags
        self.claudeSessionID = claudeSessionID
        self.piSessionID = piSessionID
        self.agent = agent
        self.autoReview = autoReview
        self.addedAt = addedAt
        self.lastOpenedAt = lastOpenedAt
        self.disabled = disabled
        self.viewedFiles = viewedFiles
        self.claudeReviewedAt = claudeReviewedAt
        self.approvedByMe = approvedByMe
        self.manualIssueStatus = manualIssueStatus
        self.label = label
        self.lastPane = lastPane
        self.authorUpdateSeenAt = authorUpdateSeenAt
        self.waitingSeenAt = waitingSeenAt
        self.agentRunStartedAt = agentRunStartedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.title = try c.decode(String.self, forKey: .title)
        self.baseBranch = try c.decode(String.self, forKey: .baseBranch)
        self.headBranch = try c.decodeIfPresent(String.self, forKey: .headBranch)
        self.worktreePath = try c.decodeIfPresent(String.self, forKey: .worktreePath)
        self.issueRef = try c.decodeIfPresent(IssueRef.self, forKey: .issueRef)
        self.origin = try c.decode(ReviewOrigin.self, forKey: .origin)
        self.closingIssueNumber = try c.decodeIfPresent(Int.self, forKey: .closingIssueNumber)
        self.notes = try c.decodeIfPresent(String.self, forKey: .notes)
        self.agentFlags = try c.decodeIfPresent([String].self, forKey: .agentFlags)
        self.claudeSessionID = try c.decodeIfPresent(String.self, forKey: .claudeSessionID)
        self.piSessionID = try c.decodeIfPresent(String.self, forKey: .piSessionID)
        self.agent = try c.decodeIfPresent(AgentKind.self, forKey: .agent)
        self.addedAt = try c.decode(Date.self, forKey: .addedAt)
        self.lastOpenedAt = try c.decodeIfPresent(Date.self, forKey: .lastOpenedAt)
        self.disabled = try c.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
        self.viewedFiles = try c.decodeIfPresent([String].self, forKey: .viewedFiles) ?? []
        self.claudeReviewedAt = try c.decodeIfPresent(Date.self, forKey: .claudeReviewedAt)
        self.approvedByMe = try c.decodeIfPresent(Bool.self, forKey: .approvedByMe) ?? false
        self.manualIssueStatus = try c.decodeIfPresent(IssueWorkStatus.self, forKey: .manualIssueStatus)
        self.label = try c.decodeIfPresent(String.self, forKey: .label)
        self.lastPane = try c.decodeIfPresent(PaneSelection.self, forKey: .lastPane)
        self.authorUpdateSeenAt = try c.decodeIfPresent(Date.self, forKey: .authorUpdateSeenAt)
        self.myReviewState = try c.decodeIfPresent(MyReviewState.self, forKey: .myReviewState)
        self.myLastReviewAt = try c.decodeIfPresent(Date.self, forKey: .myLastReviewAt)
        self.claudeLastCompletedAt = try c.decodeIfPresent(Date.self, forKey: .claudeLastCompletedAt)
        self.waitingSeenAt = try c.decodeIfPresent(Date.self, forKey: .waitingSeenAt)
        self.agentRunStartedAt = try c.decodeIfPresent(Date.self, forKey: .agentRunStartedAt)
        self.agentLimitedAt = try c.decodeIfPresent(Date.self, forKey: .agentLimitedAt)
        self.agentLimitMessage = try c.decodeIfPresent(String.self, forKey: .agentLimitMessage)

        if c.contains(.repoKey) {
            self.id = try c.decode(String.self, forKey: .id)
            self.repoKey = try c.decode(String.self, forKey: .repoKey)
            self.prRef = try c.decodeIfPresent(PRRef.self, forKey: .prRef)
            self.prState = try c.decodeIfPresent(PRState.self, forKey: .prState)
            self.autoReview = try c.decodeIfPresent(Bool.self, forKey: .autoReview) ?? false
        } else {
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            let owner = try legacy.decode(String.self, forKey: .owner)
            let repo = try legacy.decode(String.self, forKey: .repo)
            let number = try legacy.decode(Int.self, forKey: .number)
            let url = try legacy.decode(URL.self, forKey: .url)
            let author = try legacy.decode(String.self, forKey: .author)
            self.id = UUID().uuidString
            self.repoKey = "github.com/\(owner)/\(repo)"
            self.prRef = PRRef(owner: owner, repo: repo, number: number, url: url, authorLogin: author)
            self.prState = try c.decode(PRState.self, forKey: .prState)
            self.autoReview = false
        }
    }

    public func category(myLogin: String?) -> WorkItemCategory {
        if let prRef {
            if let myLogin, prRef.authorLogin.caseInsensitiveCompare(myLogin) == .orderedSame {
                return .myPR
            }
            return .reviewRequest
        }
        if issueRef != nil { return .issue }
        return .task
    }

    public var owner: String { WorkItem.ownerRepo(from: repoKey).owner }
    public var repo: String { WorkItem.ownerRepo(from: repoKey).repo }
    public var number: Int? { prRef?.number }
    public var issueNumber: Int? { issueRef?.number }
    public var displayNumber: Int? { prRef?.number ?? issueRef?.number }
    public var url: URL? { prRef?.url ?? issueRef?.url }
    public var author: String? { prRef?.authorLogin ?? issueRef?.authorLogin }

    public static func slug(_ text: String, maxLength: Int = 40) -> String {
        var out = ""
        var lastDash = false
        for ch in text.lowercased() {
            if ch.isASCII && (ch.isLetter || ch.isNumber) {
                out.append(ch)
                lastDash = false
            } else if !lastDash {
                out.append("-")
                lastDash = true
            }
        }
        let dashes = CharacterSet(charactersIn: "-")
        let trimmed = out.trimmingCharacters(in: dashes)
        guard trimmed.count > maxLength else { return trimmed }
        return String(trimmed.prefix(maxLength)).trimmingCharacters(in: dashes)
    }

    public static func issueBranchName(number: Int, title: String) -> String {
        let s = slug(title)
        return s.isEmpty ? "issue-\(number)" : "issue-\(number)-\(s)"
    }

    static func ownerRepo(from repoKey: String) -> (owner: String, repo: String) {
        let parts = repoKey.split(separator: "/").map(String.init)
        guard parts.count >= 3 else {
            assertionFailure("malformed repoKey: \(repoKey)")
            return ("", "")
        }
        return (parts[parts.count - 2], parts[parts.count - 1])
    }
}
