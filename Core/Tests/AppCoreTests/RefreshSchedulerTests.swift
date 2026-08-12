import Testing
import Foundation
@testable import AppCore

private func stamp(_ secondsAgo: Int) -> Date {
    Date(timeIntervalSince1970: 1_000_000 - Double(secondsAgo))
}

@Test func schedulerAlwaysIncludesTheSelectedItem() {
    let chosen = RefreshScheduler.itemsToRefresh(
        openIDs: ["a", "b", "c"],
        selectedID: "c",
        lastRefreshedAt: ["a": stamp(10), "b": stamp(20), "c": stamp(0)],
        batchSize: 1
    )

    #expect(chosen.first == "c")
}

@Test func schedulerPicksTheMostStaleOthersFirst() {
    let chosen = RefreshScheduler.itemsToRefresh(
        openIDs: ["fresh", "stale", "stalest", "selected"],
        selectedID: "selected",
        lastRefreshedAt: [
            "fresh": stamp(1),
            "stale": stamp(50),
            "stalest": stamp(500),
            "selected": stamp(0),
        ],
        batchSize: 2
    )

    #expect(chosen == ["selected", "stalest", "stale"])
}

@Test func schedulerTreatsNeverRefreshedAsMostStale() {
    let chosen = RefreshScheduler.itemsToRefresh(
        openIDs: ["seen", "never"],
        selectedID: nil,
        lastRefreshedAt: ["seen": stamp(9999)],
        batchSize: 1
    )

    #expect(chosen == ["never"])
}

@Test func schedulerHonoursTheBatchSize() {
    let chosen = RefreshScheduler.itemsToRefresh(
        openIDs: ["a", "b", "c", "d", "e", "f"],
        selectedID: "a",
        lastRefreshedAt: [:],
        batchSize: 4
    )

    #expect(chosen.count == 5)
}

@Test func schedulerSkipsASelectionThatIsNotOpen() {
    let chosen = RefreshScheduler.itemsToRefresh(
        openIDs: ["a", "b"],
        selectedID: "closed",
        lastRefreshedAt: [:],
        batchSize: 4
    )

    #expect(chosen == ["a", "b"])
}
