import Foundation

/// One transcript line, reduced to what drives review status.
public struct TranscriptEvent: Sendable, Equatable {
    public let date: Date
    /// First text block of an assistant message, truncated for display.
    public let snippet: String?
    /// The assistant reached `stop_reason == "end_turn"` with no background work left —
    /// the signal that a review actually finished.
    public let turnCompleted: Bool
    /// A `Workflow` launched from this session has not reported back yet.
    public let workflowPending: Bool

    public init(date: Date, snippet: String?, turnCompleted: Bool, workflowPending: Bool) {
        self.date = date
        self.snippet = snippet
        self.turnCompleted = turnCompleted
        self.workflowPending = workflowPending
    }
}

@MainActor
public final class TranscriptWatcher {
    private let transcriptDir: URL
    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var currentFileURL: URL?
    private var readOffset: Int = 0
    private var onEvent: (@MainActor (TranscriptEvent) -> Void)?
    private let isoFormatter: ISO8601DateFormatter
    private let isoFormatterNoFrac: ISO8601DateFormatter
    /// Workflows launched from this session that have not reported back. A transcript is
    /// replayed from the start whenever a file is attached, so this rebuilds on resume.
    private var pendingWorkflows: Int = 0

    public init(transcriptDir: URL) {
        self.transcriptDir = transcriptDir
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.isoFormatter = fmt
        let fmt2 = ISO8601DateFormatter()
        fmt2.formatOptions = [.withInternetDateTime]
        self.isoFormatterNoFrac = fmt2
    }

    /// Fires for each transcript line. `turnCompleted` is true when an assistant message
    /// finished its turn (`stop_reason == "end_turn"`) — the signal that a review actually
    /// completed, as opposed to merely going idle after being interrupted mid-task.
    ///
    /// `/code-review` hands the review to a background `Workflow` and ends its turn within
    /// seconds, so an end_turn is only reported as a completion once no workflow is
    /// outstanding; until then the event carries `workflowPending`.
    public func start(onEvent: @escaping @MainActor (TranscriptEvent) -> Void) {
        self.onEvent = onEvent
        let fm = FileManager.default
        if !fm.fileExists(atPath: transcriptDir.path) {
            try? fm.createDirectory(at: transcriptDir, withIntermediateDirectories: true)
        }
        attachDirectorySource()
        rescanForLatestJsonl()
    }

    public func stop() {
        directorySource?.cancel()
        directorySource = nil
        fileSource?.cancel()
        fileSource = nil
        currentFileURL = nil
        readOffset = 0
        pendingWorkflows = 0
        onEvent = nil
    }

    private func attachDirectorySource() {
        let fd = open(transcriptDir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.rescanForLatestJsonl() }
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        directorySource = source
    }

    private func rescanForLatestJsonl() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: transcriptDir.path) else { return }
        let jsonls = entries.filter { $0.hasSuffix(".jsonl") }
        var latestURL: URL?
        var latestMod: Date = .distantPast
        for name in jsonls {
            let url = transcriptDir.appendingPathComponent(name)
            if let attrs = try? fm.attributesOfItem(atPath: url.path),
               let mod = attrs[.modificationDate] as? Date,
               mod > latestMod {
                latestMod = mod
                latestURL = url
            }
        }
        guard let latestURL else { return }
        if currentFileURL?.path == latestURL.path {
            readAppended()
        } else {
            attachFileSource(latestURL)
        }
    }

    private func attachFileSource(_ url: URL) {
        fileSource?.cancel()
        fileSource = nil
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        currentFileURL = url
        readOffset = 0
        pendingWorkflows = 0
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
        struct MinimalEvent: Decodable {
            let type: String?
            let timestamp: String?
        }
        guard let event = try? JSONDecoder().decode(MinimalEvent.self, from: data) else { return }
        guard let ts = event.timestamp else { return }
        guard let date = isoFormatter.date(from: ts) ?? isoFormatterNoFrac.date(from: ts) else { return }
        updatePendingWorkflows(from: data, line: line, type: event.type)
        let snippet = extractSnippet(from: data, type: event.type)
        let turnCompleted = isCompletedTurn(from: data, type: event.type) && pendingWorkflows == 0
        onEvent?(
            TranscriptEvent(
                date: date,
                snippet: snippet,
                turnCompleted: turnCompleted,
                workflowPending: pendingWorkflows > 0
            )
        )
    }

    /// Runs before a line is reported, so an end_turn on the same line as a workflow launch
    /// is never mistaken for a completion.
    ///
    /// Three signals, in the order a transcript emits them: the `Workflow` tool call starts
    /// the count; the `turn_duration` system event carries the authoritative
    /// `pendingWorkflowCount` (omitted entirely once nothing is outstanding); and a
    /// `<task-notification>` is one workflow reporting back.
    private func updatePendingWorkflows(from data: Data, line: String, type: String?) {
        switch type {
        case "assistant":
            struct ToolUseEvent: Decodable {
                let message: MessageEnvelope?
                struct MessageEnvelope: Decodable {
                    let content: [ContentBlock]?
                    struct ContentBlock: Decodable {
                        let type: String?
                        let name: String?
                    }
                }
            }
            guard let event = try? JSONDecoder().decode(ToolUseEvent.self, from: data) else { return }
            let launches = event.message?.content?.filter { $0.type == "tool_use" && $0.name == "Workflow" }.count ?? 0
            pendingWorkflows += launches
        case "system":
            struct SystemEvent: Decodable {
                let subtype: String?
                let pendingWorkflowCount: Int?
            }
            guard let event = try? JSONDecoder().decode(SystemEvent.self, from: data) else { return }
            guard event.subtype == "turn_duration" else { return }
            pendingWorkflows = event.pendingWorkflowCount ?? 0
        case "user":
            guard line.contains("<task-notification>") else { return }
            pendingWorkflows = max(0, pendingWorkflows - 1)
        default:
            return
        }
    }

    private func isCompletedTurn(from data: Data, type: String?) -> Bool {
        guard type == "assistant" else { return false }
        struct AssistantStop: Decodable {
            let message: MessageEnvelope?
            struct MessageEnvelope: Decodable {
                let stopReason: String?
                enum CodingKeys: String, CodingKey { case stopReason = "stop_reason" }
            }
        }
        guard let event = try? JSONDecoder().decode(AssistantStop.self, from: data) else { return false }
        return event.message?.stopReason == "end_turn"
    }

    private func extractSnippet(from data: Data, type: String?) -> String? {
        guard type == "assistant" else { return nil }
        struct AssistantEvent: Decodable {
            let message: MessageEnvelope?
            struct MessageEnvelope: Decodable {
                let content: [ContentBlock]?
                struct ContentBlock: Decodable {
                    let type: String?
                    let text: String?
                }
            }
        }
        guard let event = try? JSONDecoder().decode(AssistantEvent.self, from: data) else { return nil }
        guard let first = event.message?.content?.first(where: { $0.type == "text" }) else { return nil }
        guard let text = first.text else { return nil }
        return String(text.prefix(80))
    }
}
