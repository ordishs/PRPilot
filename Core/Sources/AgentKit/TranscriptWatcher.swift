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

    public init(date: Date, snippet: String?, turnCompleted: Bool, workflowPending: Bool) {
        self.date = date
        self.snippet = snippet
        self.turnCompleted = turnCompleted
        self.workflowPending = workflowPending
    }
}

/// Tails the newest transcript in a directory and reports each line as a `TranscriptEvent`.
///
/// The watching, the read-offset bookkeeping and the replay-on-attach behaviour are the same
/// for every agent. What a line *means* is not, so that is delegated to the backend.
@MainActor
public final class TranscriptWatcher {
    private let transcriptDir: URL
    private let backend: any AgentBackend
    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var currentFileURL: URL?
    private var readOffset: Int = 0
    private var onEvent: (@MainActor (TranscriptEvent) -> Void)?
    /// Per-transcript parser state, for example Claude Code's outstanding workflow count. A
    /// transcript is replayed from the start whenever a file is attached, so this rebuilds on
    /// resume and must reset with the file.
    private var parseState = TranscriptParseState()

    public init(transcriptDir: URL, kind: AgentKind) {
        self.transcriptDir = transcriptDir
        self.backend = AgentBackends.backend(for: kind)
    }

    /// Fires for each transcript line. `turnCompleted` is true when the agent finished its
    /// turn — the signal that a review actually completed, as opposed to merely going idle
    /// after being interrupted.
    ///
    /// Claude Code's `/code-review` hands the review to a background `Workflow` and ends its
    /// turn within seconds, so an end_turn is only reported as a completion once no workflow is
    /// outstanding; until then the event carries `workflowPending`.
    public func start(onEvent: @escaping @MainActor (TranscriptEvent) -> Void) {
        self.onEvent = onEvent
        let fm = FileManager.default
        if !fm.fileExists(atPath: transcriptDir.path) {
            try? fm.createDirectory(at: transcriptDir, withIntermediateDirectories: true)
        }
        attachDirectorySource()
        rescanForLatestTranscript()
    }

    public func stop() {
        directorySource?.cancel()
        directorySource = nil
        fileSource?.cancel()
        fileSource = nil
        currentFileURL = nil
        readOffset = 0
        parseState = TranscriptParseState()
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
            MainActor.assumeIsolated { self?.rescanForLatestTranscript() }
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        directorySource = source
    }

    private func rescanForLatestTranscript() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: transcriptDir.path) else { return }
        // Which names count as transcripts is the backend's call: Claude Code uses
        // "<uuid>.jsonl", pi prefixes a timestamp.
        let transcripts = entries.filter { backend.sessionID(fromTranscriptFilename: $0) != nil }
        var latestURL: URL?
        var latestMod: Date = .distantPast
        for name in transcripts {
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
