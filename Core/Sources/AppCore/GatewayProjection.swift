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
        sidebar: SidebarItemFacts,
        decoration: Decoration
    ) -> GatewayItem {
        let attention = GatewayAttentionRule.evaluate(facts)

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
            attentionReason: attention.reason,
            agent: decoration.agent,
            badges: decoration.badges,
            issueStatus: decoration.issueStatus,
            label: work.label,
            isDisabled: work.disabled,
            ahead: decoration.ahead,
            behind: decoration.behind,
            localChanges: decoration.localChanges,
            lastActivityAt: work.claudeLastCompletedAt ?? work.lastOpenedAt ?? work.addedAt,
            primaryCommand: attention.primaryCommand,
            signals: SignalFilter.ordered.filter { sidebar.has($0) }.map(\.key),
            resources: ResourceFilter.ordered.filter { sidebar.has($0) }.map(\.key),
            isParked: sidebar.isParked,
            addedAt: work.addedAt,
            statusRank: statusRank(work.prState)
        )
    }

    /// The Mac's three sections, split and sorted by the same `sidebarSections` call the
    /// sidebar makes. Every section is sent, empty or not, because the Mac shows every
    /// heading with its count.
    public static func sections(
        items: [WorkItem],
        myLogin: String?,
        sort: SidebarSort,
        facts: [String: GatewayItemFacts],
        sidebarFacts: (WorkItem) -> SidebarItemFacts,
        decorate: (WorkItem) -> Decoration
    ) -> [GatewaySection] {
        let known = items.filter { facts[$0.id] != nil }
        let split = sidebarSections(items: known, myLogin: myLogin, sort: sort)

        func project(_ works: [WorkItem]) -> [GatewayItem] {
            works.compactMap { work in
                guard let itemFacts = facts[work.id] else { return nil }
                return item(
                    from: work,
                    facts: itemFacts,
                    sidebar: sidebarFacts(work),
                    decoration: decorate(work)
                )
            }
        }

        return [
            GatewaySection(kind: .myWork, items: project(split.myWork)),
            GatewaySection(kind: .reviewRequests, items: project(split.reviewRequests)),
            GatewaySection(kind: .issues, items: project(split.issues)),
        ]
    }

    /// The pills and sort orders the Mac sidebar offers, in its order and with its words,
    /// plus the Mac's own sort and Hide parked as the phone's starting point.
    public static func listing(sort: SidebarSort, hideParked: Bool) -> GatewayListing {
        GatewayListing(
            signalFilters: SignalFilter.ordered.map {
                GatewayOption(key: $0.key, label: $0.displayName, help: $0.help)
            },
            resourceFilters: ResourceFilter.ordered.map {
                GatewayOption(key: $0.key, label: $0.displayName, help: $0.help)
            },
            sorts: SidebarSort.allCases.map {
                GatewayOption(key: $0.rawValue, label: $0.displayName, help: "")
            },
            sort: sort.rawValue,
            hideParked: hideParked
        )
    }

    /// `AppModel.removeReview` deletes the worktree from disk, including uncommitted work.
    /// On a phone that is one mis-tap, so a dirty worktree can only be removed at the Mac.
    public static func removalRefusal(localChanges: Int) -> String? {
        guard localChanges > 0 else { return nil }
        return "This worktree has \(localChanges) local change\(localChanges == 1 ? "" : "s"). "
            + "Remove it at the Mac, or discard the changes there first."
    }
}
