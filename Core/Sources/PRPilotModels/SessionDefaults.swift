import Foundation

/// Defaults the session cap and its protection rule share.
///
/// They live here rather than in `AppCore` because `Settings` persists them, and this module
/// cannot depend on `AppCore`.
public enum SessionDefaults {
    /// How long a quiet `.idle` session still counts as mid-turn, in minutes.
    public static let idleProtectionMinutes = 20
}
