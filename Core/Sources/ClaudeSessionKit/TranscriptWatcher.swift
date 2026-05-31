import Foundation

@MainActor
public final class TranscriptWatcher {
    private let transcriptDir: URL
    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var currentFileURL: URL?
    private var readOffset: Int = 0
    private var onEvent: (@MainActor (Date, String?, Bool) -> Void)?
    private let isoFormatter: ISO8601DateFormatter
    private let isoFormatterNoFrac: ISO8601DateFormatter

    public init(transcriptDir: URL) {
        self.transcriptDir = transcriptDir
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.isoFormatter = fmt
        let fmt2 = ISO8601DateFormatter()
        fmt2.formatOptions = [.withInternetDateTime]
        self.isoFormatterNoFrac = fmt2
    }

    /// Fires for each transcript line: (timestamp, assistant text snippet, turnCompleted).
    /// `turnCompleted` is true when an assistant message finished its turn
    /// (`stop_reason == "end_turn"`) — the signal that a review actually completed, as
    /// opposed to merely going idle after being interrupted mid-task.
    public func start(onEvent: @escaping @MainActor (Date, String?, Bool) -> Void) {
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
        let snippet = extractSnippet(from: data, type: event.type)
        let turnCompleted = isCompletedTurn(from: data, type: event.type)
        onEvent?(date, snippet, turnCompleted)
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
