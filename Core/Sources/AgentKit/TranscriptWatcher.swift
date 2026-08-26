import Foundation
import PRPilotModels

/// One transcript line, reduced to what drives review status.
public struct TranscriptEvent: Sendable, Equatable {
    public let date: Date
    /// First text block of an assistant message, truncated for display.
    public let snippet: String?
    /// The assistant finished its turn with no background work left — the signal that a review
    /// actually finished. Each backend decides what that looks like in its own schema.
    public let turnCompleted: Bool
    /// A `Workflow` launched from this session has not reported back yet. Claude Code only.
    public let workflowPending: Bool
    /// The agent stopped because it ran out of allowance — see `LimitStop`. Nil on every
    /// other line.
    public let limitMessage: String?
    /// How much allowance the agent says it has spent, when the line reports it. codex only —
    /// see `AgentUsage`.
    public let usage: AgentUsage?

    public init(
        date: Date,
        snippet: String?,
        turnCompleted: Bool,
        workflowPending: Bool,
        limitMessage: String? = nil,
        usage: AgentUsage? = nil
    ) {
        self.date = date
        self.snippet = snippet
        self.turnCompleted = turnCompleted
        self.workflowPending = workflowPending
        self.limitMessage = limitMessage
        self.usage = usage
    }
}

/// Tails the newest transcript in a directory and reports each line as a `TranscriptEvent`.
///
/// The watching, the read-offset bookkeeping and the replay-on-attach behaviour are the same
/// for every agent. What a line *means* is not, so that is delegated to the backend.
@MainActor
public final class TranscriptWatcher {
    private let transcriptDirs: [URL]
    private let worktreePath: String?
    private let backend: any AgentBackend
    private var directorySources: [DispatchSourceFileSystemObject] = []
    /// Whether a transcript belongs to this watcher's worktree, memoised by path.
    ///
    /// Membership is read from the file's first line, which never changes, and a rescan runs
    /// on every write event. Without this cache codex would re-read a `session_meta` line on
    /// every keystroke of every live session.
    private var membershipCache: [String: Bool] = [:]
    private var fileSource: DispatchSourceFileSystemObject?
    private var currentFileURL: URL?
    private var readOffset: Int = 0
    private var onEvent: (@MainActor (TranscriptEvent) -> Void)?
    /// Reports the session id of each transcript this watcher attaches to. The app stores the
    /// id an item launched with, which stops being the truth the moment the agent moves to a
    /// different transcript — `/clear` starts a new conversation under a new id.
    private var onSessionFile: (@MainActor (String) -> Void)?
    /// Per-transcript parser state, for example Claude Code's outstanding workflow count. A
    /// transcript is replayed from the start whenever a file is attached, so this rebuilds on
    /// resume and must reset with the file.
    private var parseState = TranscriptParseState()

    /// - Parameters:
    ///   - transcriptDirs: every directory that could hold this session's transcript. codex
    ///     supplies two, because a session that crosses midnight keeps writing into the day
    ///     directory it started in.
    ///   - worktreePath: the worktree whose transcripts this watcher wants, or nil to accept
    ///     every transcript in the directories. Only codex distinguishes the two: its day
    ///     directory mixes every project, so without this the watcher would tail a stranger's
    ///     session.
    public init(transcriptDirs: [URL], kind: AgentKind, worktreePath: String? = nil) {
        self.transcriptDirs = transcriptDirs
        self.worktreePath = worktreePath
        self.backend = AgentBackends.backend(for: kind)
    }

    public convenience init(transcriptDir: URL, kind: AgentKind, worktreePath: String? = nil) {
        self.init(transcriptDirs: [transcriptDir], kind: kind, worktreePath: worktreePath)
    }

    /// Fires for each transcript line. `turnCompleted` is true when the agent finished its
    /// turn — the signal that a review actually completed, as opposed to merely going idle
    /// after being interrupted.
    ///
    /// Claude Code's `/code-review` hands the review to a background `Workflow` and ends its
    /// turn within seconds, so an end_turn is only reported as a completion once no workflow is
    /// outstanding; until then the event carries `workflowPending`.
    public func start(
        onEvent: @escaping @MainActor (TranscriptEvent) -> Void,
        onSessionFile: (@MainActor (String) -> Void)? = nil
    ) {
        self.onEvent = onEvent
        self.onSessionFile = onSessionFile
        let fm = FileManager.default
        for dir in transcriptDirs where !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        for dir in transcriptDirs {
            attachDirectorySource(dir)
        }
        rescanForLatestTranscript()
    }

    public func stop() {
        for source in directorySources {
            source.cancel()
        }
        directorySources = []
        membershipCache = [:]
        fileSource?.cancel()
        fileSource = nil
        currentFileURL = nil
        readOffset = 0
        parseState = TranscriptParseState()
        onEvent = nil
        onSessionFile = nil
    }

    private func attachDirectorySource(_ dir: URL) {
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.rescanForLatestTranscript() }
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        directorySources.append(source)
    }

    private func rescanForLatestTranscript() {
        let fm = FileManager.default
        var latestURL: URL?
        var latestMod: Date = .distantPast
        for dir in transcriptDirs {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            // Which names count as transcripts is the backend's call: Claude Code uses
            // "<uuid>.jsonl", pi prefixes a timestamp, codex prefixes "rollout-".
            for name in entries where backend.sessionID(fromTranscriptFilename: name) != nil {
                let url = dir.appendingPathComponent(name)
                guard belongsToWorktree(url) else { continue }
                if let attrs = try? fm.attributesOfItem(atPath: url.path),
                   let mod = attrs[.modificationDate] as? Date,
                   mod > latestMod {
                    latestMod = mod
                    latestURL = url
                }
            }
        }
        // No candidate leaves the current file attached. That is what makes a codex day
        // directory dropping out of the list at midnight harmless: the file source holds its
        // own descriptor and keeps tailing.
        guard let latestURL else { return }
        if currentFileURL?.path == latestURL.path {
            readAppended()
        } else {
            attachFileSource(latestURL)
        }
    }

    /// Whether this file is one of ours, memoised. A file only becomes a candidate once, so
    /// the cache holds one entry per transcript the directories ever contain.
    private func belongsToWorktree(_ url: URL) -> Bool {
        guard let worktreePath else { return true }
        if let cached = membershipCache[url.path] { return cached }
        let belongs = backend.transcript(at: url, belongsToWorktreePath: worktreePath)
        // A negative is cached too. A codex rollout's session_meta line is written before
        // anything else, so a file that does not claim this worktree on its first line never
        // will.
        membershipCache[url.path] = belongs
        return belongs
    }

    private func attachFileSource(_ url: URL) {
        fileSource?.cancel()
        fileSource = nil
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        currentFileURL = url
        readOffset = 0
        parseState = TranscriptParseState()
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.readAppended() }
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        fileSource = source
        if let sessionID = backend.sessionID(fromTranscriptFilename: url.lastPathComponent) {
            onSessionFile?(sessionID)
        }
        readAppended()
    }

    private func readAppended() {
        guard let url = currentFileURL else { return }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: UInt64(readOffset))
        } catch {
            return
        }
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return }
        readOffset += data.count
        guard let text = String(data: data, encoding: .utf8) else { return }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            handleLine(String(line))
        }
    }

    private func handleLine(_ line: String) {
        guard let data = line.data(using: .utf8) else { return }
        guard let event = backend.parse(line: data, state: &parseState) else { return }
        onEvent?(event)
    }
}
