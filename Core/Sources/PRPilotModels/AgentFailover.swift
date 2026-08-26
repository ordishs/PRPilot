import Foundation

/// What PR Pilot does when an agent stops because it ran out of allowance.
///
/// A usage limit is account-wide, so when one agent blocks, every item running that agent
/// blocks with it. The choice here is only about who presses the button.
public enum AgentFailoverMode: String, Codable, Sendable, CaseIterable {
    /// PR Pilot writes the handover note and switches the item on its own.
    case automatic
    /// PR Pilot offers the switch on the blocked item and waits. The default: a switch hands a
    /// half-finished worktree to an agent with a different sandbox and approval model, and that
    /// is worth a deliberate click the first few times.
    case manual

    public var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        case .manual: return "Manual"
        }
    }
}
