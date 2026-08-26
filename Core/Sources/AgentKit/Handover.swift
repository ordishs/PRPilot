import Foundation
import PRPilotModels

/// One turn of a conversation, read back out of a transcript.
///
/// `TranscriptEvent.snippet` cannot serve here. It is truncated to 80 characters for the
/// sidebar, and a handover needs the whole turn.
public struct HandoverEntry: Sendable, Equatable {
    public enum Role: String, Sendable { case user, assistant }

    public let role: Role
    public let date: Date
    public let text: String

    public init(role: Role, date: Date, text: String) {
        self.role = role
        self.date = date
        self.text = text
    }
}

/// The note PR Pilot writes into a worktree when it hands an item from one agent to another.
///
/// A limit stop is the reason this exists: the blocked agent cannot summarise its own work,
/// because summarising costs exactly the allowance it has run out of. So PR Pilot renders the
/// note itself, from the transcript it is already tailing. No model call is involved, which is
/// what makes it work at the moment it is needed.
public enum HandoverNote {
    /// File name inside the worktree. Fixed, so a second handover overwrites the first rather
    /// than littering the branch, and so the user can find it.
    public static let fileName = "HANDOVER.md"

    /// How many turns to carry. The tail is what matters — the note names the transcript so
    /// the receiving agent can read further back itself.
    static let turnLimit = 12
    /// Per-turn cap. One agent turn can run to thousands of words, and a prompt built from a
    /// dozen of those would crowd out the work itself.
    static let charactersPerTurn = 1500

    public static func render(
        item: WorkItem,
        from: AgentKind,
        to: AgentKind,
        reason: String?,
        entries: [HandoverEntry],
        transcriptPath: String?,
        now: Date
    ) -> String {
        var out: [String] = []
        out.append("# Handover: \(from.displayName) → \(to.displayName)")
        out.append("")
        out.append("PR Pilot wrote this note. It is not from \(from.displayName).")
        out.append("")

        out.append("## The work")
        out.append("")
        out.append("- Item: \(item.title)")
        if let number = item.displayNumber {
            out.append("- \(item.prRef != nil ? "Pull request" : "Issue"): #\(number)")
        }
        if let url = item.url {
            out.append("- URL: \(url.absoluteString)")
        }
        out.append("- Repository: \(item.repoKey)")
        out.append("- Branch: \(item.headBranch ?? "(none)")")
        out.append("- Base: \(item.baseBranch)")
        out.append("")

        out.append("## Why the agent changed")
        out.append("")
        if let reason, !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append("\(from.displayName) stopped mid-task:")
            out.append("")
            out.append("> \(reason.trimmingCharacters(in: .whitespacesAndNewlines))")
        } else {
            out.append("\(from.displayName) stopped mid-task and PR Pilot moved the item to \(to.displayName).")
        }
        out.append("")
        out.append("Handed over at \(Self.timestamp.string(from: now)).")
        out.append("")

        out.append("## What to do")
        out.append("")
        out.append("Read the conversation below, work out where \(from.displayName) had reached, and")
        out.append("carry on. Check the working tree first: \(from.displayName) may have left edits,")
        out.append("staged or unstaged, that the conversation does not mention.")
        if let transcriptPath {
            out.append("")
            out.append("The full transcript is at:")
            out.append("")
            out.append("    \(transcriptPath)")
            out.append("")
            out.append("It is JSONL, one event per line. Read it if the summary below is not enough.")
        }
        out.append("")

        out.append("## Conversation so far")
        out.append("")
        let kept = carriedIndices(of: entries)
        if kept.isEmpty {
            out.append("The transcript held no readable turns, so there is nothing to carry over.")
            out.append("Treat the item as a fresh start.")
        } else {
            if entries.count > kept.count {
                out.append("\(kept.count) of \(entries.count) turns. The rest are in the transcript.")
                out.append("")
            }
            var previous: Int?
            for index in kept {
                if let previous, index > previous + 1 {
                    let gap = index - previous - 1
                    out.append("*… \(gap) \(gap == 1 ? "turn" : "turns") omitted …*")
                    out.append("")
                }
                let entry = entries[index]
                let who = entry.role == .user ? "User" : from.displayName
                out.append("### \(who) — \(Self.timestamp.string(from: entry.date))")
                out.append("")
                out.append(truncate(entry.text))
                out.append("")
                previous = index
            }
        }
        return out.joined(separator: "\n")
    }

    /// Which turns to carry, as ascending indices into `entries`.
    ///
    /// The tail alone is not enough, and running this against a real 56-turn transcript is what
    /// showed why: the last twelve turns were all short assistant preambles, with no user turn
    /// among them. A note built from that tells the receiving agent what the previous agent was
    /// saying and nothing about what was asked.
    ///
    /// So the window is the tail, plus two turns that carry intent wherever they sit: the first
    /// user turn, which is the task as originally stated, and the most recent one, which is what
    /// the previous agent was actually working on.
    static func carriedIndices(of entries: [HandoverEntry]) -> [Int] {
        guard !entries.isEmpty else { return [] }
        var kept = Set(entries.indices.suffix(turnLimit))
        let userIndices = entries.indices.filter { entries[$0].role == .user }
        if let first = userIndices.first { kept.insert(first) }
        if let last = userIndices.last { kept.insert(last) }
        return kept.sorted()
    }

    static func truncate(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > charactersPerTurn else { return trimmed }
        return String(trimmed.prefix(charactersPerTurn)) + "\n\n[truncated — see the transcript]"
    }

    /// Reads a transcript and returns the turns a backend can recognise in it.
    public static func entries(inTranscriptAt url: URL, kind: AgentKind) -> [HandoverEntry] {
        let backend = AgentBackends.backend(for: kind)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line in
                guard let data = line.data(using: .utf8) else { return nil }
                return backend.conversationEntry(line: data)
            }
    }

    /// The transcript this item's agent is writing, or nil when none can be found.
    public static func transcriptURL(for kind: AgentKind, worktreePath: String, sessionID: String?) -> URL? {
        let backend = AgentBackends.backend(for: kind)
        let files = backend.transcriptDirectories(forWorktreePath: worktreePath)
            .flatMap { AgentTranscriptPath.transcripts(in: $0, backend: backend, worktreePath: worktreePath) }
        if let sessionID,
           let match = files.first(where: {
               backend.sessionID(fromTranscriptFilename: $0.lastPathComponent) == sessionID
           }) {
            return match
        }
        return AgentTranscriptPath.newest(of: files)
    }

    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
