import Foundation

/// Which coding agent drives a work item's session.
///
/// This lives in `PRPilotModels` rather than `AgentKit` because `WorkItem` and `Settings`
/// both persist it, and `AgentKit` depends on this module rather than the other way round.
public enum AgentKind: String, Codable, Sendable, CaseIterable {
    case claudeCode
    case pi
    case codex

    public var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .pi: return "pi"
        case .codex: return "Codex"
        }
    }

    /// Name looked up on the login PATH when the user has set no explicit path.
    public var defaultExecutableName: String {
        switch self {
        case .claudeCode: return "claude"
        case .pi: return "pi"
        case .codex: return "codex"
        }
    }
}
