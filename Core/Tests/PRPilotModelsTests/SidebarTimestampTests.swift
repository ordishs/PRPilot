import Testing
import Foundation
@testable import PRPilotModels

private var utc: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    c.locale = Locale(identifier: "en_US_POSIX")
    return c
}

private func date(_ iso: String) -> Date {
    let f = ISO8601DateFormatter()
    f.timeZone = TimeZone(identifier: "UTC")!
    return f.date(from: iso)!
}

private func item(addedAt: Date) -> WorkItem {
    WorkItem(
        title: "centrifuge fix",
        repoKey: "github.com/bsv-blockchain/teranode",
        baseBranch: "main",
        origin: .added,
        addedAt: addedAt
    )
}

@Test func lastActivityFallsBackToAddedAt() {
    let added = date("2026-08-19T14:32:00Z")
    #expect(lastActivityAt(item(addedAt: added), authorUpdatedAt: nil) == added)
}

@Test func lastActivityTakesTheNewestOfTheThree() {
    let added = date("2026-08-01T09:00:00Z")
    var i = item(addedAt: added)
    i.claudeLastCompletedAt = date("2026-08-19T14:32:00Z")
    #expect(lastActivityAt(i, authorUpdatedAt: date("2026-08-05T11:00:00Z")) == i.claudeLastCompletedAt)
    #expect(lastActivityAt(i, authorUpdatedAt: date("2026-08-20T08:00:00Z")) == date("2026-08-20T08:00:00Z"))
}

@Test func lastActivityIgnoresOlderSignals() {
    let added = date("2026-08-19T14:32:00Z")
    var i = item(addedAt: added)
    i.claudeLastCompletedAt = date("2026-08-01T09:00:00Z")
    #expect(lastActivityAt(i, authorUpdatedAt: date("2026-07-01T09:00:00Z")) == added)
}

@Test func todayShowsClockTime() {
    let now = date("2026-08-20T18:00:00Z")
    #expect(sidebarDateLabel(for: date("2026-08-20T14:32:00Z"), now: now, calendar: utc) == "Today 14:32")
    #expect(sidebarDateLabel(for: date("2026-08-20T09:07:00Z"), now: now, calendar: utc) == "Today 09:07")
}

@Test func yesterdayShowsClockTime() {
    let now = date("2026-08-20T18:00:00Z")
    #expect(sidebarDateLabel(for: date("2026-08-19T09:07:00Z"), now: now, calendar: utc) == "Yesterday 09:07")
}

@Test func earlierThisYearShowsDayMonthAndClock() {
    let now = date("2026-08-20T18:00:00Z")
    #expect(sidebarDateLabel(for: date("2026-08-18T14:32:00Z"), now: now, calendar: utc) == "18 Aug 14:32")
    #expect(sidebarDateLabel(for: date("2026-01-03T00:05:00Z"), now: now, calendar: utc) == "3 Jan 00:05")
}

@Test func anotherYearShowsTheYearInsteadOfTheClock() {
    let now = date("2026-08-20T18:00:00Z")
    #expect(sidebarDateLabel(for: date("2025-03-14T14:32:00Z"), now: now, calendar: utc) == "14 Mar 2025")
    // A prior year is dated by its year even when it is only days away.
    #expect(sidebarDateLabel(for: date("2025-12-30T23:59:00Z"),
                             now: date("2026-01-01T00:30:00Z"), calendar: utc) == "30 Dec 2025")
}

@Test func yesterdayWinsOverTheYearRuleAcrossNewYear() {
    // 31 Dec is the day before 1 Jan, so the yesterday rule fires first and keeps the clock.
    // The year is lost from the short label on purpose; the tooltip still carries it.
    #expect(sidebarDateLabel(for: date("2025-12-31T23:59:00Z"),
                             now: date("2026-01-01T09:00:00Z"), calendar: utc) == "Yesterday 23:59")
    #expect(sidebarDateTooltip(for: date("2025-12-31T23:59:00Z"), calendar: utc) == "Wed 31 Dec 2025 at 23:59")
}

@Test func tooltipCarriesTheFullDate() {
    #expect(sidebarDateTooltip(for: date("2026-08-19T14:32:00Z"), calendar: utc) == "Wed 19 Aug 2026 at 14:32")
    #expect(sidebarDateTooltip(for: date("2025-03-14T09:07:00Z"), calendar: utc) == "Fri 14 Mar 2025 at 09:07")
}

@Test func agentRunLabelPairsStartAndLastReply() {
    let started = date("2026-08-19T14:32:00Z")
    let completed = date("2026-08-20T09:07:00Z")
    let now = date("2026-08-20T18:00:00Z")
    #expect(agentRunLabel(startedAt: started, lastCompletedAt: completed, now: now, calendar: utc)
        == "started Yesterday 14:32 · last reply Today 09:07")
    #expect(agentRunLabel(startedAt: started, lastCompletedAt: nil, now: now, calendar: utc)
        == "started Yesterday 14:32")
    // An older run falls back to the dated form.
    #expect(agentRunLabel(startedAt: date("2026-08-11T14:32:00Z"), lastCompletedAt: nil,
                          now: now, calendar: utc) == "started 11 Aug 14:32")
    #expect(agentRunLabel(startedAt: nil, lastCompletedAt: completed, now: now, calendar: utc)
        == "last reply Today 09:07")
    #expect(agentRunLabel(startedAt: nil, lastCompletedAt: nil, now: now, calendar: utc) == nil)
}
