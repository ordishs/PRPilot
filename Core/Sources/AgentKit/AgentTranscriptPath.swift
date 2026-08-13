import Foundation
import PRPilotModels

/// Transcript discovery, expressed once for every agent.
///
/// Each backend supplies only two facts — where its transcripts live, and how to read a
/// session ID out of a file name. Everything here is derived from those, so pi's timestamped
/// file names need no special case.
public enum AgentTranscriptPath {
    public static func directoryURL(for kind: AgentKind, worktreePath: String) -> URL {
        AgentBackends.backend(for: kind).transcriptDirectory(forWorktreePath: worktreePath)
    }

    public static func latestSessionID(for kind: AgentKind, worktreePath: String) -> String? {
        latestSessionID(in: directoryURL(for: kind, worktreePath: worktreePath), kind: kind)
    }

    /// Whether a transcript still exists for `sessionID`.
    ///
    /// Used to decide whether resuming is safe: a persisted session whose transcript has been
    /// archived or pruned would exit with "No conversation found", so the caller starts a
    /// fresh session instead.
    ///
    /// This lists the directory and maps names to session IDs rather than building a path.
    /// It cannot build one — pi prefixes a timestamp the caller does not know.
    public static func transcriptExists(for kind: AgentKind, worktreePath: String, sessionID: String) -> Bool {
        let dir = directoryURL(for: kind, worktreePath: worktreePath)
        let backend = AgentBackends.backend(for: kind)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return false
        }
        return names.contains { backend.sessionID(fromTranscriptFilename: $0) == sessionID }
    }

    /// Moves a worktree's session transcripts into an `archived/` subdirectory so they are
    /// no longer discovered by `latestSessionID` (or tailed by the watcher). This forces a
    /// brand-new session — used when clearing a session to start a fresh review, rather than
    /// resuming the old (possibly interrupted) conversation. Transcripts are preserved on
    /// disk under `archived/`, not deleted. Returns the number moved.
    @discardableResult
    public static func archiveTranscripts(for kind: AgentKind, worktreePath: String) -> Int {
        archiveTranscripts(in: directoryURL(for: kind, worktreePath: worktreePath))
    }

    @discardableResult
    public static func archiveTranscripts(in dir: URL) -> Int {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        let jsonl = entries.filter { $0.pathExtension == "jsonl" }
        guard !jsonl.isEmpty else { return 0 }
        let archiveDir = dir.appendingPathComponent("archived", isDirectory: true)
        try? fm.createDirectory(at: archiveDir, withIntermediateDirectories: true)
        var moved = 0
        for url in jsonl {
            let dest = archiveDir.appendingPathComponent(url.lastPathComponent)
            try? fm.removeItem(at: dest)
            if (try? fm.moveItem(at: url, to: dest)) != nil {
                moved += 1
            }
        }
        return moved
    }

    public static func latestSessionID(in dir: URL, kind: AgentKind) -> String? {
        let backend = AgentBackends.backend(for: kind)
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        let transcripts = entries.filter { backend.sessionID(fromTranscriptFilename: $0.lastPathComponent) != nil }
        guard !transcripts.isEmpty else { return nil }
        let withDates: [(URL, Date)] = transcripts.compactMap { url in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            guard let date = values?.contentModificationDate else { return nil }
            return (url, date)
        }
        guard let newest = withDates.max(by: { $0.1 < $1.1 }) else { return nil }
        return backend.sessionID(fromTranscriptFilename: newest.0.lastPathComponent)
    }
}
