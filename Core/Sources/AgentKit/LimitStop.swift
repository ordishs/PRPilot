import Foundation

/// Recognises the turn where the agent stopped because it ran out of allowance.
///
/// A limit stop leaves no trace anywhere else. The process stays alive, it writes no error
/// row, and it never exits, so the only evidence is the assistant message itself. Without
/// this the session simply goes quiet, reads as `.idle`, and the cap later reclaims it —
/// the user never learns the agent was blocked rather than thinking.
///
/// The stop reason alone cannot decide it. Claude Code also answers a resume nudge with
/// `stop_sequence` ("No response requested."), so the text has to separate the two.
///
/// The phrase list is the weak point, and it is deliberately in one place. Anthropic owns
/// this wording and can change it; if they do, the badge stops appearing and the fix is one
/// line here. `LimitStopTests` pins two real lines from a blocked session so a reword shows
/// up as a failing test rather than as silence.
public enum LimitStop {
    private static let phrases = [
        "spend limit",
        "usage limit",
        "rate limit",
        "-hour limit",
        "limit reached",
        "limit will reset",
        "resets at",
    ]

    /// The limit message, verbatim apart from trimming, or nil when this is not a limit stop.
    public static func message(stopReason: String?, text: String?) -> String? {
        guard stopReason == "stop_sequence" else { return nil }
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let haystack = trimmed.lowercased()
        guard phrases.contains(where: { haystack.contains($0) }) else { return nil }
        return trimmed
    }
}
