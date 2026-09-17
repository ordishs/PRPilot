import Foundation
import PRPilotModels
import AgentKit
import GatewayKit

extension AppModel: GatewayBackend {
    public func snapshot() -> GatewaySnapshot {
        let items = reviews
        var facts: [String: GatewayItemFacts] = [:]

        for work in items {
            facts[work.id] = GatewayItemFacts(
                id: work.id,
                isDisabled: work.disabled,
                limitMessage: work.agentLimitMessage,
                awaitsMyResponse: work.awaitsMyResponse(myLogin: currentLogin),
                hasVerdict: work.claudeReviewedAt != nil,
                hasUnseenAuthorUpdate: hasUnseenAuthorUpdate(work),
                sessionIsLive: claudeSessions[work.id] != nil,
                isQueued: queuedReviewIDs.contains(work.id)
            )
        }

        let groups = GatewayProjection.groups(items: items, facts: facts) { work in
            GatewayProjection.Decoration(
                agent: gatewayAgent(for: work),
                badges: gatewayBadges(for: work),
                issueStatus: gatewayIssueStatus(for: work),
                ahead: pushability[work.id]?.ahead ?? 0,
                behind: pushability[work.id]?.behind ?? 0,
                localChanges: worktreeLocalChanges[work.id] ?? 0
            )
        }

        return GatewaySnapshot(
            generatedAt: Date(),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
            login: currentLogin,
            groups: groups,
            warnings: discoveryWarnings
        )
    }

    public func perform(_ command: GatewayCommand) async -> GatewayCommandResult {
        switch command {
        case .refreshAll:
            await refreshAllNow()

        case .refreshItem(let id):
            await refreshReviewState(for: id)
            await refreshWorktreeCleanliness(for: id)

        case .markAuthorUpdateSeen(let id):
            await markAuthorUpdateSeen(id: id)

        case .clearWaiting(let id):
            await clearWaiting(id: id)

        case .setPane(let id, let pane):
            guard let selection = PaneSelection(rawValue: pane) else {
                return rejection("unknown pane \(pane)")
            }
            await setPane(selection, for: id)

        case .startSession(let id, let forceFresh):
            guard let work = reviews.first(where: { $0.id == id }) else {
                return rejection("no such item")
            }
            await ensureAgentSession(for: work, forceFresh: forceFresh)

        case .clearSession(let id):
            await clearAgentSession(for: id)

        case .clearAgentLimit(let id):
            await clearAgentLimit(for: id)

        case .handOver(let id):
            guard await handOverToFailoverAgent(for: id) else {
                return rejection("no failover agent is available for this item")
            }

        case .addPR(let url):
            await addPR(urlString: url)

        case .addIssue(let url):
            await addIssue(urlString: url)

        case .setIssueStatus(let id, let status):
            let resolved = status.flatMap(IssueWorkStatus.init(rawValue:))
            if status != nil, resolved == nil {
                return rejection("unknown issue status \(status ?? "")")
            }
            await setIssueStatus(resolved, for: id)

        case .setLabel(let id, let label):
            await setLabel(label, for: id)

        case .setDisabled(let id, let disabled):
            await setReviewDisabled(disabled, for: id)

        case .removeItem(let id):
            if let refusal = GatewayProjection.removalRefusal(localChanges: worktreeLocalChanges[id] ?? 0) {
                return rejection(refusal)
            }
            await removeReview(id: id)
        }

        // `AppModel` reports failure by setting `errorMessage` rather than throwing, so the
        // gateway reads it back to decide whether the command actually worked.
        if let error = errorMessage {
            return rejection(error)
        }
        return GatewayCommandResult(status: .accepted, snapshot: snapshot())
    }

    private func rejection(_ message: String) -> GatewayCommandResult {
        GatewayCommandResult(status: .rejected, message: message, snapshot: snapshot())
    }
}

extension AppModel {
    func gatewayAgent(for work: WorkItem) -> GatewayAgent? {
        let kind = work.effectiveAgent(default: settings.defaultAgent)
        guard let status = claudeStatuses[work.id] else { return nil }

        let elapsed = work.agentRunStartedAt.map { Int(Date().timeIntervalSince($0)) }
        let usage = usageToShow(for: work)

        return GatewayAgent(
            kind: kind.displayName,
            status: gatewayStatusName(status),
            verdict: gatewayVerdict(status),
            elapsedSeconds: elapsed,
            usedPercent: usage?.displayPercent
        )
    }

