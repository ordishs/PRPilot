import Testing
@testable import GatewayKit

private func facts(
    id: String = "owner/repo#1",
    isDisabled: Bool = false,
    limitMessage: String? = nil,
    awaitsMyResponse: Bool = false,
    hasVerdict: Bool = false,
    hasUnseenAuthorUpdate: Bool = false,
    sessionIsLive: Bool = false,
    isQueued: Bool = false
) -> GatewayItemFacts {
    GatewayItemFacts(
        id: id,
        isDisabled: isDisabled,
        limitMessage: limitMessage,
        awaitsMyResponse: awaitsMyResponse,
        hasVerdict: hasVerdict,
        hasUnseenAuthorUpdate: hasUnseenAuthorUpdate,
        sessionIsLive: sessionIsLive,
        isQueued: isQueued
    )
}

@Test func aLimitedAgentNeedsYouAndOffersToClearTheLimit() {
    let result = GatewayGrouping.classify(facts(limitMessage: "5-hour limit reached"))

    #expect(result.group == .needsYou)
    #expect(result.reason == "Agent hit its usage limit")
    #expect(result.primaryCommand == .clearAgentLimit(id: "owner/repo#1"))
}

@Test func anAgentAwaitingAnAnswerNeedsYouAndOffersToClearTheWait() {
    let result = GatewayGrouping.classify(facts(awaitsMyResponse: true))

    #expect(result.group == .needsYou)
    #expect(result.reason == "Agent is waiting for you")
    #expect(result.primaryCommand == .clearWaiting(id: "owner/repo#1"))
}

@Test func aFinishedReviewNeedsYouButOffersNoCommand() {
    let result = GatewayGrouping.classify(facts(hasVerdict: true))

    #expect(result.group == .needsYou)
    #expect(result.reason == "Agent finished its review")
    #expect(result.primaryCommand == nil)
}

@Test func anUnseenAuthorPushNeedsYouAndOffersToMarkItSeen() {
    let result = GatewayGrouping.classify(facts(hasUnseenAuthorUpdate: true))

    #expect(result.group == .needsYou)
    #expect(result.reason == "Author pushed new commits")
    #expect(result.primaryCommand == .markAuthorUpdateSeen(id: "owner/repo#1"))
}

@Test func aLimitOutranksEveryOtherReason() {
    let result = GatewayGrouping.classify(
        facts(
            limitMessage: "spend limit",
            awaitsMyResponse: true,
            hasVerdict: true,
            hasUnseenAuthorUpdate: true
        )
    )

    #expect(result.reason == "Agent hit its usage limit")
}

@Test func awaitingAnAnswerOutranksAVerdictAndAnAuthorPush() {
    let result = GatewayGrouping.classify(
        facts(awaitsMyResponse: true, hasVerdict: true, hasUnseenAuthorUpdate: true)
    )

    #expect(result.reason == "Agent is waiting for you")
}

@Test func aVerdictOutranksAnAuthorPush() {
    let result = GatewayGrouping.classify(facts(hasVerdict: true, hasUnseenAuthorUpdate: true))

    #expect(result.reason == "Agent finished its review")
}

@Test func aLiveSessionWithNothingOutstandingIsRunning() {
    let result = GatewayGrouping.classify(facts(sessionIsLive: true))

    #expect(result.group == .running)
    #expect(result.reason == nil)
    #expect(result.primaryCommand == nil)
}

@Test func aQueuedItemIsQueued() {
    let result = GatewayGrouping.classify(facts(isQueued: true))

    #expect(result.group == .queued)
    #expect(result.reason == nil)
}

@Test func aLiveSessionOutranksTheQueue() {
    let result = GatewayGrouping.classify(facts(sessionIsLive: true, isQueued: true))

    #expect(result.group == .running)
}

@Test func anItemWithNothingHappeningIsIdle() {
    let result = GatewayGrouping.classify(facts())

    #expect(result.group == .idle)
    #expect(result.reason == nil)
    #expect(result.primaryCommand == nil)
}

@Test func aDisabledItemIsAlwaysIdleWhateverElseIsTrue() {
    let result = GatewayGrouping.classify(
        facts(
            isDisabled: true,
            limitMessage: "5-hour limit reached",
            awaitsMyResponse: true,
            hasVerdict: true,
            hasUnseenAuthorUpdate: true,
            sessionIsLive: true,
            isQueued: true
        )
    )

    #expect(result.group == .idle)
    #expect(result.reason == nil)
    #expect(result.primaryCommand == nil)
}
