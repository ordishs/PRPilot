import Foundation

/// How much of an agent's allowance is spent, as the agent itself reports it.
///
/// Only codex publishes this. Every `token_count` event carries a rate-limit block naming the
/// percentage used, the window it applies to and when that window resets. Claude Code says
/// nothing until it is already blocked, which is why `LimitStop` has to match prose — so an
/// item running Claude Code simply has no usage to show.
///
/// The point of reading it is timing. A limit stop is discovered after the work has stopped;
/// this is known before, so the user can finish the turn, hand the item over, or raise the
/// limit while the agent is still running.
public struct AgentUsage: Codable, Sendable, Equatable {
    /// Percentage of the window consumed, 0 to 100 as the agent reports it.
    public var usedPercent: Double
    /// Length of the window this percentage applies to. 10080 minutes is a week; codex also
    /// reports shorter secondary windows.
    public var windowMinutes: Int?
    /// When the window resets, if the agent said.
    public var resetsAt: Date?
    /// The agent that reported it. Usage is per account, not per item, but an item only ever
    /// hears from the agent driving it.
    public var agent: AgentKind
    /// When PR Pilot read this. A percentage with no age is unreadable: an agent that has been
    /// quiet for a day may have had its window reset since.
    public var readAt: Date

    public init(
        usedPercent: Double,
        windowMinutes: Int? = nil,
        resetsAt: Date? = nil,
        agent: AgentKind,
        readAt: Date
    ) {
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
        self.agent = agent
        self.readAt = readAt
    }

    /// Whether the reported figure has reached the warning threshold.
    public func hasReached(_ threshold: Int) -> Bool {
        usedPercent >= Double(threshold)
    }

    /// Rounded for display. Always rounds down, so 99.6% never shows as 100% while the agent
    /// is still working.
    public var displayPercent: Int {
        Int(max(0, min(100, usedPercent)).rounded(.down))
    }

    /// The window, in words, or nil when the agent did not say. Whole hours and whole days
    /// only — codex reports 10080 minutes, and "7 days" reads better than "10080 minutes".
    public var windowDescription: String? {
        guard let windowMinutes, windowMinutes > 0 else { return nil }
        if windowMinutes % (60 * 24) == 0 {
            let days = windowMinutes / (60 * 24)
            return "\(days) day\(days == 1 ? "" : "s")"
        }
        if windowMinutes % 60 == 0 {
            let hours = windowMinutes / 60
            return "\(hours) hour\(hours == 1 ? "" : "s")"
        }
        return "\(windowMinutes) minutes"
    }

    /// Whether this reading is too old to show.
    ///
    /// A stale percentage is worse than none: it invites the user to hand work over on the
    /// strength of a figure whose window has since reset. A reading is dropped once its own
    /// window has passed its reset time, and in any case after `maximumAgeHours`.
    public func isStale(now: Date, maximumAgeHours: Double = 12) -> Bool {
        if let resetsAt, now >= resetsAt { return true }
        return now.timeIntervalSince(readAt) > maximumAgeHours * 3600
    }
}
