import Foundation
import PRPilotModels
import GatewayKit

/// Pure mapping from a `WorkItem` to the flat shape the phone renders.
///
/// Nothing here reads `AppModel`. The caller supplies the facts and the decoration, so this
/// is testable without a store, without `gh` and without git.
public enum GatewayProjection {
    public struct Decoration: Sendable {
        public var agent: GatewayAgent?
        public var badges: [GatewayBadge]
        public var issueStatus: String?
        public var ahead: Int
        public var behind: Int
        public var localChanges: Int

        public init(
            agent: GatewayAgent?,
            badges: [GatewayBadge],
            issueStatus: String?,
            ahead: Int,
            behind: Int,
            localChanges: Int
        ) {
            self.agent = agent
            self.badges = badges
            self.issueStatus = issueStatus
            self.ahead = ahead
            self.behind = behind
            self.localChanges = localChanges
        }
    }

    public static func item(
        from work: WorkItem,
        facts: GatewayItemFacts,
        decoration: Decoration
    ) -> GatewayItem {
        let classification = GatewayGrouping.classify(facts)

        let kind: GatewayItemKind
        let owner: String?
        let repo: String?
        let number: Int?
        let url: String?

        if let pr = work.prRef {
            kind = .pr
            owner = pr.owner
            repo = pr.repo
            number = pr.number
            url = pr.url.absoluteString
        } else if let issue = work.issueRef {
            kind = .issue
            owner = issue.owner
            repo = issue.repo
            number = issue.number
            url = issue.url.absoluteString
        } else {
            kind = .task
            owner = nil
            repo = nil
            number = nil
            url = nil
        }

        return GatewayItem(
            id: work.id,
            kind: kind,
            owner: owner,
            repo: repo,
            number: number,
            url: url,
            title: work.title,
            author: work.author,
            headBranch: work.headBranch,
            baseBranch: work.baseBranch,
            attentionReason: classification.reason,
            agent: decoration.agent,
            badges: decoration.badges,
            issueStatus: decoration.issueStatus,
            label: work.label,
            isDisabled: work.disabled,
            ahead: decoration.ahead,
            behind: decoration.behind,
            localChanges: decoration.localChanges,
            lastActivityAt: work.claudeLastCompletedAt ?? work.lastOpenedAt ?? work.addedAt,
            primaryCommand: classification.primaryCommand
        )
    }

    /// Groups are emitted in `GatewayGroupKind.allCases` order — needsYou, running, queued,
    /// idle — which is the order the client renders them. An empty group is dropped rather
    /// than sent as an empty heading.
    public static func groups(
        items: [WorkItem],
        facts: [String: GatewayItemFacts],
        decorate: (WorkItem) -> Decoration
    ) -> [GatewayGroup] {
        var buckets: [GatewayGroupKind: [GatewayItem]] = [:]

        for work in items {
            guard let itemFacts = facts[work.id] else { continue }
            let projected = item(from: work, facts: itemFacts, decoration: decorate(work))
            buckets[GatewayGrouping.classify(itemFacts).group, default: []].append(projected)
        }

        return GatewayGroupKind.allCases.compactMap { kind in
            guard let bucket = buckets[kind], !bucket.isEmpty else { return nil }
            return GatewayGroup(kind: kind, items: bucket)
        }
    }

    /// `AppModel.removeReview` deletes the worktree from disk, including uncommitted work.
    /// On a phone that is one mis-tap, so a dirty worktree can only be removed at the Mac.
    public static func removalRefusal(localChanges: Int) -> String? {
        guard localChanges > 0 else { return nil }
        return "This worktree has \(localChanges) local change\(localChanges == 1 ? "" : "s"). "
            + "Remove it at the Mac, or discard the changes there first."
    }
}
