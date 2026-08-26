import Foundation
import PRPilotModels

/// codex, the third agent.
///
/// codex differs from Claude Code and pi in two ways that reach beyond its own file:
///
/// 1. It does not key transcripts by working directory. Every session of every project goes
///    into `~/.codex/sessions/YYYY/MM/DD`, and the working directory is recorded inside the
///    file. So membership is a file read, not a directory name.
/// 2. It has no `--session-id`. codex names the session, and PR Pilot learns the name from
///    the transcript the watcher attaches to.
///
/// codex also refuses to start outside a git repository, and outside a directory its own
/// `~/.codex/config.toml` marks as trusted. Managed worktrees are real git worktrees, so the
/// repository check passes, but a machine with no `[projects."…"] trust_level = "trusted"`
/// entry covering the worktree root fails at launch with a message on the terminal.
public struct CodexBackend: AgentBackend {
    public let kind: AgentKind = .codex

    /// codex is a node script with an `env node` shebang, installed under nvm, exactly like
    /// pi. Prepending its own bin directory supplies the sibling `node`.
    ///
    /// Defensive rather than always required. A machine whose `.zprofile` exports the
    /// version-manager PATH already gives a login shell `node`, and this machine's does. A
    /// machine that sets it only in `.zshrc` does not, and there codex exits 127 without
    /// drawing anything. This also pins the `node` beside the exact binary that was resolved,
    /// rather than whatever `nvm alias default` says later.
    public let prependsExecutableDirectoryToPath = true

    /// codex has no `--session-id` flag. It names the session itself.
    public let acceptsAssignedSessionID = false

    /// Injected so the day-directory arithmetic is testable. Production uses the real clock.
    private let now: @Sendable () -> Date

    public init(now: @Sendable @escaping () -> Date = { Date() }) {
        self.now = now
    }

    // MARK: - Transcript location

    /// Today's and yesterday's day directory.
    ///
    /// A session appends to the file it created, so one that starts at 23:59 keeps writing
    /// into the previous day's directory. Watching both covers that. Dropping a directory
    /// from this list cannot detach a live tail: the watcher's file source holds its own
    /// descriptor, and a rescan that finds no candidate leaves the current file attached.
    public func transcriptDirectories(forWorktreePath path: String) -> [URL] {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/sessions")
        let today = now()
        let yesterday = today.addingTimeInterval(-24 * 60 * 60)
        return [today, yesterday].map { root.appendingPathComponent(Self.dayPath(for: $0)) }
    }

    /// `YYYY/MM/DD` in the local time zone, which is what codex uses to file a rollout.
    static func dayPath(for date: Date) -> String {
        let calendar = Calendar(identifier: .gregorian)
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let year = parts.year ?? 0
        let month = parts.month ?? 0
        let day = parts.day ?? 0
        return String(format: "%04d/%02d/%02d", year, month, day)
    }

    public func sessionID(fromTranscriptFilename name: String) -> String? {
        // codex names transcripts "rollout-<iso-timestamp>-<uuid>.jsonl", e.g.
        // "rollout-2026-08-26T14-08-18-01a03df8-9e0c-7672-908a-546665225b9b.jsonl".
        // The timestamp itself is hyphen-separated, so the session ID cannot be found by
        // splitting on the first hyphen. It is the last five hyphen groups, matched by the
        // 8-4-4-4-12 UUID shape.
        guard name.hasSuffix(".jsonl") else { return nil }
        guard name.hasPrefix("rollout-") else { return nil }
        let stem = String(name.dropFirst("rollout-".count).dropLast(".jsonl".count))
        let parts = stem.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count >= 5 else { return nil }
        let tail = parts.suffix(5).map(String.init)
        guard Self.isUUIDShaped(tail) else { return nil }
        return tail.joined(separator: "-")
    }

    private static func isUUIDShaped(_ groups: [String]) -> Bool {
        let widths = [8, 4, 4, 4, 12]
        guard groups.count == widths.count else { return false }
        for (group, width) in zip(groups, widths) {
            guard group.count == width else { return false }
            guard group.allSatisfy(\.isHexDigit) else { return false }
        }
        return true
    }

