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
}
