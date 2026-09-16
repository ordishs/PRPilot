/// Flat view of one work item's state, built by `AppCore`.
///
/// `AgentStatus` lives in `AgentKit`, which links SwiftTerm. A gateway that renders no
/// terminal must not drag a terminal emulator in behind it, so the caller flattens the
/// status into booleans at the boundary.
public struct GatewayItemFacts: Sendable, Equatable {
    public var id: String
    public var isDisabled: Bool
    public var limitMessage: String?
    public var awaitsMyResponse: Bool
    public var hasVerdict: Bool
    public var hasUnseenAuthorUpdate: Bool
    public var sessionIsLive: Bool
    public var isQueued: Bool

    public init(
        id: String,
        isDisabled: Bool,
        limitMessage: String?,
        awaitsMyResponse: Bool,
        hasVerdict: Bool,
        hasUnseenAuthorUpdate: Bool,
        sessionIsLive: Bool,
        isQueued: Bool
    ) {
        self.id = id
        self.isDisabled = isDisabled
        self.limitMessage = limitMessage
        self.awaitsMyResponse = awaitsMyResponse
        self.hasVerdict = hasVerdict
        self.hasUnseenAuthorUpdate = hasUnseenAuthorUpdate
        self.sessionIsLive = sessionIsLive
        self.isQueued = isQueued
    }
}

public struct GatewayClassification: Sendable, Equatable {
    public var group: GatewayGroupKind
    public var reason: String?
    public var primaryCommand: GatewayCommand?
}

public enum GatewayGrouping {
    /// Total, pure, first match wins. A disabled item has no session to nudge and no review
    /// to read, so it never reaches the attention branches.
    public static func classify(_ facts: GatewayItemFacts) -> GatewayClassification {
        if facts.isDisabled {
            return GatewayClassification(group: .idle, reason: nil, primaryCommand: nil)
        }
        if facts.limitMessage != nil {
            return GatewayClassification(
                group: .needsYou,
                reason: "Agent hit its usage limit",
                primaryCommand: .clearAgentLimit(id: facts.id)
            )
        }
        if facts.awaitsMyResponse {
            return GatewayClassification(
                group: .needsYou,
                reason: "Agent is waiting for you",
                primaryCommand: .clearWaiting(id: facts.id)
            )
        }
        if facts.hasVerdict {
            return GatewayClassification(
                group: .needsYou,
                reason: "Agent finished its review",
                primaryCommand: nil
            )
        }
        if facts.hasUnseenAuthorUpdate {
            return GatewayClassification(
                group: .needsYou,
                reason: "Author pushed new commits",
                primaryCommand: .markAuthorUpdateSeen(id: facts.id)
            )
        }
        if facts.sessionIsLive {
            return GatewayClassification(group: .running, reason: nil, primaryCommand: nil)
        }
        if facts.isQueued {
            return GatewayClassification(group: .queued, reason: nil, primaryCommand: nil)
        }
        return GatewayClassification(group: .idle, reason: nil, primaryCommand: nil)
    }
}
