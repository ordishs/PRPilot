import Foundation

/// Parses the ISO8601 timestamps both agents put at the top level of every transcript line.
/// Claude Code and pi both write fractional seconds, but neither guarantees it, so try the
/// fractional format first and fall back.
enum TranscriptTimestamp {
    static func date(from string: String) -> Date? {
        withFractionalSeconds.date(from: string) ?? withoutFractionalSeconds.date(from: string)
    }

    // Formatters are expensive to build and this runs per transcript line. Both are only ever
    // reached from `TranscriptWatcher`, which is @MainActor, so the shared instances are never
    // touched concurrently.
    nonisolated(unsafe) private static let withFractionalSeconds: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) private static let withoutFractionalSeconds: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
