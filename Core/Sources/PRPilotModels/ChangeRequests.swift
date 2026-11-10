import Foundation

/// One review on a PR, with the commit it was made against.
public struct ReviewVerdict: Sendable, Equatable {
    public var login: String
    public var state: String
    public var commitOID: String?
    public var at: Date?

    public init(login: String, state: String, commitOID: String?, at: Date?) {
        self.login = login
        self.state = state
        self.commitOID = commitOID
        self.at = at
    }
}

/// How many reviewers are asking for changes, and on which code.
public struct ChangeRequestTally: Sendable, Equatable, Codable {
    /// Reviewers whose standing request for changes was made on the current head commit.
    public var current: Int
    /// Reviewers whose standing request was made on an older commit. The author has pushed
    /// since, so the ball is with the reviewer.
    public var outdated: Int

    public init(current: Int = 0, outdated: Int = 0) {
        self.current = current
        self.outdated = outdated
    }

    /// Every standing request predates the latest push.
    public var isOutdatedOnly: Bool { outdated > 0 && current == 0 }

    private static let decisive = ["APPROVED", "CHANGES_REQUESTED", "DISMISSED"]

    /// Each reviewer's newest decisive review decides their stance, the same rule that decides
    /// your own review state: a comment never lifts a request, an approval or a dismissal does.
    /// A request counts as outdated only when both commits are known and differ, so missing
    /// data never hides a live request.
    ///
    /// The caller removes bots before passing verdicts.
    public static func tally(verdicts: [ReviewVerdict], headOID: String?) -> ChangeRequestTally {
        var tally = ChangeRequestTally()
        for (_, reviews) in Dictionary(grouping: verdicts, by: { $0.login.lowercased() }) {
            let newest = reviews
                .filter { decisive.contains($0.state) }
                .max { ($0.at ?? .distantPast) < ($1.at ?? .distantPast) }
            guard let newest, newest.state == "CHANGES_REQUESTED" else { continue }
            if let headOID, let commit = newest.commitOID, commit != headOID {
                tally.outdated += 1
            } else {
                tally.current += 1
            }
        }
        return tally
    }
}
