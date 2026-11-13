import Foundation

/// What a row is about: the ticket, the case, and the value that makes the case new. The
/// trigger is the head commit for cases 3 to 7, and a time for cases 1, 2 and 8. The app
/// notifies one time per cause and AUTO acts one time per cause.
public struct CoordinatorCause: Codable, Hashable, Sendable {
    public let itemID: String
    public let kase: NextUpCase
    public let trigger: String

    public var key: String { "\(itemID)|\(kase.rawValue)|\(trigger)" }

    public init(itemID: String, kase: NextUpCase, trigger: String) {
        self.itemID = itemID
        self.kase = kase
        self.trigger = trigger
    }
}

extension NextUpRow {
    public var cause: CoordinatorCause {
        CoordinatorCause(itemID: itemID, kase: kase, trigger: trigger)
    }
}

public enum HandledKind: String, Codable, Sendable, Equatable {
    case notified
    case acted
    case failureNotified
}

public struct AutoLogEntry: Codable, Sendable, Equatable {
    public let at: Date
    public let itemID: String
    public let title: String
    public let kase: NextUpCase
    public let action: String
    public let result: String

    public init(at: Date, itemID: String, title: String, kase: NextUpCase, action: String, result: String) {
        self.at = at
        self.itemID = itemID
        self.title = title
        self.kase = kase
        self.action = action
        self.result = result
    }
}

public enum CoordinatorMode: Sendable, Equatable {
    case ask
    case auto
}

public struct AutoFacts: Sendable, Equatable {
    /// The agent is starting or working.
    public var isBusy: Bool
    public var hasUncommittedChanges: Bool
    public var rebaseInProgress: Bool
    public var hasWorktree: Bool
    /// A registered local clone exists, so a session start can create the worktree.
    public var hasClone: Bool
    public var hasLiveSession: Bool
    public var slotFree: Bool

    public init(
        isBusy: Bool = false,
        hasUncommittedChanges: Bool = false,
        rebaseInProgress: Bool = false,
        hasWorktree: Bool = false,
        hasClone: Bool = false,
        hasLiveSession: Bool = false,
        slotFree: Bool = false
    ) {
        self.isBusy = isBusy
        self.hasUncommittedChanges = hasUncommittedChanges
        self.rebaseInProgress = rebaseInProgress
        self.hasWorktree = hasWorktree
        self.hasClone = hasClone
        self.hasLiveSession = hasLiveSession
        self.slotFree = slotFree
    }
}

public enum NotifyReason: Sendable, Equatable {
    case newCause
    case fixDidNotClear
}

public enum SkipReason: Sendable, Equatable {
    case alreadyHandled
    case rowOnly
    case ticketBusy
    case noSlot
    case noWorktree
}

public enum AutoDecision: Sendable, Equatable {
    case act(NextUpStep)
    case notify(NotifyReason)
    case skip(SkipReason)
}

/// The Ask and AUTO tables as one pure function. AUTO reaches only the three steps in the
/// table, and the step type has no case that merges or posts.
public func autoDecision(
    row: NextUpRow,
    mode: CoordinatorMode,
    facts: AutoFacts,
    handled: [String: HandledKind]
) -> AutoDecision {
    if row.kase == .issueInProgress { return .skip(.rowOnly) }

    let autoStep = autoStep(for: row.kase)

    switch handled[row.cause.key] {
    case .failureNotified:
        return .skip(.alreadyHandled)

    case .acted:
        guard mode == .auto, !facts.isBusy else { return .skip(.alreadyHandled) }

        return .notify(.fixDidNotClear)

    case .notified:
        guard mode == .auto, autoStep != nil else { return .skip(.alreadyHandled) }

    case nil:
        break
    }

    guard mode == .auto, let step = autoStep else { return .notify(.newCause) }

    if facts.isBusy || facts.hasUncommittedChanges || facts.rebaseInProgress { return .skip(.ticketBusy) }

    if step == .rebase {
        if !facts.hasWorktree { return .skip(.noWorktree) }
    } else {
        if !facts.hasWorktree && !facts.hasClone { return .skip(.noWorktree) }
        if !facts.hasLiveSession && !facts.slotFree { return .skip(.noSlot) }
    }

    return .act(step)
}

private func autoStep(for kase: NextUpCase) -> NextUpStep? {
    switch kase {
    case .reviewRequested: return .startReview
    case .ciRed, .changesRequested, .conflict: return .startFix
    case .behind: return .rebase
    case .sessionWaits, .readyToMerge, .issueInProgress: return nil
    }
}
