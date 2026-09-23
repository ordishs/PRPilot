import Testing
@testable import GatewayKit

private func facts(
    id: String = "owner/repo#1",
    isDisabled: Bool = false,
    limitMessage: String? = nil,
    awaitsMyResponse: Bool = false,
    hasUnseenAuthorUpdate: Bool = false
) -> GatewayItemFacts {
    GatewayItemFacts(
        id: id,
        isDisabled: isDisabled,
        limitMessage: limitMessage,
        awaitsMyResponse: awaitsMyResponse,
        hasUnseenAuthorUpdate: hasUnseenAuthorUpdate
    )
}

@Test func aLimitedAgentAsksForYouAndOffersToClearTheLimit() {
    let result = GatewayAttentionRule.evaluate(facts(limitMessage: "5-hour limit reached"))

    #expect(result.reason == "Agent hit its usage limit")
    #expect(result.primaryCommand == .clearAgentLimit(id: "owner/repo#1"))
}

@Test func anAgentAwaitingAnAnswerAsksForYouAndOffersToClearTheWait() {
    let result = GatewayAttentionRule.evaluate(facts(awaitsMyResponse: true))

    #expect(result.reason == "Agent is waiting for you")
    #expect(result.primaryCommand == .clearWaiting(id: "owner/repo#1"))
}

@Test func anUnseenAuthorPushAsksForYouAndOffersToMarkItSeen() {
    let result = GatewayAttentionRule.evaluate(facts(hasUnseenAuthorUpdate: true))

    #expect(result.reason == "Author pushed new commits")
    #expect(result.primaryCommand == .markAuthorUpdateSeen(id: "owner/repo#1"))
}

@Test func aLimitOutranksEveryOtherReason() {
    let result = GatewayAttentionRule.evaluate(
        facts(limitMessage: "spend limit", awaitsMyResponse: true, hasUnseenAuthorUpdate: true)
    )

    #expect(result.reason == "Agent hit its usage limit")
}

@Test func awaitingAnAnswerOutranksAnAuthorPush() {
    let result = GatewayAttentionRule.evaluate(facts(awaitsMyResponse: true, hasUnseenAuthorUpdate: true))

    #expect(result.reason == "Agent is waiting for you")
}

// A review the agent finished once used to ask for you forever, because nothing clears
// `claudeReviewedAt`. With the turn answered and nothing new, nothing is outstanding.
@Test func anItemWithNothingOutstandingAsksForNothing() {
    let result = GatewayAttentionRule.evaluate(facts())

    #expect(result.reason == nil)
    #expect(result.primaryCommand == nil)
}

@Test func aDisabledItemAsksForNothingWhateverElseIsTrue() {
    let result = GatewayAttentionRule.evaluate(
        facts(
            isDisabled: true,
            limitMessage: "5-hour limit reached",
            awaitsMyResponse: true,
            hasUnseenAuthorUpdate: true
        )
    )

    #expect(result.reason == nil)
    #expect(result.primaryCommand == nil)
}
