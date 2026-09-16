import Foundation

public enum GatewayGroupKind: String, Codable, Sendable, Hashable, CaseIterable {
    case needsYou
    case running
    case queued
    case idle
}

public enum GatewayItemKind: String, Codable, Sendable, Hashable {
    case pr
    case issue
    case task
}

public enum GatewayBadgeTone: String, Codable, Sendable, Hashable {
    case green
    case orange
    case red
    case blue
    case grey
}

public struct GatewayBadge: Codable, Sendable, Hashable {
    public var text: String
    public var tone: GatewayBadgeTone
    /// The same sentence the Mac badge shows on hover. A five-letter chip cannot say which
    /// actor it is talking about, and the phone has no hover to fall back on.
    public var help: String

    public init(text: String, tone: GatewayBadgeTone, help: String) {
        self.text = text
        self.tone = tone
        self.help = help
    }
}

public struct GatewayAgent: Codable, Sendable, Hashable {
    public var kind: String
    public var status: String
    public var verdict: String?
    public var elapsedSeconds: Int?
    public var usedPercent: Int?

    public init(
        kind: String,
        status: String,
        verdict: String? = nil,
        elapsedSeconds: Int? = nil,
        usedPercent: Int? = nil
    ) {
        self.kind = kind
        self.status = status
        self.verdict = verdict
        self.elapsedSeconds = elapsedSeconds
        self.usedPercent = usedPercent
    }
}

public struct GatewayItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var kind: GatewayItemKind
    public var owner: String?
    public var repo: String?
    public var number: Int?
    public var url: String?
    public var title: String
    public var author: String?
    public var headBranch: String?
    public var baseBranch: String
    public var attentionReason: String?
    public var agent: GatewayAgent?
    public var badges: [GatewayBadge]
    public var issueStatus: String?
    public var label: String?
    public var isDisabled: Bool
    public var ahead: Int
    public var behind: Int
    public var localChanges: Int
    public var lastActivityAt: Date?
    public var primaryCommand: GatewayCommand?

    public init(
        id: String,
        kind: GatewayItemKind,
        owner: String?,
        repo: String?,
        number: Int?,
        url: String?,
        title: String,
        author: String?,
        headBranch: String?,
        baseBranch: String,
        attentionReason: String?,
        agent: GatewayAgent?,
        badges: [GatewayBadge],
        issueStatus: String?,
        label: String?,
        isDisabled: Bool,
        ahead: Int,
        behind: Int,
        localChanges: Int,
        lastActivityAt: Date?,
        primaryCommand: GatewayCommand?
    ) {
        self.id = id
        self.kind = kind
        self.owner = owner
        self.repo = repo
        self.number = number
        self.url = url
        self.title = title
        self.author = author
        self.headBranch = headBranch
        self.baseBranch = baseBranch
        self.attentionReason = attentionReason
        self.agent = agent
        self.badges = badges
        self.issueStatus = issueStatus
        self.label = label
        self.isDisabled = isDisabled
        self.ahead = ahead
        self.behind = behind
        self.localChanges = localChanges
        self.lastActivityAt = lastActivityAt
        self.primaryCommand = primaryCommand
    }
}

public struct GatewayGroup: Codable, Sendable, Equatable {
    public var kind: GatewayGroupKind
    public var items: [GatewayItem]

    public init(kind: GatewayGroupKind, items: [GatewayItem]) {
        self.kind = kind
        self.items = items
    }
}

public struct GatewaySnapshot: Codable, Sendable, Equatable {
    public var generatedAt: Date
    public var gatewayVersion: Int
    public var appVersion: String
    public var login: String?
    public var groups: [GatewayGroup]
    public var warnings: [String]

    public init(
        generatedAt: Date,
        gatewayVersion: Int = GatewayVersion.current,
        appVersion: String,
        login: String?,
        groups: [GatewayGroup],
        warnings: [String]
    ) {
        self.generatedAt = generatedAt
        self.gatewayVersion = gatewayVersion
        self.appVersion = appVersion
        self.login = login
        self.groups = groups
        self.warnings = warnings
    }
}
