import Testing
import Foundation
import PRPilotModels
@testable import AgentKit

/// Reading the allowance out of codex's own telemetry.
///
/// The `token_count` lines below are copied from real sessions under `~/.codex/sessions`. The
/// gauge exists to arrive *before* the agent stops, so a schema change that silences it must
/// fail here rather than pass quietly.
struct CodexUsageTests {
    private static func parse(_ line: String) -> TranscriptEvent? {
        var state = TranscriptParseState()
        return CodexBackend().parse(line: Data(line.utf8), state: &state)
    }

    /// Verbatim from a real session, apart from shortening the token counts.
    private static let realLine = #"{"timestamp":"2026-08-15T15:03:14.540Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":25530}},"rate_limits":{"limit_id":"codex","limit_name":null,"primary":{"used_percent":9.0,"window_minutes":10080,"resets_at":1786206068},"secondary":null,"credits":{"has_credits":false,"unlimited":false,"balance":"0"},"individual_limit":null,"spend_control_reached":null,"plan_type":"plus","rate_limit_reached_type":null}}}"#

    @Test func aRealTokenCountLineYieldsTheUsage() {
        let usage = Self.parse(Self.realLine)?.usage
        #expect(usage?.usedPercent == 9.0)
        #expect(usage?.windowMinutes == 10080)
        #expect(usage?.resetsAt == Date(timeIntervalSince1970: 1_786_206_068))
        #expect(usage?.agent == .codex)
        // Read from the line's own timestamp, not from the clock, so a replayed transcript
        // does not look freshly read.
        #expect(usage?.readAt == TranscriptTimestamp.date(from: "2026-08-15T15:03:14.540Z"))
    }

    /// The gauge and the limit badge come off the same block, and must not be confused: this
    /// line reports 9% with both limit fields null, so it is usage and not a block.
    @Test func aHealthyReadingIsUsageAndNotALimit() {
        let event = Self.parse(Self.realLine)
        #expect(event?.usage != nil)
        #expect(event?.limitMessage == nil)
    }

    /// A blocked reading carries both: the badge says stopped, the gauge says why.
    @Test func aBlockedReadingCarriesUsageAndTheLimit() {
        let line = #"{"timestamp":"2026-08-15T15:03:14.540Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":{"used_percent":100.0,"window_minutes":10080,"resets_at":1786206068},"spend_control_reached":null,"rate_limit_reached_type":"primary"}}}"#
        let event = Self.parse(line)
        #expect(event?.usage?.usedPercent == 100.0)
        #expect(event?.limitMessage != nil)
    }

    @Test func noRateLimitBlockYieldsNoUsage() {
        let line = #"{"timestamp":"2026-08-15T15:03:14.540Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":10}}}}"#
        let event = Self.parse(line)
        #expect(event != nil, "the line is still liveness")
        #expect(event?.usage == nil)
    }

    /// Only the primary window is read. codex reports a secondary one, null in every session
    /// read here, and guessing at its meaning would put a wrong number in front of the user.
    @Test func aBlockWithNoPrimaryWindowYieldsNoUsage() {
        let line = #"{"timestamp":"2026-08-15T15:03:14.540Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"codex","primary":null,"secondary":{"used_percent":50.0},"rate_limit_reached_type":null}}}"#
        #expect(Self.parse(line)?.usage == nil)
    }

    @Test func usageIsOnlyReadFromTokenCountLines() {
        let line = #"{"timestamp":"2026-08-15T15:03:14.540Z","type":"event_msg","payload":{"type":"task_complete","rate_limits":{"primary":{"used_percent":50.0}}}}"#
        #expect(Self.parse(line)?.usage == nil)
    }

    /// Claude Code and pi publish nothing, so their lines must not invent a figure.
    @Test func theOtherAgentsReportNoUsage() {
        var state = TranscriptParseState()
        let claude = #"{"type":"assistant","timestamp":"2026-08-26T12:00:00.000Z","message":{"role":"assistant","stop_reason":"end_turn","content":[{"type":"text","text":"done"}]}}"#
        #expect(ClaudeCodeBackend().parse(line: Data(claude.utf8), state: &state)?.usage == nil)

        let pi = #"{"type":"message","timestamp":"2026-08-26T12:00:00.000Z","message":{"role":"assistant","stopReason":"stop","content":[{"type":"text","text":"done"}]}}"#
        #expect(PiBackend().parse(line: Data(pi.utf8), state: &state)?.usage == nil)
    }
}

/// How a reading is presented and when it is dropped.
struct AgentUsageModelTests {
    private func usage(
        _ percent: Double,
        window: Int? = 10080,
        resetsAt: Date? = nil,
        readAt: Date = Date(timeIntervalSince1970: 1_786_000_000)
    ) -> AgentUsage {
        AgentUsage(usedPercent: percent, windowMinutes: window, resetsAt: resetsAt, agent: .codex, readAt: readAt)
    }

    /// Rounds down, so an agent that is still working never reads as 100%.
    @Test func theDisplayedPercentageRoundsDown() {
        #expect(usage(99.6).displayPercent == 99)
        #expect(usage(9.0).displayPercent == 9)
        #expect(usage(0.4).displayPercent == 0)
        #expect(usage(100.0).displayPercent == 100)
    }

    /// A figure outside 0–100 is clamped rather than shown. Nothing observed reports one, and a
    /// "-3%" badge would read as a bug in PR Pilot.
    @Test func anImpossiblePercentageIsClamped() {
        #expect(usage(-5).displayPercent == 0)
        #expect(usage(140).displayPercent == 100)
    }

    @Test func theWindowReadsInDaysOrHours() {
        #expect(usage(9, window: 10080).windowDescription == "7 days")
        #expect(usage(9, window: 1440).windowDescription == "1 day")
        #expect(usage(9, window: 300).windowDescription == "5 hours")
        #expect(usage(9, window: 60).windowDescription == "1 hour")
        #expect(usage(9, window: 90).windowDescription == "90 minutes")
        #expect(usage(9, window: nil).windowDescription == nil)
        #expect(usage(9, window: 0).windowDescription == nil)
    }

    @Test func theThresholdIsInclusive() {
        #expect(usage(90).hasReached(90))
        #expect(usage(90.0).hasReached(90))
        #expect(!usage(89.9).hasReached(90))
    }

    /// A reading whose window has reset is worthless, and worse than nothing: it would invite a
    /// handover on the strength of a figure that no longer holds.
    @Test func aReadingIsStaleOnceItsWindowHasReset() {
        let read = Date(timeIntervalSince1970: 1_786_000_000)
        let resets = read.addingTimeInterval(3600)
        let value = usage(95, resetsAt: resets, readAt: read)
        #expect(!value.isStale(now: resets.addingTimeInterval(-1)))
        #expect(value.isStale(now: resets))
        #expect(value.isStale(now: resets.addingTimeInterval(60)))
    }

    /// A reset time is not always given, so age alone has to bound it too.
    @Test func aReadingWithNoResetTimeStillExpiresWithAge() {
        let read = Date(timeIntervalSince1970: 1_786_000_000)
        let value = usage(95, resetsAt: nil, readAt: read)
        #expect(!value.isStale(now: read.addingTimeInterval(11 * 3600)))
        #expect(value.isStale(now: read.addingTimeInterval(13 * 3600)))
    }

    @Test func usageRoundTripsThroughJSON() throws {
        let value = usage(93.5, window: 10080, resetsAt: Date(timeIntervalSince1970: 1_786_206_068))
        let decoded = try JSONDecoder().decode(AgentUsage.self, from: try JSONEncoder().encode(value))
        #expect(decoded == value)
    }
}
