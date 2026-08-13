import Foundation

/// Makes a string safe to paste into a shell.
///
/// Managed worktrees live under `~/Library/Application Support/PRPilot`, so every worktree
/// path contains a space. Copied raw, `cd <path>` splits into two arguments and fails.
public enum ShellQuoting {
    /// Characters a shell never treats specially, so a string built only from these needs
    /// no quotes.
    private static let safeCharacters = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-/:=@+,"
    )

    /// Returns `value` unchanged when it is already safe, and wrapped in single quotes when
    /// it is not. Single quotes are used because a shell interprets nothing inside them —
    /// double quotes would still expand `$`, a backtick and a backslash. An embedded single
    /// quote closes the run, escapes itself, and reopens: `'\''`.
    public static func quote(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        guard value.contains(where: { !safeCharacters.contains($0) }) else { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
