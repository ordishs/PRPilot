import Foundation

/// Defaults the session cap and its protection rule share.
///
/// They live here rather than in `AppCore` because `Settings` persists them, and this module
/// cannot depend on `AppCore`.
public enum SessionDefaults {
    /// How long a quiet `.idle` session still counts as mid-turn, in minutes.
    public static let idleProtectionMinutes = 20

    /// How long a session blocked on a spend or usage limit is kept, in minutes.
    ///
    /// Long enough to raise the limit and carry on in the same pane. It must still expire:
    /// a blocked agent can do no work, so protecting it forever would let a handful of them
    /// hold every slot and starve the drain queue.
    public static let limitProtectionMinutes = 30

    /// Percentage of an agent's allowance at which PR Pilot warns.
    ///
    /// 90 leaves a real margin: on a weekly window that is most of a day's work, which is
    /// enough to finish the turn in hand, hand the item over, or raise the limit. Lower and
    /// the warning becomes noise; higher and it arrives too late to act on.
    public static let usageWarningPercent = 90
}
