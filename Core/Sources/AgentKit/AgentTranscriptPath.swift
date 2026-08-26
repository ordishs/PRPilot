import Foundation
import PRPilotModels

/// Transcript discovery, expressed once for every agent.
///
/// Each backend supplies three facts — which directories can hold its transcripts for a
/// worktree, how to read a session ID out of a file name, and whether a given file belongs to
/// that worktree. Everything here is derived from those, so pi's timestamped file names and
/// codex's shared date-partitioned tree both need no special case.
public enum AgentTranscriptPath {
    public static func directoryURLs(for kind: AgentKind, worktreePath: String) -> [URL] {
        AgentBackends.backend(for: kind).transcriptDirectories(forWorktreePath: worktreePath)
    }

    /// First candidate directory. Claude Code and pi have exactly one; codex has two, and the
    /// first is the current day.
    public static func directoryURL(for kind: AgentKind, worktreePath: String) -> URL {
        directoryURLs(for: kind, worktreePath: worktreePath)[0]
    }

    public static func latestSessionID(for kind: AgentKind, worktreePath: String) -> String? {
        latestSessionID(for: kind, worktreePath: worktreePath, backend: AgentBackends.backend(for: kind))
    }

    /// `backend` is injectable so a test can scope codex to a temporary directory instead of
    /// the user's real `~/.codex/sessions`.
    static func latestSessionID(
        for kind: AgentKind,
        worktreePath: String,
        backend: any AgentBackend
    ) -> String? {
        let candidates = backend.transcriptDirectories(forWorktreePath: worktreePath)
            .flatMap { transcripts(in: $0, backend: backend, worktreePath: worktreePath) }
        return newest(of: candidates).flatMap { backend.sessionID(fromTranscriptFilename: $0.lastPathComponent) }
    }

    /// Whether a transcript still exists for `sessionID`.
    ///
    /// Used to decide whether resuming is safe: a persisted session whose transcript has been
    /// archived or pruned would exit with "No conversation found", so the caller starts a
    /// fresh session instead.
    ///
    /// This lists the directory and maps names to session IDs rather than building a path.
    /// It cannot build one — pi prefixes a timestamp the caller does not know, and codex
    /// prefixes one too.
    public static func transcriptExists(for kind: AgentKind, worktreePath: String, sessionID: String) -> Bool {
        transcriptExists(
            for: kind,
            worktreePath: worktreePath,
            sessionID: sessionID,
            backend: AgentBackends.backend(for: kind)
        )
    }

    static func transcriptExists(
        for kind: AgentKind,
        worktreePath: String,
        sessionID: String,
        backend: any AgentBackend
    ) -> Bool {
        backend.transcriptDirectories(forWorktreePath: worktreePath).contains { dir in
            transcripts(in: dir, backend: backend, worktreePath: worktreePath).contains { url in
                backend.sessionID(fromTranscriptFilename: url.lastPathComponent) == sessionID
            }
        }
    }

    /// Moves a worktree's session transcripts into an `archived/` subdirectory so they are
    /// no longer discovered by `latestSessionID` (or tailed by the watcher). This forces a
    /// brand-new session — used when clearing a session to start a fresh review, rather than
    /// resuming the old (possibly interrupted) conversation. Transcripts are preserved on
    /// disk under `archived/`, not deleted. Returns the number moved.
    ///
    /// Only this worktree's transcripts move. That filter is not cosmetic: codex keeps every
    /// project's sessions in one day directory, so archiving the directory wholesale would
    /// archive every codex session started that day, across every project.
    @discardableResult
    public static func archiveTranscripts(for kind: AgentKind, worktreePath: String) -> Int {
        archiveTranscripts(for: kind, worktreePath: worktreePath, backend: AgentBackends.backend(for: kind))
    }

    @discardableResult
    static func archiveTranscripts(
        for kind: AgentKind,
        worktreePath: String,
        backend: any AgentBackend
    ) -> Int {
        backend.transcriptDirectories(forWorktreePath: worktreePath).reduce(0) { total, dir in
            total + archive(transcripts(in: dir, backend: backend, worktreePath: worktreePath), into: dir)
        }
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
        return archive(entries.filter { $0.pathExtension == "jsonl" }, into: dir)
    }

    private static func archive(_ urls: [URL], into dir: URL) -> Int {
        guard !urls.isEmpty else { return 0 }
        let fm = FileManager.default
        let archiveDir = dir.appendingPathComponent("archived", isDirectory: true)
        try? fm.createDirectory(at: archiveDir, withIntermediateDirectories: true)
        var moved = 0
        for url in urls {
            let dest = archiveDir.appendingPathComponent(url.lastPathComponent)
            try? fm.removeItem(at: dest)
            if (try? fm.moveItem(at: url, to: dest)) != nil {
                moved += 1
            }
        }
        return moved
    }

    public static func latestSessionID(in dir: URL, kind: AgentKind) -> String? {
        latestSessionID(in: dir, kind: kind, worktreePath: nil, backend: AgentBackends.backend(for: kind))
    }

    static func latestSessionID(
        in dir: URL,
        kind: AgentKind,
        worktreePath: String?,
        backend: any AgentBackend
    ) -> String? {
        let named = transcripts(in: dir, backend: backend, worktreePath: worktreePath)
        return newest(of: named).flatMap { backend.sessionID(fromTranscriptFilename: $0.lastPathComponent) }
    }

    /// Transcript files in one directory that this backend recognises, and — when a worktree
    /// is given — that belong to it.
    ///
    /// `worktreePath` is nil only for the directory-scoped entry points, where the caller has
    /// already chosen the directory and no worktree is in play.
    static func transcripts(
        in dir: URL,
        backend: any AgentBackend,
        worktreePath: String?
    ) -> [URL] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        return entries.filter { url in
            guard backend.sessionID(fromTranscriptFilename: url.lastPathComponent) != nil else { return false }
            guard let worktreePath else { return true }
            return backend.transcript(at: url, belongsToWorktreePath: worktreePath)
        }
    }

    /// Newest by modification time. A file whose date cannot be read is skipped, because an
    /// unordered file cannot be compared against the rest.
    static func newest(of urls: [URL]) -> URL? {
        let withDates: [(URL, Date)] = urls.compactMap { url in
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            guard let date = values?.contentModificationDate else { return nil }
            return (url, date)
        }
        return withDates.max(by: { $0.1 < $1.1 })?.0
    }
}