    private func gatewayStatusName(_ status: AgentStatus) -> String {
        switch status {
        case .starting: return "starting"
        case .working: return "working"
        case .awaitingInput: return "awaiting input"
        case .idle: return "idle"
        case .limited: return "limited"
        case .ready: return "finished"
        case .failed: return "failed"
        }
    }

    private func gatewayVerdict(_ status: AgentStatus) -> String? {
        switch status {
        case .awaitingInput(_, let snippet), .idle(_, let snippet):
            return snippet
        case .limited(_, let message):
            return message
        case .failed(let reason):
            return reason
        case .starting, .working, .ready:
            return nil
        }
    }

    func gatewayIssueStatus(for work: WorkItem) -> String? {
        guard work.category(myLogin: currentLogin) == .issue else { return nil }
        return resolveIssueStatus(
            manual: work.manualIssueStatus,
            prState: work.prState,
            claudeReviewedAt: work.claudeReviewedAt,
            claudeWorking: claudeStatuses[work.id] == .working
        ).displayName
    }

    /// Reproduces the sidebar badge line from `App/ContentView.swift`, carrying the same
    /// text and the same help sentence. The phone has no hover, so the help text is what the
    /// detail screen shows under each chip.
    func gatewayBadges(for work: WorkItem) -> [GatewayBadge] {
        var badges: [GatewayBadge] = []
        let agent = work.effectiveAgent(default: settings.defaultAgent).displayName

        if work.category(myLogin: currentLogin) == .issue {
            if let status = gatewayIssueStatus(for: work) {
                badges.append(
                    GatewayBadge(text: status, tone: issueStatusTone(status), help: "Issue status: \(status)")
                )
            }
        } else {
            switch work.sidebarStatus(myLogin: currentLogin) {
            case .merged:
                badges.append(GatewayBadge(text: "Merged", tone: .blue, help: "The PR is merged"))
            case .closed:
                badges.append(GatewayBadge(text: "Closed", tone: .red, help: "The PR is closed without merging"))
            case .approved:
                badges.append(GatewayBadge(text: "Approved", tone: .green, help: "You approved this PR"))
            case .new:
                badges.append(GatewayBadge(text: "New", tone: .orange, help: "You have not reviewed this PR yet"))
            case .reviewed:
                badges.append(GatewayBadge(text: "Reviewed", tone: .blue, help: "You commented or requested changes"))
            case .draft:
                badges.append(GatewayBadge(text: "Draft", tone: .grey, help: "The PR is still a draft"))
            case .open:
                break
            }

            if work.awaitsMyResponse(myLogin: currentLogin) {
                badges.append(
                    GatewayBadge(
                        text: "Agent",
                        tone: .orange,
                        help: "\(agent) finished a turn that you have not answered."
                    )
                )
            }

            if queuedReviewIDs.contains(work.id) {
                badges.append(
                    GatewayBadge(text: "Queued", tone: .grey, help: "Waiting for a free agent session slot")
                )
            }
        }

        if let status = prStatuses[work.id] {
            badges.append(contentsOf: ciBadges(status))
            badges.append(contentsOf: approvalBadges(work, status))

            if status.mergeState == .conflict {
                badges.append(
                    GatewayBadge(
                        text: "Conflict",
                        tone: .red,
                        help: "The merge into \(work.baseBranch) has conflicts. Resolve them by hand."
                    )
                )
            }
            if status.isBehind {
                badges.append(
                    GatewayBadge(
                        text: "Rebase",
                        tone: .orange,
                        help: "The branch is behind \(work.baseBranch) and the repo wants it current"
                    )
                )
            }
            if status.readiness == .changesRequested {
                badges.append(GatewayBadge(text: "changes", tone: .red, help: "A reviewer requested changes"))
            }
            if status.unresolvedThreads > 0,
               [.myPR, .task].contains(work.category(myLogin: currentLogin)) {
                let plural = status.unresolvedThreads == 1
                badges.append(
                    GatewayBadge(
                        text: "\(status.unresolvedThreads) thread\(plural ? "" : "s")",
                        tone: .blue,
                        help: "\(status.unresolvedThreads) review thread\(plural ? " is" : "s are") unresolved"
                    )
                )
            }
            if status.isReadyToMerge(prState: work.prState) {
                badges.append(
                    GatewayBadge(
                        text: "Ready",
                        tone: .green,
                        help: "The PR merges cleanly and passes every branch protection rule"
                    )
                )
            }
            if hasUnseenAuthorUpdate(work) {
                badges.append(
                    GatewayBadge(
                        text: "Author",
                        tone: .blue,
                        help: "\(work.author ?? "The author") pushed or replied since your last review."
                    )
                )
            }
        }

        if let message = work.agentLimitMessage {
            badges.append(GatewayBadge(text: "Limit", tone: .red, help: "\(agent) stopped: \(message)."))
        }

        if let usage = usageToShow(for: work), usage.hasReached(settings.usageWarningPercent) {
            badges.append(
                GatewayBadge(
                    text: "\(usage.displayPercent)%",
                    tone: usage.displayPercent >= 99 ? .red : .orange,
                    help: gatewayUsageHelp(usage, for: work)
                )
            )
        }

        if let changes = worktreeLocalChanges[work.id], changes > 0 {
            badges.append(
                GatewayBadge(
                    text: "Dirty",
                    tone: .grey,
                    help: "\(changes) local change\(changes == 1 ? "" : "s") in this review worktree, "
                        + "so it was not refreshed to the PR head."
                )
            )
        }

        if let push = pushability[work.id] {
            if push.ahead > 0 {
                badges.append(
                    GatewayBadge(text: "↑\(push.ahead)", tone: .green, help: "\(push.ahead) commit(s) to push")
                )
            }
            if push.behind > 0 {
                badges.append(
                    GatewayBadge(text: "↓\(push.behind)", tone: .orange, help: "\(push.behind) commit(s) to pull")
                )
            }
        }

        return badges
    }

