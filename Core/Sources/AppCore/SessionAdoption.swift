import Foundation

/// Decides when an item should adopt the session id its transcript watcher is tailing.
///
/// The item stores the session id it launched with, and `ensureAgentSession` resumes that id
/// for the rest of the item's life. That is wrong whenever the agent moves to a different
/// transcript: `/clear` inside Claude Code starts a fresh conversation under a new id, and
/// the launched id then names a conversation the user deliberately threw away — or, once it
/// is pruned, nothing at all, so the next open starts the review from scratch.
///
/// Adopting is not free of risk, which is what the guards are for. The watcher tails the
/// newest transcript in a directory, and two items that share a clone share that directory,
/// so the newest file is not always this item's own.
public enum SessionAdoption {
    /// The session id to store, or nil to leave the item alone.
    ///
    /// - Parameters:
    ///   - watched: session id of the transcript the watcher is tailing.
    ///   - stored: session id the item currently holds for this agent.
    ///   - eventDate: timestamp of the transcript line that prompted this check.
    ///   - sessionStartedAt: when this item's agent process started.
    ///   - idsOwnedByOtherItems: session ids other items hold for this agent.
    ///   - transcriptDirectoryIsShared: whether another live session watches the same directory.
    public static func adoptedSessionID(
        watched: String?,
        stored: String?,
        eventDate: Date,
        sessionStartedAt: Date?,
        idsOwnedByOtherItems: Set<String>,
        transcriptDirectoryIsShared: Bool
    ) -> String? {
        guard let watched, !watched.isEmpty else { return nil }
        guard watched != stored else { return nil }
        // Another live session tails the same directory, so the newest file there may be its
        // work rather than ours. Nothing here can tell the two apart, so nothing is adopted.
        guard !transcriptDirectoryIsShared else { return nil }
        // The watcher replays a transcript from the start on attach, so its first events
        // describe an earlier run. Only a line this process could have written proves which
        // file this process writes.
        guard let sessionStartedAt, eventDate >= sessionStartedAt else { return nil }
        // Never take an id another item holds: that would hand one item's conversation to
        // another, and both would then resume the same transcript.
        guard !idsOwnedByOtherItems.contains(watched) else { return nil }
        return watched
    }
}