    /// Reads the working directory back out of the transcript's own first line.
    ///
    /// codex writes a `session_meta` line before anything else:
    ///   {"type":"session_meta","payload":{"id":"…","cwd":"/path/to/worktree",…}}
    ///
    /// A file with no readable `session_meta` is not claimed. Claiming it would be worse than
    /// ignoring it: `latestSessionID` would resume another project's conversation in this
    /// worktree, and `archiveTranscripts` would archive it.
    public func transcript(at url: URL, belongsToWorktreePath path: String) -> Bool {
        guard let cwd = Self.recordedWorktreePath(at: url) else { return false }
        return Self.canonical(cwd) == Self.canonical(path)
    }

    static func recordedWorktreePath(at url: URL) -> String? {
        guard let line = firstLine(of: url) else { return nil }
        struct Meta: Decodable {
            let type: String?
            let payload: Payload?
            struct Payload: Decodable { let cwd: String? }
        }
        guard let meta = try? JSONDecoder().decode(Meta.self, from: line) else { return nil }
        guard meta.type == "session_meta" else { return nil }
        return meta.payload?.cwd
    }

    /// Reads only as far as the first newline. A rollout grows to megabytes, and this runs on
    /// every rescan, so the whole file must never be loaded.
    private static func firstLine(of url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var buffer = Data()
        let chunkSize = 4096
        // A session_meta line carries the agent's base instructions, so it is long. 256 KB is
        // far past any observed length and still bounded.
        let limit = 256 * 1024
        while buffer.count < limit {
            guard let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            buffer.append(chunk)
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                return buffer.prefix(upTo: newline)
            }
        }
        return buffer.isEmpty ? nil : buffer
    }

    /// Resolves symlinks and trailing slashes so `/tmp/x` and `/private/tmp/x/` compare equal.
    /// macOS makes this a real difference: `/tmp` is a symlink, and codex records the resolved
    /// path while the caller may hold either form.
    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    // MARK: - Launch

    public func launchArguments(
        settings: Settings,
        review: WorkItem,
        sessionID: String,
        resume: Bool
    ) -> [String] {
        // codex has no `--name`. Nothing here names the session, so the agent's own session
        // list shows the thread name codex derives from the conversation.
        if resume {
            // `resume` is a subcommand, so it must lead the non-option arguments.
            //
            // codex's help documents the picker as the default and an explicit UUID as
            // taking precedence over it, so this should resume directly rather than prompt.
            // That is read from the help text, not demonstrated: driven from a script the
            // command needs a terminal, and given a pty it neither exits nor reveals which
            // of the two it drew. If it does prompt, the pane waits for ever on a keypress —
            // the same failure pi's `--resume` has. Confirming it needs a person in a real
            // pane.
            return ["resume", sessionID]
        }
        let template = review.prRef != nil
            ? settings.codexReviewPromptTemplate
            : (review.issueNumber != nil ? settings.codexIssuePromptTemplate : "")
        let prompt = LaunchPrompt.render(template, for: review, url: review.url)
        // The prompt is codex's positional argument. A blank template launches with no prompt.
        return prompt.isEmpty ? [] : [prompt]
    }

    // MARK: - Handover

    /// codex reports a turn twice: once as an `event_msg` (`agent_message` / `user_message`,
    /// text in `payload.message`) and once as a `response_item` message with a content array.
    /// Only the `event_msg` form is read, so a turn is not carried twice.
    ///
    /// A `user_message` can also be harness plumbing rather than a person — codex's desktop
    /// app injects an `<app-context>` developer block, and a PR Pilot launch prompt is itself
    /// the first user turn. Both are wanted in a handover, so neither is filtered.
    public func conversationEntry(line: Data) -> HandoverEntry? {
        guard let event = try? JSONDecoder().decode(CodexTranscriptLine.self, from: line) else { return nil }
        guard event.type == "event_msg" else { return nil }
        guard let ts = event.timestamp, let date = TranscriptTimestamp.date(from: ts) else { return nil }
        let role: HandoverEntry.Role
        switch event.payload?.type {
        case "agent_message": role = .assistant
        case "user_message": role = .user
        default: return nil
        }
        guard let text = event.payload?.message?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return nil }
        return HandoverEntry(role: role, date: date, text: text)
    }

    // MARK: - Transcript parsing

    public func parse(line: Data, state: inout TranscriptParseState) -> TranscriptEvent? {
        guard let event = try? JSONDecoder().decode(CodexTranscriptLine.self, from: line) else { return nil }
        guard let ts = event.timestamp, let date = TranscriptTimestamp.date(from: ts) else { return nil }

        let payloadType = event.payload?.type
        let snippet = payloadType == "agent_message"
            ? event.payload?.message.map { String($0.prefix(80)) }
            : nil

        // codex ends a turn with its own event rather than a stop reason on the message.
        let turnCompleted = payloadType == "task_complete"

        // Every other line — a user turn, a tool call, a reasoning block — still proves the
        // session is alive, so it moves the status clock. That matches how pi is treated.
        return TranscriptEvent(
            date: date,
            snippet: snippet,
            turnCompleted: turnCompleted,
            // codex has no `Workflow` concept, so this stays false and `state` is untouched.
            workflowPending: false,
            limitMessage: limitMessage(payloadType: payloadType, rateLimits: event.payload?.rateLimits),
            usage: usage(payloadType: payloadType, rateLimits: event.payload?.rateLimits, at: date)
        )
    }

    /// The allowance codex says it has spent.
    ///
    /// Read from the same `token_count` block as the limit, and verified against real sessions:
    /// `{"primary":{"used_percent":9.0,"window_minutes":10080,"resets_at":1786206068}}`.
    /// The primary window is the one that matters — codex reports a secondary window too, but
    /// it is null in every session read here.
    ///
    /// `resets_at` is a Unix timestamp in seconds.
    private func usage(
        payloadType: String?,
        rateLimits: CodexTranscriptLine.Payload.RateLimits?,
        at date: Date
    ) -> AgentUsage? {
        guard payloadType == "token_count" else { return nil }
        guard let window = rateLimits?.primary, let percent = window.usedPercent else { return nil }
        return AgentUsage(
            usedPercent: percent,
            windowMinutes: window.windowMinutes,
            resetsAt: window.resetsAt.map { Date(timeIntervalSince1970: $0) },
            agent: .codex,
            readAt: date
        )
    }

    /// codex names a block in a field, so this needs no phrase list. `LimitStop` exists only
    /// because Anthropic states a Claude limit in prose.
    ///
    /// Unverified against a real block: no local codex session has ever been limited, so
    /// there is no captured fixture with these fields populated. If codex reports a block
    /// some other way, this badge stays silent — the same failure `LimitStop` documents for a
    /// reworded Claude message.
    private func limitMessage(
        payloadType: String?,
        rateLimits: CodexTranscriptLine.Payload.RateLimits?
    ) -> String? {
        guard payloadType == "token_count", let limits = rateLimits else { return nil }
        let blocked = limits.rateLimitReachedType != nil || limits.spendControlReached == true
        guard blocked else { return nil }
        var text = limits.rateLimitReachedType.map { "codex limit reached: \($0)." }
            ?? "codex spend limit reached."
        if let resetsAt = limits.primary?.resetsAt {
            let reset = Date(timeIntervalSince1970: resetsAt)
            text += " Resets at \(Self.resetFormatter.string(from: reset))."
        }
        return text
    }

    private static let resetFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}