    private func ciBadges(_ status: PRStatus) -> [GatewayBadge] {
        switch status.ci {
        case .passing: return [GatewayBadge(text: "✓ CI", tone: .green, help: "CI is passing")]
        case .failing: return [GatewayBadge(text: "✗ CI", tone: .red, help: "CI is failing")]
        case .pending: return [GatewayBadge(text: "◷ CI", tone: .orange, help: "CI is still running")]
        case .none: return []
        }
    }

    /// Approvals against the requirement, when the app could read one. A short count is
    /// amber because it is the reason a PR sits blocked; a met one is green. Without a known
    /// requirement the badge falls back to the plain count and claims nothing about the merge.
    private func approvalBadges(_ work: WorkItem, _ status: PRStatus) -> [GatewayBadge] {
        let rules = gatewayMergeRules(for: work)

        if let required = rules.requiredApprovals {
            let short = rules.isApprovalCountShort(status.approvalCount)
            return [
                GatewayBadge(
                    text: "\(status.approvalCount)/\(required) ✓",
                    tone: short ? .orange : .green,
                    help: short
                        ? "\(status.approvalCount) of the \(required) approvals \(work.baseBranch) requires"
                        : "\(status.approvalCount) approvals — \(work.baseBranch) requires \(required)"
                )
            ]
        }

        guard status.approvalCount > 0 else { return [] }
        return [
            GatewayBadge(
                text: "\(status.approvalCount) ✓",
                tone: .green,
                help: "\(status.approvalCount) reviewer\(status.approvalCount == 1 ? "" : "s") approved this PR"
            )
        ]
    }

    private func gatewayMergeRules(for work: WorkItem) -> MergeRules {
        guard let ref = work.prRef else { return MergeRules() }
        let key = MergeRules.key(owner: ref.owner, repo: ref.repo, branch: work.baseBranch)
        return mergeRules[key] ?? MergeRules()
    }

    private func gatewayUsageHelp(_ usage: AgentUsage, for work: WorkItem) -> String {
        var parts = ["\(usage.agent.displayName) has spent \(usage.displayPercent)%"]

        if let window = usage.windowDescription {
            parts[0] += " of its \(window) allowance"
        } else {
            parts[0] += " of its allowance"
        }
        if let resetsAt = usage.resetsAt {
            parts.append("Resets \(resetsAt.formatted(date: .abbreviated, time: .shortened))")
        }
        if settings.failoverAgent != work.effectiveAgent(default: settings.defaultAgent) {
            parts.append("Hand it to \(settings.failoverAgent.displayName) before it stops")
        }

        return parts.joined(separator: ". ") + "."
    }

    /// The Mac uses six colours here. The wire format has five tones, so teal and purple
    /// fold into blue. Nothing depends on telling those two apart.
    private func issueStatusTone(_ displayName: String) -> GatewayBadgeTone {
        switch displayName {
        case IssueWorkStatus.new.displayName: return .orange
        case IssueWorkStatus.inReview.displayName: return .blue
        case IssueWorkStatus.reviewed.displayName: return .blue
        case IssueWorkStatus.onHold.displayName: return .grey
        case IssueWorkStatus.done.displayName: return .blue
        case IssueWorkStatus.closed.displayName: return .red
        default: return .grey
        }
    }
}
