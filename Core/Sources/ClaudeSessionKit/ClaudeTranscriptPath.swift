import Foundation

public enum ClaudeTranscriptPath {
    public static func directoryURL(forWorktreePath path: String) -> URL {
        // Claude Code derives the transcript folder name from the working directory by
        // replacing every character that is not ASCII-alphanumeric or '-' with '-'.
        // This must match exactly — e.g. "/Users/me/Application Support/x" must encode to
        // "-Users-me-Application-Support-x" (space -> '-') and "masa.gi" to "masa-gi"
        // ('.' -> '-'). If it doesn't, the transcript watcher tails the wrong (empty)
        // directory, status stays .starting, and review state never updates.
        let encoded = String(path.map { Self.encodedCharacters.contains($0) ? $0 : "-" })
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        return homeDir.appendingPathComponent(".claude/projects/\(encoded)")
    }

    private static let encodedCharacters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-")

    public static func latestSessionID(forWorktreePath path: String) -> String? {
        latestSessionID(in: directoryURL(forWorktreePath: path))
    }

    /// Moves a worktree's session transcripts into an `archived/` subdirectory so they are
    /// no longer discovered by `latestSessionID` (or tailed by the watcher). This forces a
    /// brand-new Claude session — used when clearing a session to start a fresh review,
    /// rather than resuming the old (possibly interrupted) conversation. Transcripts are
    /// preserved on disk under `archived/`, not deleted. Returns the number moved.
    @discardableResult
    public static func archiveTranscripts(forWorktreePath path: String) -> Int {
        archiveTranscripts(in: directoryURL(forWorktreePath: path))
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

    public static func latestSessionID(in dir: URL) -> String? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        let jsonl = entries.filter { $0.pathExtension == "jsonl" }
        guard !jsonl.isEmpty else { return nil }
        let withDates: [(URL, Date)] = jsonl.compactMap { url in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            guard let date = values?.contentModificationDate else { return nil }
            return (url, date)
        }
        guard let newest = withDates.max(by: { $0.1 < $1.1 }) else { return nil }
        return newest.0.deletingPathExtension().lastPathComponent
    }
}
