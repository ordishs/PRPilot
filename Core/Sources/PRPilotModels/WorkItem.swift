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
    public var claudeFlags: [String]?
    public var claudeSessionID: String?
    public var autoReview: Bool
    public var addedAt: Date
    public var lastOpenedAt: Date?
    public var disabled: Bool
    public var viewedFiles: [String]
    public var claudeReviewedAt: Date?
    public var approvedByMe: Bool
    public var manualIssueStatus: IssueWorkStatus?

    enum CodingKeys: String, CodingKey {
        case id, title, repoKey, baseBranch, headBranch, worktreePath, prRef, prState, issueRef
        case origin, closingIssueNumber, notes, claudeFlags, claudeSessionID, autoReview
        case addedAt, lastOpenedAt, disabled, viewedFiles, claudeReviewedAt, approvedByMe, manualIssueStatus
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
        claudeFlags: [String]? = nil,
        claudeSessionID: String? = nil,
        autoReview: Bool = false,
        addedAt: Date,
        lastOpenedAt: Date? = nil,
        disabled: Bool = false,
        viewedFiles: [String] = [],
        claudeReviewedAt: Date? = nil,
        approvedByMe: Bool = false,
        manualIssueStatus: IssueWorkStatus? = nil
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
        self.claudeFlags = claudeFlags
        self.claudeSessionID = claudeSessionID
        self.autoReview = autoReview
        self.addedAt = addedAt
        self.lastOpenedAt = lastOpenedAt
        self.disabled = disabled
        self.viewedFiles = viewedFiles
        self.claudeReviewedAt = claudeReviewedAt
        self.approvedByMe = approvedByMe
        self.manualIssueStatus = manualIssueStatus
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
        self.claudeFlags = try c.decodeIfPresent([String].self, forKey: .claudeFlags)
        self.claudeSessionID = try c.decodeIfPresent(String.self, forKey: .claudeSessionID)
        self.addedAt = try c.decode(Date.self, forKey: .addedAt)
        self.lastOpenedAt = try c.decodeIfPresent(Date.self, forKey: .lastOpenedAt)
        self.disabled = try c.decodeIfPresent(Bool.self, forKey: .disabled) ?? false
        self.viewedFiles = try c.decodeIfPresent([String].self, forKey: .viewedFiles) ?? []
        self.claudeReviewedAt = try c.decodeIfPresent(Date.self, forKey: .claudeReviewedAt)
        self.approvedByMe = try c.decodeIfPresent(Bool.self, forKey: .approvedByMe) ?? false
        self.manualIssueStatus = try c.decodeIfPresent(IssueWorkStatus.self, forKey: .manualIssueStatus)

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
