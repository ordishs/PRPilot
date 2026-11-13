import Testing
import Foundation
@testable import PRPilotModels

private let at = Date(timeIntervalSince1970: 1_700_000_000)

private func row(_ kase: NextUpCase, trigger: String = "h1", id: String = "t1") -> NextUpRow {
    let step: NextUpStep
    switch kase {
    case .reviewRequested: step = .startReview
    case .ciRed, .changesRequested, .conflict: step = .startFix
    case .behind: step = .rebase
    case .issueInProgress: step = .continueWork
    case .sessionWaits, .readyToMerge: step = .open
    }

    return NextUpRow(itemID: id, kase: kase, reason: "r", step: step, since: at, trigger: trigger)
}

private func facts(
    busy: Bool = false,
    dirty: Bool = false,
    rebasing: Bool = false,
    worktree: Bool = true,
    clone: Bool = true,
    live: Bool = false,
    slot: Bool = true
) -> AutoFacts {
    AutoFacts(
        isBusy: busy, hasUncommittedChanges: dirty, rebaseInProgress: rebasing,
        hasWorktree: worktree, hasClone: clone, hasLiveSession: live, slotFree: slot
    )
}

private func decide(
    _ row: NextUpRow,
    _ mode: CoordinatorMode,
    _ facts: AutoFacts = facts(),
    handled: [String: HandledKind] = [:]
) -> AutoDecision {
    autoDecision(row: row, mode: mode, facts: facts, handled: handled)
}

@Test func askModeNotifiesForEveryCaseButIssueRows() {
    let notified: [NextUpCase] = [.reviewRequested, .sessionWaits, .ciRed, .changesRequested, .conflict, .behind, .readyToMerge]

    for kase in notified {
        #expect(decide(row(kase), .ask) == .notify(.newCause))
    }

    #expect(decide(row(.issueInProgress), .ask) == .skip(.rowOnly))
}

@Test func autoModeActsOnCasesOneAndThreeToSix() {
    #expect(decide(row(.reviewRequested), .auto) == .act(.startReview))
    #expect(decide(row(.ciRed), .auto) == .act(.startFix))
    #expect(decide(row(.changesRequested), .auto) == .act(.startFix))
    #expect(decide(row(.conflict), .auto) == .act(.startFix))
    #expect(decide(row(.behind), .auto) == .act(.rebase))
}

@Test func autoModeOnlyNotifiesForWaitingAndReadyToMerge() {
    #expect(decide(row(.sessionWaits), .auto) == .notify(.newCause))
    #expect(decide(row(.readyToMerge), .auto) == .notify(.newCause))
    #expect(decide(row(.issueInProgress), .auto) == .skip(.rowOnly))
}

@Test func noAutoDecisionCanReachAStepOutsideTheTable() {
    let allowed: Set<NextUpStep> = [.startReview, .startFix, .rebase]

    for raw in 1...8 {
        let kase = NextUpCase(rawValue: raw)!

        if case .act(let step) = decide(row(kase), .auto) {
            #expect(allowed.contains(step))
        }
    }
}

@Test func handledCauseGivesNoSecondNotification() {
    let item = row(.ciRed)

    #expect(decide(item, .ask, handled: [item.cause.key: .notified]) == .skip(.alreadyHandled))
    #expect(decide(row(.readyToMerge), .auto, handled: [row(.readyToMerge).cause.key: .notified]) == .skip(.alreadyHandled))
}

@Test func causeNotifiedInAskModeStillGetsOneAutoAction() {
    let item = row(.ciRed)

    #expect(decide(item, .auto, handled: [item.cause.key: .notified]) == .act(.startFix))
}

@Test func actedCauseGivesNoSecondAction() {
    let item = row(.ciRed)
    let handled = [item.cause.key: HandledKind.acted]

    #expect(decide(item, .auto, facts(busy: true), handled: handled) == .skip(.alreadyHandled))
    #expect(decide(item, .ask, handled: handled) == .skip(.alreadyHandled))
}

@Test func actedCauseStillTrueAfterTheSessionStopsNotifiesOnce() {
    let item = row(.ciRed)

    #expect(decide(item, .auto, handled: [item.cause.key: .acted]) == .notify(.fixDidNotClear))
    #expect(decide(item, .auto, handled: [item.cause.key: .failureNotified]) == .skip(.alreadyHandled))
}

@Test func newHeadCommitGivesNewCause() {
    let old = row(.ciRed, trigger: "h1")
    let new = row(.ciRed, trigger: "h2")

    #expect(old.cause.key != new.cause.key)
    #expect(decide(new, .auto, handled: [old.cause.key: .acted]) == .act(.startFix))
}

@Test func autoSkipsABusyDirtyOrRebasingTicket() {
    for blocked in [facts(busy: true), facts(dirty: true), facts(rebasing: true)] {
        #expect(decide(row(.ciRed), .auto, blocked) == .skip(.ticketBusy))
        #expect(decide(row(.behind), .auto, blocked) == .skip(.ticketBusy))
    }
}

@Test func noSlotBlocksSessionStepsButNotRebaseOrALiveSession() {
    let full = facts(slot: false)

    #expect(decide(row(.reviewRequested), .auto, full) == .skip(.noSlot))
    #expect(decide(row(.ciRed), .auto, full) == .skip(.noSlot))
    #expect(decide(row(.behind), .auto, full) == .act(.rebase))
    #expect(decide(row(.ciRed), .auto, facts(live: true, slot: false)) == .act(.startFix))
}

@Test func ticketWithNoWorktreeAndNoCloneIsSkipped() {
    let bare = facts(worktree: false, clone: false)

    #expect(decide(row(.ciRed), .auto, bare) == .skip(.noWorktree))
    #expect(decide(row(.behind), .auto, bare) == .skip(.noWorktree))
}

@Test func sessionStepNeedsOnlyACloneButRebaseNeedsAWorktree() {
    let cloneOnly = facts(worktree: false, clone: true)

    #expect(decide(row(.reviewRequested), .auto, cloneOnly) == .act(.startReview))
    #expect(decide(row(.behind), .auto, cloneOnly) == .skip(.noWorktree))
}

@Test func causeKeyHoldsTicketCaseAndTrigger() {
    #expect(row(.ciRed, trigger: "abc", id: "t9").cause.key == "t9|3|abc")
}
