import Testing
@testable import AppCore

@Test func webViewBudgetEvictsNothingUnderTheCap() {
    let victims = WebViewBudget.evictions(
        activationOrder: ["a", "b"],
        cap: 8,
        selectedID: "a"
    )

    #expect(victims.isEmpty)
}

@Test func webViewBudgetEvictsTheOldestBeyondTheCap() {
    let victims = WebViewBudget.evictions(
        activationOrder: ["newest", "middle", "oldest"],
        cap: 1,
        selectedID: "newest"
    )

    #expect(victims == ["oldest", "middle"])
}

@Test func webViewBudgetNeverEvictsTheSelectedItem() {
    let victims = WebViewBudget.evictions(
        activationOrder: ["newest", "middle", "oldest"],
        cap: 2,
        selectedID: "oldest"
    )

    #expect(victims == ["middle"])
}

@Test func webViewBudgetEvictsNothingForANonPositiveCap() {
    let victims = WebViewBudget.evictions(
        activationOrder: ["a", "b", "c"],
        cap: 0,
        selectedID: nil
    )

    #expect(victims.isEmpty)
}