/// One line of a codex rollout transcript.
///
/// Every line is `{"timestamp":…,"type":<envelope>,"payload":{"type":<kind>,…}}`. The
/// envelope is `session_meta`, `event_msg`, `response_item`, `turn_context` or `world_state`;
/// the useful discriminator is the payload type inside it.
struct CodexTranscriptLine: Decodable {
    let timestamp: String?
    let type: String?
    let payload: Payload?

    struct Payload: Decodable {
        let type: String?
        /// `agent_message` carries its text here, as a plain string rather than a content
        /// array.
        let message: String?
        let rateLimits: RateLimits?

        struct RateLimits: Decodable {
            let rateLimitReachedType: String?
            let spendControlReached: Bool?
            let primary: Window?

            struct Window: Decodable {
                let usedPercent: Double?
                let windowMinutes: Int?
                let resetsAt: Double?

                enum CodingKeys: String, CodingKey {
                    case usedPercent = "used_percent"
                    case windowMinutes = "window_minutes"
                    case resetsAt = "resets_at"
                }
            }

            enum CodingKeys: String, CodingKey {
                case rateLimitReachedType = "rate_limit_reached_type"
                case spendControlReached = "spend_control_reached"
                case primary
            }
        }

        enum CodingKeys: String, CodingKey {
            case type, message
            case rateLimits = "rate_limits"
        }
    }
}
