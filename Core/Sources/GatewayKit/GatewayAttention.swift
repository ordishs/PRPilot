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
    public var hasUnseenAuthorUpdate: Bool

    public init(
        id: String,
        isDisabled: Bool,
        limitMessage: String?,
        awaitsMyResponse: Bool,
        hasUnseenAuthorUpdate: Bool
    ) {
        self.id = id
        self.isDisabled = isDisabled
        self.limitMessage = limitMessage
        self.awaitsMyResponse = awaitsMyResponse
        self.hasUnseenAuthorUpdate = hasUnseenAuthorUpdate
    }
}

public struct GatewayAttention: Sendable, Equatable {
    public var reason: String?
    public var primaryCommand: GatewayCommand?
}

public enum GatewayAttentionRule {
    /// Total, pure, first match wins. A disabled item has no session to nudge and no review
    /// to read, so it never reaches the attention branches.
    ///
    /// Every reason here clears once you act on it. A finished review used to count too,
    /// but `claudeReviewedAt` never clears, so every reviewed item asked for you forever.
    /// The unanswered turn is already the `awaitsMyResponse` branch.
    public static func evaluate(_ facts: GatewayItemFacts) -> GatewayAttention {
        if facts.isDisabled {
            return GatewayAttention(reason: nil, primaryCommand: nil)
        }
        if facts.limitMessage != nil {
            return GatewayAttention(
                reason: "Agent hit its usage limit",
                primaryCommand: .clearAgentLimit(id: facts.id)
            )
        }
        if facts.awaitsMyResponse {
            return GatewayAttention(
                reason: "Agent is waiting for you",
                primaryCommand: .clearWaiting(id: facts.id)
            )
        }
        if facts.hasUnseenAuthorUpdate {
            return GatewayAttention(
                reason: "Author pushed new commits",
                primaryCommand: .markAuthorUpdateSeen(id: facts.id)
            )
        }
        return GatewayAttention(reason: nil, primaryCommand: nil)
    }
}
