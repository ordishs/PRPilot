import Testing
import Foundation
@testable import AgentKit

/// The two `stop_sequence` lines a real blocked session wrote, copied verbatim from
/// `4df7aef5-fe6c-4df7-a5fc-6d2e2c1974b4.jsonl`. One is the limit, the other is the reply
/// the resume nudge got. They share a stop reason, which is why the text has to decide.
private let realSpendLimitText =
    "You've hit your individual spend limit · run /usage-credits to ask your admin for a higher limit"
private let realNudgeReplyText = "No response requested."

@Test func realSpendLimitLineIsALimitStop() {
    #expect(LimitStop.message(stopReason: "stop_sequence", text: realSpendLimitText) == realSpendLimitText)
}

@Test func realNudgeReplyIsNotALimitStop() {
    #expect(LimitStop.message(stopReason: "stop_sequence", text: realNudgeReplyText) == nil)
}

@Test func everyLimitPhraseMatches() {
    let texts = [
        "You've hit your individual spend limit · run /usage-credits to ask your admin for a higher limit",
        "Claude usage limit reached. Your limit will reset at 3pm.",
        "5-hour limit reached ∙ resets 3pm",
        "Approaching the 5-hour limit",
        "API rate limit exceeded, try again later",
        "Your limit will reset at 21:00",
        "Quota resets at midnight UTC",
    ]
    for text in texts {
        #expect(LimitStop.message(stopReason: "stop_sequence", text: text) == text,
                "should match: \(text)")
    }
}

@Test func matchingIsCaseInsensitive() {
    #expect(LimitStop.message(stopReason: "stop_sequence", text: "SPEND LIMIT reached") != nil)
    #expect(LimitStop.message(stopReason: "stop_sequence", text: "Usage Limit Reached") != nil)
}

@Test func ordinaryProseIsNotALimitStop() {
    let texts = [
        "No response requested.",
        "Done. The tests pass.",
        "I will now read the file.",
        "",
    ]
    for text in texts {
        #expect(LimitStop.message(stopReason: "stop_sequence", text: text) == nil,
                "should not match: \(text)")
    }
}

@Test func onlyAStopSequenceTurnCanBeALimitStop() {
    // The same words mid-turn are the agent talking about limits, not being stopped by one.
    #expect(LimitStop.message(stopReason: "tool_use", text: realSpendLimitText) == nil)
    #expect(LimitStop.message(stopReason: "end_turn", text: realSpendLimitText) == nil)
    #expect(LimitStop.message(stopReason: nil, text: realSpendLimitText) == nil)
}

@Test func missingTextIsNotALimitStop() {
    #expect(LimitStop.message(stopReason: "stop_sequence", text: nil) == nil)
}

@Test func theMessageIsTrimmedButOtherwiseVerbatim() {
    let padded = "  \(realSpendLimitText)\n"
    #expect(LimitStop.message(stopReason: "stop_sequence", text: padded) == realSpendLimitText)
}
