import Foundation
import Observation
import PRPilotModels
import ReviewStore
import GitHubKit
import AgentKit
import CommandSupport
import WorktreeKit

public enum ClaudePaneState: Sendable, Equatable {
    case idle
    case preparingWorktree
    case worktreeFailed(String)
    case claudeUnavailable(String)
    case sessionLive
}

@MainActor
@Observable
public final class AppModel {
    public private(set) var reviews: [WorkItem] = []
    public var selection: String?
    public private(set) var errorMessage: String?
    public private(set) var isAdding = false
    public private(set) var diffStates: [String: DiffLoadState] = [:]
    public private(set) var registeredRepos: [RegisteredRepo] = []
    public private(set) var claudeSessions: [String: AgentSession] = [:]
    public private(set) var claudePaneState: [String: ClaudePaneState] = [:]
    /// Non-nil only while the app is quitting and waiting for agent processes to exit. The quit
    /// window observes this; `nil` means no shutdown is in flight.
    public private(set) var shutdown: ShutdownProgress?
    public private(set) var terminalIsDark: Bool = true
    /// The appearance each live session's `claude` process was launched under, so a
    /// background session can be relaunched on selection if it no longer matches.
    private var sessionLaunchedIsDark: [String: Bool] = [:]
    /// When each live session's process was launched, so the budget can let a genuinely
    /// starting session finish while still evicting one that went silent.
    private var sessionStartedAt: [String: Date] = [:]
    public private(set) var claudePrepLog: [String: [PrepLogEntry]] = [:]
    public private(set) var claudeStatuses: [String: AgentStatus] = [:]
    public private(set) var prStatuses: [String: PRStatus] = [:]
    /// What each base branch demands before it merges, keyed by `MergeRules.key`. Keyed by
    /// repository and branch rather than by item, because that is what the rules describe —
    /// twenty PRs onto one branch read it once.
    public private(set) var mergeRules: [String: MergeRules] = [:]
    private var mergeRulesReadAt: [String: Date] = [:]
    /// Items autoLoad wants reviewed that have no session yet, most recently opened first.
    public private(set) var queuedReviewIDs: [String] = []
    /// Items autoLoad has had its turn at this run: everything the drain started, and
    /// everything the session budget evicted. A session that goes away before the item earns
    /// its reviewed stamp would otherwise re-enter the queue at once, and the drain would
    /// restart it every tick for as long as the app runs — releasing another live session each
    /// time to make room. A deliberate restart clears the id again in `terminateAgentSession`.
    private var autoLoadSpentIDs: Set<String> = []

    public enum RebaseState: Sendable, Equatable {
        case conflicted([String])
        case failed(String)
    }
    public struct Pushability: Sendable, Equatable {
        public var canPush: Bool
        public var needsForce: Bool
        public var ahead: Int
        public var behind: Int
    }
    public private(set) var rebaseStates: [String: RebaseState] = [:]
    public private(set) var pushability: [String: Pushability] = [:]
    /// Local changes found in each item's worktree, by item id. Only recorded for review
    /// items: an editable worktree is the user's own branch, where edits are the point.
    public private(set) var worktreeLocalChanges: [String: Int] = [:]
    public private(set) var currentLogin: String?
    public private(set) var settings: Settings = .default
    public private(set) var discoveryWarnings: [String] = []
    public var diffMode: DiffMode { settings.diffMode }

    public var webPreloadHandler: ((WorkItem) -> Void)?

    private var transcriptWatchers: [String: TranscriptWatcher] = [:]
    /// Session id of the transcript each watcher is currently tailing. Not the same thing as
    /// the id the item launched with — see `SessionAdoption`.
    private var watchedSessionID: [String: String] = [:]
    private var claudePreparing: Set<String> = []
    private var lastEventAt: [String: Date] = [:]
    private var lastVerdictSnippet: [String: String] = [:]
    private var lastEventWasTurnCompletion: [String: Bool] = [:]
    /// The limit message from the newest transcript event, when that event was a limit stop.
    private var limitMessageForSession: [String: String] = [:]
    /// Tail of the serialised item-edit chain. See `enqueueItemEdit`.
    private var pendingItemEdits: Task<Void, Never>?
    /// Latest allowance reading per session, ahead of what is persisted on the item.
    private var agentUsage: [String: AgentUsage] = [:]
    /// Sessions already warned about the current window, so one crossing fires one alert.
    private var warnedUsageForSession: Set<String> = []
    /// Sessions already notified about their current block, so one limit fires one alert.
    private var notifiedLimitForSession: Set<String> = []
    private var workflowPendingForSession: [String: Bool] = [:]
    private var notifiedAwaitingForSession: Set<String> = []
    private var lastRefreshedAt: [String: Date] = [:]
    private static let refreshBatchSize = 4
    /// Merge rules change when somebody edits a ruleset — rarely. A long life keeps the
    /// extra call off the poll path while still picking up a change the same day.
    static let mergeRulesTTL: TimeInterval = 6 * 3600
    private var tickTask: Task<Void, Never>?
    private var discoveryTask: Task<Void, Never>?
    private static let tickIntervalNanoseconds: UInt64 = 5_000_000_000

    private let store: ReviewStore
    private let client: GitHubClient
    private let diffLoader: DiffLoading
    private let worktreeProvider: WorktreeProviding
    private let cloneRegistrar: CloneRegistering
    private let worktreeOps: WorktreeManaging
    private let claudePath: String
    private let notificationPoster: NotificationPosting
    private let statusReader: AgentStatusReader
    private let commandRunner: CommandRunner
    /// Resolved executable path per agent. Resolution shells out to a login shell, so the
    /// result is cached for the app's lifetime.
    private var resolvedAgentPaths: [AgentKind: String] = [:]

    public init(
        store: ReviewStore,
        client: GitHubClient,
        diffLoader: DiffLoading,
        worktreeProvider: WorktreeProviding,
        cloneRegistrar: CloneRegistering,
        worktreeOps: WorktreeManaging,
        claudePath: String,
        notificationPoster: NotificationPosting,
        statusReader: AgentStatusReader = AgentStatusReader(),
        commandRunner: CommandRunner = ProcessCommandRunner()
    ) {
        self.store = store
        self.client = client
        self.diffLoader = diffLoader
        self.worktreeProvider = worktreeProvider
        self.cloneRegistrar = cloneRegistrar
        self.worktreeOps = worktreeOps
        self.claudePath = claudePath
        self.notificationPoster = notificationPoster
        self.statusReader = statusReader
        self.commandRunner = commandRunner
    }

    public func load() async {
        reviews = await store.allItems()
        registeredRepos = await store.allRepos()
        settings = await store.settings()
        switch settings.appearance {
        case .light: terminalIsDark = false
        case .dark: terminalIsDark = true
        case .system: break   // resolved by ContentView's colorScheme observer
        }
        if currentLogin == nil {
            currentLogin = try? await client.fetchCurrentLogin()
        }
        if selection == nil {
            selection = reviews
                .sorted { (a, b) in
                    (a.lastOpenedAt ?? a.addedAt) > (b.lastOpenedAt ?? b.addedAt)
                }
                .first?.id
        }
        startTickTimerIfNeeded()
        recomputeReviewQueue()
    }

    private func startTickTimerIfNeeded() {
        guard tickTask == nil else { return }
        tickTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.tickIntervalNanoseconds)
                // Statuses first, so the drain sees a session that has just finished.
                self.tickAllActiveStatuses()
                await self.drainSessionQueue()
            }
        }
    }

    private func tickAllActiveStatuses() {
        let now = Date()
        for id in claudeSessions.keys {
            recomputeStatus(for: id, now: now)
        }
    }

    public func startDiscoveryPolling() {
        guard discoveryTask == nil else { return }
        discoveryTask = Task { @MainActor in
            await self.discoverNow()
            await self.refreshReviewStates()
            while !Task.isCancelled {
                let intervalNs = UInt64(self.settings.pollIntervalSeconds) * 1_000_000_000
                try? await Task.sleep(nanoseconds: intervalNs)
                await self.discoverNow()
                await self.refreshReviewStates()
            }
        }
    }

    func discoverNow() async {
        var hitsByID: [String: DiscoveryHit] = [:]
        var anyQuerySucceeded = false
        var warnings: [String] = []

        let groups: [(enabled: Bool, queries: [DiscoveryQuery])] = [
            (settings.reviewRequestsEnabled, settings.reviewRequestQueries),
            (settings.myPRsEnabled, settings.myPRQueries),
        ]
        for group in groups where group.enabled {
            for query in group.queries {
                let text = query.text.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                guard query.isScoped || query.allowUnscoped else {
                    warnings.append("Skipped \"\(text)\" — not scoped to you, an org, or a repo. Add a qualifier (author:/org:/repo:/…) or enable \"run anyway\".")
                    continue
                }
                let results: [DiscoveryHit]
                do {
                    results = try await client.searchPRs(query: text)
                } catch {
                    // Swallowing this hid rate limits and auth failures: no new PRs
                    // appeared and nothing said why.
                    warnings.append("\"\(text)\" failed — \(Self.searchFailureReason(error))")
                    continue
                }
                anyQuerySucceeded = true
                if results.count >= 100 {
                    warnings.append("\"\(text)\" returned 100+ results (too broad) — refine it. Those results were not added.")
                    continue
                }
                for hit in results {
                    hitsByID[hit.id] = hit
                }
            }
        }
        var issueHitsByID: [String: IssueHit] = [:]
        var anyIssueQuerySucceeded = false
        if settings.issuesEnabled {
            for query in settings.issueQueries {
                let text = query.text.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                guard query.isScoped || query.allowUnscoped else {
                    warnings.append("Skipped \"\(text)\" — not scoped to you, an org, or a repo. Add a qualifier (author:/org:/repo:/…) or enable \"run anyway\".")
                    continue
                }
                let results: [IssueHit]
                do {
                    results = try await client.searchIssues(query: text)
                } catch {
                    warnings.append("\"\(text)\" failed — \(Self.searchFailureReason(error))")
                    continue
                }
                anyIssueQuerySucceeded = true
                if results.count >= 100 {
                    warnings.append("\"\(text)\" returned 100+ results (too broad) — refine it. Those results were not added.")
                    continue
                }
                for hit in results {
                    issueHitsByID[hit.id] = hit
                }
            }
        }
        discoveryWarnings = warnings
        await mergeDiscoveryHits(Array(hitsByID.values))
        if anyQuerySucceeded {
            await pruneStaleDiscoveredReviews(currentHitIDs: Set(hitsByID.keys))
        }
        await mergeDiscoveredIssues(Array(issueHitsByID.values))
        if anyIssueQuerySucceeded {
            await pruneStaleDiscoveredIssues(currentIssueIDs: Set(issueHitsByID.keys))
        }
    }

    /// `gh`'s own stderr is the useful part of a failed search (rate limit, auth, network),
    /// so prefer it over the Swift error description.
    private static func searchFailureReason(_ error: Error) -> String {
        guard case GitHubError.commandFailed(_, let message) = error else {
            return String(describing: error)
        }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstLine = trimmed.split(separator: "\n").first, !firstLine.isEmpty else {
            return String(describing: error)
        }
        return String(firstLine.prefix(200))
    }

    private func pruneStaleDiscoveredReviews(currentHitIDs: Set<String>) async {
        let staleIDs = reviews.compactMap { item -> String? in
            guard item.origin == .discovered else { return nil }
            guard item.prState == .closed || item.prState == .merged else { return nil }
            guard let key = prKey(item), !currentHitIDs.contains(key) else { return nil }
            return item.id
        }
        for id in staleIDs {
            do { try await store.removeItem(id: id) } catch { continue }
        }
        if !staleIDs.isEmpty {
            reviews = await store.allItems()
        }
    }

    private func prKey(_ item: WorkItem) -> String? {
        guard let r = item.prRef else { return nil }
        return "\(r.owner)/\(r.repo)#\(r.number)"
    }

    private func issueKey(_ item: WorkItem) -> String? {
        guard let r = item.issueRef else { return nil }
        return "\(r.owner)/\(r.repo)/issues/\(r.number)"
    }

    private func issueAutoStart(_ item: WorkItem) {
        guard !item.disabled else { return }
        Task { await ensureAgentSession(for: item) }
        webPreloadHandler?(item)
    }

    private func mergeDiscoveredIssues(_ hits: [IssueHit]) async {
        let existingByKey = Dictionary(
            reviews.compactMap { item in issueKey(item).map { ($0, item) } },
            uniquingKeysWith: { a, _ in a }
        )
        for hit in hits {
            if let existing = existingByKey[hit.id] {
                var updated = existing
                updated.title = hit.title
                updated.prState = GitHubClient.mapIssueState(state: hit.state)
                if existing.origin == .added { updated.origin = .both }
                try? await store.upsertItem(updated)
            } else {
                guard let fresh = try? await client.fetchIssue(for: hit.locator, origin: .discovered) else { continue }
                try? await store.upsertItem(fresh)
                issueAutoStart(fresh)
            }
        }
        reviews = await store.allItems()
    }

    private func pruneStaleDiscoveredIssues(currentIssueIDs: Set<String>) async {
        let staleIDs = reviews.compactMap { item -> String? in
            guard item.origin == .discovered, item.issueRef != nil else { return nil }
            guard item.prState == .closed else { return nil }
            guard let key = issueKey(item), !currentIssueIDs.contains(key) else { return nil }
            return item.id
        }
        for id in staleIDs {
            do { try await store.removeItem(id: id) } catch { continue }
        }
        if !staleIDs.isEmpty {
            reviews = await store.allItems()
        }
    }

    private func mergeDiscoveryHits(_ hits: [DiscoveryHit]) async {
        let existingByPRKey = Dictionary(
            reviews.compactMap { item in prKey(item).map { ($0, item) } },
            uniquingKeysWith: { a, _ in a }
        )
        for hit in hits {
            if let existing = existingByPRKey[hit.id] {
                var updated = existing
                updated.title = hit.title
                updated.prState = GitHubClient.mapDiscoveryState(state: hit.state, isDraft: hit.isDraft)
                if existing.origin == .added { updated.origin = .both }
                try? await store.upsertItem(updated)
            } else {
                guard let fresh = try? await client.fetchReview(for: hit.ref, origin: .discovered) else { continue }
                if let task = reviews.first(where: {
                    $0.prRef == nil
                    && $0.repoKey == fresh.repoKey
                    && $0.headBranch != nil
                    && $0.headBranch == fresh.headBranch
                }) {
                    var graduated = task
                    graduated.prRef = fresh.prRef
                    graduated.prState = fresh.prState
                    graduated.title = fresh.title
                    graduated.baseBranch = fresh.baseBranch
                    graduated.origin = .both
                    try? await store.upsertItem(graduated)
                } else {
                    try? await store.upsertItem(fresh)
                    autoLoadIfEnabled(fresh)
                }
            }
        }
        reviews = await store.allItems()
    }

    public func addPR(urlString: String) async {
        isAdding = true
        defer { isAdding = false }
        do {
            let ref = try PRLocator.parse(urlString)
            let review = try await client.fetchReview(for: ref)
            try await store.upsertItem(review)
            reviews = await store.allItems()
            selection = review.id
            errorMessage = nil
            prefetch(for: review)
            autoLoadIfEnabled(review)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func addIssue(urlString: String) async {
        isAdding = true
        defer { isAdding = false }
        do {
            let loc = try IssueLocator.parse(urlString)
            let item = try await client.fetchIssue(for: loc)
            try await store.upsertItem(item)
            reviews = await store.allItems()
            selection = item.id
            errorMessage = nil
            prefetch(for: item)
            webPreloadHandler?(item)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func registeredClonePath(for review: WorkItem) -> String? {
        let identity = "github.com/\(review.owner)/\(review.repo)"
        return registeredRepos.first { $0.remoteIdentity == identity }?.localClonePath
    }

    public func registeredDefaultBase(for repoKey: String) -> String? {
        registeredRepos.first { $0.remoteIdentity == repoKey }?.defaultBase
    }

    public func createTask(repoKey: String, branch: String) async {
        let trimmedBranch = branch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBranch.isEmpty else {
            errorMessage = "Branch name is required."
            return
        }
        guard BranchName.isValid(trimmedBranch) else {
            errorMessage = "“\(trimmedBranch)” is not a valid branch name (no spaces or ~^:?*[\\, no .. or leading/trailing / or .)."
            return
        }
        guard registeredRepos.contains(where: { $0.remoteIdentity == repoKey }) else {
            errorMessage = "Pick a registered repository."
            return
        }
        let base = registeredDefaultBase(for: repoKey) ?? "main"
        let task = WorkItem(
            title: trimmedBranch,
            repoKey: repoKey,
            baseBranch: base,
            headBranch: trimmedBranch,
            prRef: nil,
            prState: nil,
            origin: .added,
            addedAt: Date()
        )
        do {
            try await store.upsertItem(task)
            reviews = await store.allItems()
            selection = task.id
            errorMessage = nil
            await ensureAgentSession(for: task)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func registerClone(for review: WorkItem, localPath: String) async {
        do {
            try await cloneRegistrar.validate(localPath: localPath, expectedOwner: review.owner, expectedRepo: review.repo)
            let identity = "github.com/\(review.owner)/\(review.repo)"
            let base = (try? await client.fetchDefaultBase(owner: review.owner, repo: review.repo)) ?? review.baseBranch
            let entry = RegisteredRepo(remoteIdentity: identity, localClonePath: localPath, defaultBase: base)
            try await store.upsert(entry)
            registeredRepos = await store.allRepos()
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func registerLocalClone(at localPath: String) async {
        do {
            let identities = try await cloneRegistrar.detectRepositories(at: localPath)
            guard !identities.isEmpty else {
                errorMessage = "No GitHub repositories found in \(localPath)"
                return
            }
            for identity in identities {
                let parts = identity.split(separator: "/").map(String.init)
                let base: String
                if parts.count == 2 {
                    base = (try? await client.fetchDefaultBase(owner: parts[0], repo: parts[1])) ?? "main"
                } else {
                    base = "main"
                }
                let entry = RegisteredRepo(remoteIdentity: "github.com/\(identity)", localClonePath: localPath, defaultBase: base)
                try await store.upsert(entry)
            }
            registeredRepos = await store.allRepos()
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func removeRegisteredRepo(remoteIdentity: String) async {
        do {
            try await store.removeRepo(id: remoteIdentity)
            registeredRepos = await store.allRepos()
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func removeReview(id: String) async {
        guard let review = reviews.first(where: { $0.id == id }) else { return }
        terminateAgentSession(for: id)
        diffStates.removeValue(forKey: id)
        var preservedClonePath: String?
        if let worktreePath = review.worktreePath, FileManager.default.fileExists(atPath: worktreePath) {
            if isRegisteredClonePath(worktreePath) {
                preservedClonePath = worktreePath
            } else {
                try? FileManager.default.removeItem(atPath: worktreePath)
            }
        }
        do {
            try await store.removeItem(id: id)
            reviews = await store.allItems()
            if selection == id {
                selection = nil
            }
            if let preservedClonePath {
                errorMessage = "Kept \(preservedClonePath) — it is a registered repository clone, not a worktree, so it was not deleted."
            } else {
                errorMessage = nil
            }
        } catch {
            errorMessage = String(describing: error)
        }
    }

    private func isRegisteredClonePath(_ path: String) -> Bool {
        func standardized(_ p: String) -> String {
            URL(fileURLWithPath: p).standardizedFileURL.path
        }
        let target = standardized(path)
        for repo in registeredRepos {
            let clone = standardized(repo.localClonePath)
            if target == clone || clone.hasPrefix(target + "/") {
                return true
            }
        }
        return false
    }

    public func loadDiff(for review: WorkItem, force: Bool = false) async {
        if !force, case .loaded = diffStates[review.id] {
            return
        }
        diffStates[review.id] = .loading
        do {
            let result = try await diffLoader.loadDiff(for: review, registeredClonePath: registeredClonePath(for: review))
            if review.worktreePath != result.worktreePath {
                guard reviews.contains(where: { $0.id == review.id }) else {
                    diffStates[review.id] = .loaded(result.files)
                    return
                }
                var updated = review
                updated.worktreePath = result.worktreePath
                try await store.upsertItem(updated)
                reviews = await store.allItems()
            }
            diffStates[review.id] = .loaded(result.files)
        } catch {
            diffStates[review.id] = .failed(String(describing: error))
        }
    }

    static func notFoundMessage(for kind: AgentKind) -> String {
        let name = kind.defaultExecutableName
        switch kind {
        case .claudeCode:
            return """
            Couldn't find the `\(name)` command on your login PATH.

            Open a terminal and run `which \(name)`, then paste that path into Settings ▸ Tools ▸ \(name).
            """
        case .pi:
            // Resolution runs an interactive login shell, so it reads .zshrc and finds a
            // version-manager PATH. Reaching this message therefore means pi really is absent
            // from the shell, not merely hidden from a login shell.
            return """
            Couldn't find the `\(name)` command in your shell.

            Open a terminal and run `which \(name)`. If that prints nothing, pi is not installed
            for the node version your shell selects by default. Otherwise paste the path into
            Settings ▸ Claude ▸ Agent binaries ▸ \(name).
            """
        case .codex:
            // codex is a node script under a version manager, like pi, so the same reasoning
            // applies: an interactive login shell already read .zshrc.
            return """
            Couldn't find the `\(name)` command in your shell.

            Open a terminal and run `which \(name)`. If that prints nothing, codex is not
            installed for the node version your shell selects by default. Otherwise paste the
            path into Settings ▸ Claude ▸ Agent binaries ▸ \(name).
            """
        }
    }

    private func agentExecutable(for kind: AgentKind) async -> String? {
        if let override = explicitOverride(for: kind) {
            return override
        }
        if let cached = resolvedAgentPaths[kind] {
            return cached
        }
        let resolved = await LoginShellResolver.resolve(kind.defaultExecutableName, runner: commandRunner)
        if let resolved {
            resolvedAgentPaths[kind] = resolved
        }
        return resolved
    }

    private func explicitOverride(for kind: AgentKind) -> String? {
        let name = kind.defaultExecutableName
        let candidates: [String?]
        switch kind {
        case .claudeCode: candidates = [settings.claudePath, claudePath]
        case .pi: candidates = [settings.piPath]
        case .codex: candidates = [settings.codexPath]
        }
        for candidate in candidates {
            guard let candidate, !candidate.isEmpty, candidate != name else { continue }
            return (candidate as NSString).expandingTildeInPath
        }
        return nil
    }

    private func appendPrepLog(_ message: String, for id: String) {
        claudePrepLog[id, default: []].append(PrepLogEntry(date: Date(), message: message))
    }

    public func ensureAgentSession(for review: WorkItem, forceFresh: Bool = false) async {
        guard !review.disabled else { return }
        if claudeSessions[review.id] != nil {
            claudePaneState[review.id] = .sessionLive
            return
        }
        if claudePreparing.contains(review.id) { return }
        claudePreparing.insert(review.id)
        defer { claudePreparing.remove(review.id) }

        let kind = review.effectiveAgent(default: settings.defaultAgent)
        claudePaneState[review.id] = .preparingWorktree
        claudePrepLog[review.id] = []
        appendPrepLog("Locating \(kind.defaultExecutableName)…", for: review.id)
        guard let executable = await agentExecutable(for: kind) else {
            claudePaneState[review.id] = .claudeUnavailable(Self.notFoundMessage(for: kind))
            claudePrepLog[review.id] = nil
            return
        }
        let reviewID = review.id
        let progress: PrepProgress = { [weak self] message in
            await self?.appendPrepLog(message, for: reviewID)
        }
        let editable = review.category(myLogin: currentLogin) != .reviewRequest
        let ready: WorktreeReady
        do {
            ready = try await worktreeProvider.ensureWorktree(
                for: review,
                editable: editable,
                registeredClonePath: registeredClonePath(for: review),
                progress: progress
            )
        } catch {
            claudePaneState[review.id] = .worktreeFailed(String(describing: error))
            return
        }
        if claudeSessions[review.id] != nil {
            claudePaneState[review.id] = .sessionLive
            return
        }
        guard reviews.contains(where: { $0.id == review.id }) else { return }
        var updated = review
        updated.worktreePath = ready.worktreePath

        // forceFresh (used when clearing a session) starts a brand-new /review and never
        // resumes. Resuming an inferred session here is unsafe right after a clear: the
        // just-terminated process can flush a stub transcript back into the directory after
        // archiveTranscripts runs, so latestSessionID would pick that stub and `claude
        // --resume` exits with "No conversation found".
        let sessionID: String
        let resume: Bool
        if forceFresh {
            sessionID = UUID().uuidString.lowercased()
            resume = false
            appendPrepLog("Starting fresh session", for: review.id)
        } else if let existing = updated.sessionID(for: kind) {
            // Resume the persisted session only if its transcript still exists. If it was
            // archived or pruned, resuming would exit with "No conversation found", so fall
            // back to a fresh session instead.
            if AgentTranscriptPath.transcriptExists(for: kind, worktreePath: ready.worktreePath, sessionID: existing) {
                sessionID = existing
                resume = true
                appendPrepLog("Resuming session \(existing)", for: review.id)
            } else {
                sessionID = UUID().uuidString.lowercased()
                resume = false
                appendPrepLog("Previous session not found; starting fresh session", for: review.id)
            }
        } else if let latest = AgentTranscriptPath.latestSessionID(for: kind, worktreePath: ready.worktreePath) {
            sessionID = latest
            resume = true
            appendPrepLog("Resuming session \(latest)", for: review.id)
        } else {
            sessionID = UUID().uuidString.lowercased()
            resume = false
            appendPrepLog("Starting fresh session", for: review.id)
        }
        // A backend that cannot be told its session ID has not been told this one, so storing
        // it would name a conversation that does not exist — and the next open would find no
        // transcript for it and start fresh again, for ever. codex names its own session, and
        // `SessionAdoption` writes the real ID through as soon as the watcher attaches.
        // A resume is different: that ID came from the transcript, so it is real.
        if resume || AgentBackends.backend(for: kind).acceptsAssignedSessionID {
            updated.setSessionID(sessionID, for: kind)
        } else {
            // Clearing rather than leaving the old value behind. A stored ID whose transcript
            // has gone is dead: it cannot be resumed, and leaving it would have the item
            // claim a conversation that no longer exists until adoption happens to replace
            // it.
            updated.setSessionID(nil, for: kind)
        }
        // A fresh launch is the start of a new review or fix. A resume continues one that is
        // already timed, so it leaves the original moment alone.
        if !resume {
            updated.agentRunStartedAt = Date()
        }

        // The prompt is built from `updated`, so the note is only cleared after the spec below
        // has been given it. A resume sends no prompt at all, so the note stays pending for
        // whichever fresh launch comes next.
        let handoverToClear = resume ? nil : updated.pendingHandoverPath
        let spec = AgentLaunchBuilder.build(
            settings: settings,
            review: updated,
            worktreePath: ready.worktreePath,
            kind: kind,
            resolvedExecutablePath: executable,
            sessionID: sessionID,
            resume: resume
        )
        if handoverToClear != nil {
            updated.pendingHandoverPath = nil
            appendPrepLog("Handover note passed to \(kind.displayName)", for: review.id)
        }
        if updated != review {
            try? await store.upsertItem(updated)
            reviews = await store.allItems()
        }
        let session = AgentSession(spec: spec)
        claudeSessions[review.id] = session
        claudePaneState[review.id] = .sessionLive
        session.applyAppearance(isDark: terminalIsDark)
        sessionLaunchedIsDark[review.id] = terminalIsDark
        sessionStartedAt[review.id] = Date()
        session.start()
        attachTranscriptWatcher(reviewID: review.id, worktreePath: ready.worktreePath, kind: kind)
        // The prep just tried to fast-forward this worktree. If local edits stopped it, the
        // row should say so rather than leaving the news in the preparation log.
        await refreshWorktreeCleanliness(for: review.id)
        recomputeStatus(for: review.id, now: Date())
        enforceSessionBudget()
        if editable {
            await refreshPushability(for: review.id)
        }
    }

    private func attachTranscriptWatcher(reviewID: String, worktreePath: String, kind: AgentKind) {
        if transcriptWatchers[reviewID] != nil { return }
        let dirs = AgentTranscriptPath.directoryURLs(for: kind, worktreePath: worktreePath)
        // The worktree is handed over so a backend that shares one directory across projects
        // — codex — tails this item's session rather than the newest file any project wrote.
        let watcher = TranscriptWatcher(transcriptDirs: dirs, kind: kind, worktreePath: worktreePath)
        watcher.start(
            onEvent: { [weak self] event in
                guard let self else { return }
                self.handleTranscriptEvent(
                    reviewID: reviewID,
                    at: event.date,
                    snippet: event.snippet,
                    turnCompleted: event.turnCompleted,
                    workflowPending: event.workflowPending,
                    limitMessage: event.limitMessage,
                    usage: event.usage
                )
            },
            onSessionFile: { [weak self] sessionID in
                self?.watchedSessionID[reviewID] = sessionID
            }
        )
        transcriptWatchers[reviewID] = watcher
    }

    func handleTranscriptEvent(
        reviewID: String,
        at date: Date,
        snippet: String?,
        turnCompleted: Bool = false,
        workflowPending: Bool = false,
        limitMessage: String? = nil,
        usage: AgentUsage? = nil
    ) {
        guard claudeSessions[reviewID] != nil else { return }
        let isNewer = lastEventAt[reviewID].map { $0 < date } ?? true
        if isNewer {
            lastEventAt[reviewID] = date
            lastEventWasTurnCompletion[reviewID] = turnCompleted
            limitMessageForSession[reviewID] = limitMessage
            // Any newer line proves the agent is running again, so the block is over and the
            // next one deserves its own alert.
            if limitMessage == nil {
                notifiedLimitForSession.remove(reviewID)
            }
            enqueueItemEdit { await self.recordAgentLimit(reviewID, message: limitMessage, at: date) }
        }
        if let usage {
            recordAgentUsage(usage, for: reviewID)
        }
        workflowPendingForSession[reviewID] = workflowPending
        if let snippet, !snippet.isEmpty {
            lastVerdictSnippet[reviewID] = snippet
        }
        // "Reviewed" means Claude actually completed a turn (stop_reason end_turn) — not
        // merely that the session went idle, which also happens when a review is
        // interrupted mid-task and later resumed.
        if turnCompleted {
            enqueueItemEdit { await self.markClaudeTurnCompleted(reviewID) }
        }
        adoptWatchedSessionIfMoved(reviewID: reviewID, eventDate: date)
        recomputeStatus(for: reviewID, now: Date())
    }

    /// Records the session the agent is actually writing, when that stops being the one the
    /// item launched with.
    ///
    /// Without this the item resumes its launch id forever. After a `/clear` that id names the
    /// conversation the user threw away; once the transcript is pruned it names nothing, and
    /// `ensureAgentSession` starts the review again from the beginning. `SessionAdoption` holds
    /// the rule and the guards that keep two items sharing a clone from taking each other's
    /// conversations.
    private func adoptWatchedSessionIfMoved(reviewID: String, eventDate: Date) {
        guard claudeSessions[reviewID] != nil else { return }
        guard var review = reviews.first(where: { $0.id == reviewID }) else { return }
        let kind = review.effectiveAgent(default: settings.defaultAgent)
        let othersIDs = Set(reviews.compactMap { other -> String? in
            guard other.id != reviewID else { return nil }
            return other.sessionID(for: kind)
        })
        let shared = review.worktreePath.map { path in
            claudeSessions.keys.contains { id in
                id != reviewID && reviews.first(where: { $0.id == id })?.worktreePath == path
            }
        } ?? false
        guard let adopted = SessionAdoption.adoptedSessionID(
            watched: watchedSessionID[reviewID],
            stored: review.sessionID(for: kind),
            eventDate: eventDate,
            sessionStartedAt: sessionStartedAt[reviewID],
            idsOwnedByOtherItems: othersIDs,
            transcriptDirectoryIsShared: shared
        ) else { return }

        enqueueItemEdit { await self.persistAdoptedSession(adopted, kind: kind, for: reviewID) }
    }

    /// Runs one item edit after every edit already queued.
    ///
    /// A single transcript line can start four separate writes to the same item: the limit
    /// badge, the turn-completion stamps, an adopted session ID and the usage reading. Each one
    /// reads the item, changes its own field and upserts the whole record, so two running
    /// concurrently means the later write puts the earlier one's field back as it was. Which
    /// field is lost depends on scheduling, so the symptom is a badge or a stamp that
    /// intermittently fails to stick.
    ///
    /// Re-reading inside each task narrows the window but does not close it: both can still
    /// read before either writes. Chaining them closes it — every edit sees the previous one's
    /// result.
    ///
    /// Ordering matters as much as atomicity. The events arrive in transcript order, and a
    /// limit cleared by a later line must not be re-applied by an earlier line's write landing
    /// second.
    func enqueueItemEdit(_ edit: @escaping @MainActor @Sendable () async -> Void) {
        let previous = pendingItemEdits
        pendingItemEdits = Task { @MainActor in
            await previous?.value
            await edit()
        }
    }

    /// Waits for every queued item edit to finish.
    ///
    /// Tests need this: the alternative is sleeping and hoping, which is exactly the race the
    /// chain exists to remove.
    public func waitForPendingItemEdits() async {
        await pendingItemEdits?.value
    }

    /// Re-reads the item inside the task rather than persisting the copy the caller held.
    ///
    /// `handleTranscriptEvent` can start a turn-completion write and this one from the same
    /// line. Writing a copy captured before that ran would put the stamps back as they were.
    private func persistAdoptedSession(_ sessionID: String, kind: AgentKind, for reviewID: String) async {
        guard var review = reviews.first(where: { $0.id == reviewID }) else { return }
        guard review.sessionID(for: kind) != sessionID else { return }
        review.setSessionID(sessionID, for: kind)
        do {
            try await store.upsertItem(review)
            reviews = await store.allItems()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    func setWatchedSessionIDForTesting(_ sessionID: String, for reviewID: String) {
        watchedSessionID[reviewID] = sessionID
    }

    func recomputeStatus(for reviewID: String, now: Date = Date()) {
        let processState = claudeSessions[reviewID]?.state ?? .starting
        let newStatus = statusReader.status(
            processState: processState,
            lastEventAt: lastEventAt[reviewID],
            lastVerdictSnippet: lastVerdictSnippet[reviewID],
            now: now,
            lastEventWasTurnCompletion: lastEventWasTurnCompletion[reviewID] ?? false,
            workflowPending: workflowPendingForSession[reviewID] ?? false,
            limitMessage: limitMessageForSession[reviewID]
        )
        let oldStatus = claudeStatuses[reviewID]
        claudeStatuses[reviewID] = newStatus
        if case .working = newStatus {
            notifiedAwaitingForSession.remove(reviewID)
        }
        if shouldFireReviewReady(old: oldStatus, new: newStatus, reviewID: reviewID) {
            notifiedAwaitingForSession.insert(reviewID)
            postReviewReadyNotification(for: reviewID, status: newStatus)
        }
        if case .limited(_, let message) = newStatus, !notifiedLimitForSession.contains(reviewID) {
            notifiedLimitForSession.insert(reviewID)
            postAgentLimitNotification(for: reviewID, message: message)
            // Automatic failover fires once per block, off the same guard as the notification,
            // so a status recomputed every second cannot switch the item repeatedly.
            if settings.agentFailover == .automatic,
               let review = reviews.first(where: { $0.id == reviewID }),
               settings.failoverAgent != review.effectiveAgent(default: settings.defaultAgent) {
                Task { await self.handOverToFailoverAgent(for: reviewID) }
            }
        }
    }

    /// The agent stopped for want of allowance, and nothing else in the app can tell. Its
    /// process stays alive and writes no error, so without an alert the work simply stops.
    private func postAgentLimitNotification(for reviewID: String, message: String) {
        guard let review = reviews.first(where: { $0.id == reviewID }) else { return }
        let title = "Agent blocked · #\(review.displayNumber.map(String.init) ?? "?")"
        let poster = notificationPoster
        Task {
            await poster.postReviewReady(reviewID: reviewID, title: title, body: message)
        }
    }

    // MARK: - Usage

    /// Stores the latest allowance reading and warns the first time it crosses the threshold.
    ///
    /// Every codex turn reports usage, so this runs constantly. Only a reading that actually
    /// moves the displayed figure is written through, because a percentage that has not
    /// changed to a whole number is not worth a store write per turn.
    func recordAgentUsage(_ usage: AgentUsage, for reviewID: String) {
        let previous = agentUsage[reviewID]
        agentUsage[reviewID] = usage
        let threshold = settings.usageWarningPercent
        // Fires on the crossing, not on the state. Without the previous reading a session
        // sitting at 95% would alert on every turn it took.
        let crossed = usage.hasReached(threshold) && !(previous?.hasReached(threshold) ?? false)
        if crossed, !warnedUsageForSession.contains(reviewID) {
            warnedUsageForSession.insert(reviewID)
            postUsageWarning(for: reviewID, usage: usage)
        }
        // A window that has reset earns a fresh warning.
        if !usage.hasReached(threshold) {
            warnedUsageForSession.remove(reviewID)
        }
        if previous?.displayPercent != usage.displayPercent || previous?.resetsAt != usage.resetsAt {
            enqueueItemEdit { await self.persistAgentUsage(usage, for: reviewID) }
        }
    }

    private func persistAgentUsage(_ usage: AgentUsage, for reviewID: String) async {
        guard var review = reviews.first(where: { $0.id == reviewID }) else { return }
        guard review.agentUsage != usage else { return }
        review.agentUsage = usage
        do {
            try await store.upsertItem(review)
            reviews = await store.allItems()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// The reading to show for an item, or nil when there is none worth showing.
    ///
    /// A stale figure is worse than none: it invites the user to hand work over on the strength
    /// of a number whose window has since reset.
    public func usageToShow(for review: WorkItem, now: Date = Date()) -> AgentUsage? {
        let usage = agentUsage[review.id] ?? review.agentUsage
        guard let usage, !usage.isStale(now: now) else { return nil }
        return usage
    }

    /// Warns while the agent is still working, which is the whole point — a limit stop is only
    /// discovered after the work has already stopped.
    private func postUsageWarning(for reviewID: String, usage: AgentUsage) {
        guard let review = reviews.first(where: { $0.id == reviewID }) else { return }
        let title = "\(usage.agent.displayName) at \(usage.displayPercent)% · #\(review.displayNumber.map(String.init) ?? "?")"
        var body = "\(usage.displayPercent)% of the"
        if let window = usage.windowDescription {
            body += " \(window)"
        }
        body += " allowance is spent."
        if let resetsAt = usage.resetsAt {
            body += " It resets \(Self.resetDescription.string(from: resetsAt))."
        }
        if settings.failoverAgent != review.effectiveAgent(default: settings.defaultAgent) {
            body += " Hand the item to \(settings.failoverAgent.displayName) before it stops."
        }
        let poster = notificationPoster
        Task {
            await poster.postReviewReady(reviewID: reviewID, title: title, body: body)
        }
    }

    private static let resetDescription: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    private func shouldFireReviewReady(old: AgentStatus?, new: AgentStatus, reviewID: String) -> Bool {
        guard !notifiedAwaitingForSession.contains(reviewID) else { return false }
        guard case .awaitingInput = new else { return false }
        return true
    }

    private func postReviewReadyNotification(for reviewID: String, status: AgentStatus) {
        guard let review = reviews.first(where: { $0.id == reviewID }) else { return }
        var snippet: String? = nil
        if case .awaitingInput(_, let s) = status { snippet = s }
        let title = "Review ready · #\(review.number.map(String.init) ?? "?")"
        let body = snippet ?? "\(review.owner)/\(review.repo) · \(review.author ?? "")"
        let poster = notificationPoster
        Task {
            await poster.postReviewReady(reviewID: reviewID, title: title, body: body)
        }
    }

    func terminateAgentSession(for id: String) {
        claudeSessions[id]?.terminate()
        claudeSessions.removeValue(forKey: id)
        autoLoadSpentIDs.remove(id)
        claudePreparing.remove(id)
        claudePaneState.removeValue(forKey: id)
        transcriptWatchers[id]?.stop()
        transcriptWatchers.removeValue(forKey: id)
        watchedSessionID.removeValue(forKey: id)
        claudeStatuses.removeValue(forKey: id)
        sessionLaunchedIsDark.removeValue(forKey: id)
        sessionStartedAt.removeValue(forKey: id)
        prStatuses.removeValue(forKey: id)
        rebaseStates.removeValue(forKey: id)
        pushability.removeValue(forKey: id)
        worktreeLocalChanges.removeValue(forKey: id)
        lastRefreshedAt.removeValue(forKey: id)
        lastEventAt.removeValue(forKey: id)
        lastVerdictSnippet.removeValue(forKey: id)
        lastEventWasTurnCompletion.removeValue(forKey: id)
        // Only the live tracking goes. The persisted limit badge is the point: it must
        // outlive the session so the user still learns why the work stopped. The persisted
        // usage reading survives for the same reason.
        limitMessageForSession.removeValue(forKey: id)
        agentUsage.removeValue(forKey: id)
        notifiedLimitForSession.remove(id)
        workflowPendingForSession.removeValue(forKey: id)
        notifiedAwaitingForSession.remove(id)
    }

    /// Shuts a session down to reclaim its process, and nothing more. Unlike
    /// `terminateAgentSession`, this keeps `prStatuses`, `rebaseStates` and `pushability`,
    /// which describe the PR on GitHub rather than the session, and keeps the persisted
    /// `claudeSessionID` so the next open resumes instead of starting over.
    private func evictAgentSession(for id: String) {
        // Eviction spends the item's autoLoad turn. Without this the drain reads the evicted
        // item as queued work and starts it again on the next tick, which costs a second live
        // session its slot.
        autoLoadSpentIDs.insert(id)
        claudeSessions[id]?.terminate()
        claudeSessions.removeValue(forKey: id)
        claudePreparing.remove(id)
        claudePaneState.removeValue(forKey: id)
        transcriptWatchers[id]?.stop()
        transcriptWatchers.removeValue(forKey: id)
        watchedSessionID.removeValue(forKey: id)
        claudeStatuses.removeValue(forKey: id)
        sessionLaunchedIsDark.removeValue(forKey: id)
        sessionStartedAt.removeValue(forKey: id)
        lastEventAt.removeValue(forKey: id)
        lastVerdictSnippet.removeValue(forKey: id)
        lastEventWasTurnCompletion.removeValue(forKey: id)
        // Only the live tracking goes. The persisted limit badge is the point: it must
        // outlive the session so the user still learns why the work stopped. The persisted
        // usage reading survives for the same reason.
        limitMessageForSession.removeValue(forKey: id)
        agentUsage.removeValue(forKey: id)
        notifiedLimitForSession.remove(id)
        workflowPendingForSession.removeValue(forKey: id)
        notifiedAwaitingForSession.remove(id)
    }

    /// Drops sessions whose agent process has already exited. They hold a slot and a watcher
    /// for nothing, and freeing one is not a kill, so it is not gated on the cap.
    ///
    /// The selected item is spared: its pane shows the exit banner and its Restart button, and
    /// reaping the session would replace that with a fresh launch the user did not ask for.
    /// A background item has no banner to show — reopening it relaunches the agent anyway.
    func reapDeadSessions(now: Date = Date()) {
        let dead = SessionBudget.deadSessions(candidates: sessionCandidates(now: now))
        for id in dead where id != selection {
            evictAgentSession(for: id)
        }
    }

    private func sessionCandidates(now: Date) -> [SessionBudget.Candidate] {
        claudeSessions.keys.compactMap { id in
            guard let review = reviews.first(where: { $0.id == id }) else { return nil }
            return SessionBudget.Candidate(
                id: id,
                lastOpenedAt: review.lastOpenedAt ?? review.addedAt,
                status: claudeStatuses[id] ?? .starting,
                startedAt: sessionStartedAt[id] ?? now
            )
        }
    }

    func enforceSessionBudget(now: Date = Date()) {
        let candidates: [SessionBudget.Candidate] = claudeSessions.keys.compactMap { id in
            guard let review = reviews.first(where: { $0.id == id }) else { return nil }
            return SessionBudget.Candidate(
                id: id,
                lastOpenedAt: review.lastOpenedAt ?? review.addedAt,
                status: claudeStatuses[id] ?? .starting,
                startedAt: sessionStartedAt[id] ?? now
            )
        }
        let victims = SessionBudget.evictions(
            candidates: candidates,
            cap: settings.maxLiveAgentSessions,
            selectedID: selection,
            now: now,
            idleProtectionSeconds: idleProtectionSeconds
        )
        for id in victims {
            evictAgentSession(for: id)
        }
    }

    /// Keyed on `claudeReviewedAt` being nil, which is what makes the queue finite: the
    /// stamp survives a session ending, so a reviewed item leaves the queue for good. An item
    /// that already spent its autoLoad turn leaves the queue too, whether or not it earned the
    /// stamp, so a session that ends without one is not started again and again.
    /// Writes the limit through to the item, or clears it, so the badge survives an
    /// eviction, a quit, and the cap reclaiming the slot.
    func recordAgentLimit(_ id: String, message: String?, at date: Date) async {
        guard var review = reviews.first(where: { $0.id == id }) else { return }
        if let message {
            guard review.agentLimitedAt != date || review.agentLimitMessage != message else { return }
            review.agentLimitedAt = date
            review.agentLimitMessage = message
        } else {
            guard review.agentLimitedAt != nil || review.agentLimitMessage != nil else { return }
            review.agentLimitedAt = nil
            review.agentLimitMessage = nil
        }
        do {
            try await store.upsertItem(review)
            reviews = await store.allItems()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// Dismisses the Limit badge by hand, for a block the user has already dealt with.
    public func clearAgentLimit(for id: String) async {
        limitMessageForSession.removeValue(forKey: id)
        notifiedLimitForSession.remove(id)
        await recordAgentLimit(id, message: nil, at: Date())
        recomputeStatus(for: id)
    }

    func recomputeReviewQueue() {
        guard settings.autoLoad else {
            queuedReviewIDs = []
            return
        }
        queuedReviewIDs = reviews
            .filter { !$0.disabled }
            .filter { $0.claudeReviewedAt == nil }
            .filter { claudeSessions[$0.id] == nil }
            .filter { !autoLoadSpentIDs.contains($0.id) }
            .filter { review in
                guard let clonePath = registeredClonePath(for: review) else { return false }
                return FileManager.default.fileExists(atPath: clonePath)
            }
            .sorted { ($0.lastOpenedAt ?? $0.addedAt) > ($1.lastOpenedAt ?? $1.addedAt) }
            .map(\.id)
    }

    /// The `.idle` protection window, in seconds, from the user's setting.
    private var idleProtectionSeconds: TimeInterval {
        Double(max(settings.idleSessionProtectionMinutes, 0)) * 60
    }

    /// One step per call. Starting a session does real work, so pacing it keeps the launch
    /// path calm and lets a released slot settle before the next start.
    ///
    /// The budget runs first. It reclaims sessions that have gone quiet past the protection
    /// window, which is the only way a slot ever comes free without the user acting. The
    /// drain then fills whatever room that left — it never takes a slot from a live agent.
    func drainSessionQueue(now: Date = Date()) async {
        recomputeReviewQueue()
        // Reaping only serves the backlog, so it waits until there is a backlog. With nothing
        // queued a dead session costs only itself, and leaving it alone keeps the pane's exit
        // banner intact for an item the user may come back to.
        if !queuedReviewIDs.isEmpty {
            reapDeadSessions(now: now)
        }
        enforceSessionBudget(now: now)
        recomputeReviewQueue()
        let candidates: [SessionBudget.Candidate] = claudeSessions.keys.compactMap { id in
            guard let review = reviews.first(where: { $0.id == id }) else { return nil }
            return SessionBudget.Candidate(
                id: id,
                lastOpenedAt: review.lastOpenedAt ?? review.addedAt,
                status: claudeStatuses[id] ?? .starting,
                startedAt: sessionStartedAt[id] ?? now
            )
        }
        let step = SessionQueue.nextStep(
            queued: queuedReviewIDs,
            live: candidates,
            cap: settings.maxLiveAgentSessions,
            now: now
        )
        guard let start = step.start,
              let review = reviews.first(where: { $0.id == start }) else { return }
        autoLoadSpentIDs.insert(start)
        await ensureAgentSession(for: review)
        recomputeReviewQueue()
    }

    /// Backdates when a session's process started. A protection rule that compares the last
    /// transcript event against the process start needs a session older than the event, and a
    /// test cannot wait ten minutes for one.
    func setSessionStartedAtForTesting(_ date: Date, for id: String) {
        sessionStartedAt[id] = date
    }

    func setPRStatusForTesting(_ status: PRStatus, for id: String) {
        prStatuses[id] = status
    }

    func setCurrentLoginForTesting(_ login: String) {
        currentLogin = login
    }

    public func terminateAllAgentSessions() {
        tickTask?.cancel()
        tickTask = nil
        discoveryTask?.cancel()
        discoveryTask = nil
        for session in claudeSessions.values { session.terminate() }
        for watcher in transcriptWatchers.values { watcher.stop() }
        clearSessionState()
    }

    /// Drops everything keyed by session id. Shared by the fire-and-forget teardown and the
    /// awaited shutdown, so the two cannot drift apart as new per-session state is added.
    private func clearSessionState() {
        claudeSessions.removeAll()
        claudePaneState.removeAll()
        transcriptWatchers.removeAll()
        watchedSessionID.removeAll()
        claudeStatuses.removeAll()
        prStatuses.removeAll()
        rebaseStates.removeAll()
        pushability.removeAll()
        worktreeLocalChanges.removeAll()
        lastEventAt.removeAll()
        lastVerdictSnippet.removeAll()
        lastEventWasTurnCompletion.removeAll()
        limitMessageForSession.removeAll()
        agentUsage.removeAll()
        warnedUsageForSession.removeAll()
        notifiedLimitForSession.removeAll()
        workflowPendingForSession.removeAll()
        notifiedAwaitingForSession.removeAll()
    }

    /// True while any agent is running, so the quit path can skip the window when there is
    /// nothing to wait for.
    public var hasLiveAgentSessions: Bool { !claudeSessions.isEmpty }

    /// Publishes what the quit is about to wait for, and stops the background work that would
    /// otherwise start new sessions while the shutdown runs.
    ///
    /// Separate from `shutdownAgentSessions` so the quit window has its contents before the first
    /// suspension point. A window opened after the wait started would race it and could show an
    /// empty list while agents are still dying.
    @discardableResult
    public func beginShutdown() -> ShutdownProgress {
        if let shutdown { return shutdown }
        tickTask?.cancel()
        tickTask = nil
        discoveryTask?.cancel()
        discoveryTask = nil
        for watcher in transcriptWatchers.values { watcher.stop() }

        let progress = ShutdownProgress(titles: claudeSessions.keys.map { title(forSessionID: $0) })
        shutdown = progress
        return progress
    }

    /// Stops every agent and returns only once their processes are gone.
    ///
    /// `applicationWillTerminate` cannot do this: it is synchronous, and AppKit exits as soon as
    /// it returns, so any detached task is lost. The quit path calls this instead, holds the quit
    /// open with `.terminateLater`, and shows `shutdown` while it runs.
    ///
    /// Agents stop concurrently. Waiting for them one after another would multiply the timeout by
    /// the number of open sessions.
    public func shutdownAgentSessions() async {
        let progress = shutdown ?? beginShutdown()
        let running = claudeSessions.map { (id: $0.key, session: $0.value) }
        let titles = running.map { title(forSessionID: $0.id) }

        let stops = running.enumerated().map { offset, entry in
            let session = entry.session
            let title = titles[offset]
            return Task { @MainActor in
                await session.terminateAndWait()
                progress.markStopped(title)
            }
        }
        for stop in stops { await stop.value }

        clearSessionState()
    }

    /// The label the quit window shows for one agent. Falls back to the session id so a session
    /// whose work item has already gone still appears in the count.
    private func title(forSessionID id: String) -> String {
        reviews.first(where: { $0.id == id })?.title ?? id
    }

    public func prefetch(for review: WorkItem) {
        guard !review.disabled else { return }
        Task { await ensureAgentSession(for: review) }
    }

    private func autoLoadIfEnabled(_ review: WorkItem) {
        guard settings.autoLoad, !review.disabled else { return }
        Task { await ensureAgentSession(for: review) }
        webPreloadHandler?(review)
    }

    public func prewarmDiffs() {
        for review in reviews where !review.disabled {
            Task(priority: .background) { await loadDiff(for: review) }
        }
    }

    public func prewarmClaude() {
        Task(priority: .background) { [weak self] in
            await self?.prewarmClaudeAndWait()
        }
    }

    /// Warms the most recently opened items up to the session cap. Warming every item
    /// starts one `claude` process per item, which exhausts memory on a large work list.
    func prewarmClaudeAndWait() async {
        _ = await agentExecutable(for: settings.defaultAgent)
        let ordered = reviews
            .filter { !$0.disabled }
            .sorted { left, right in
                (left.lastOpenedAt ?? left.addedAt) > (right.lastOpenedAt ?? right.addedAt)
            }
        for review in ordered {
            if claudeSessions[review.id] != nil { continue }
            guard let clonePath = registeredClonePath(for: review),
                  FileManager.default.fileExists(atPath: clonePath) else { continue }
            if settings.autoLoad {
                // The cap check sits inside this branch on purpose. The other branch only
                // creates worktrees, which start no process, so the cap must not cut it short.
                if claudeSessions.count >= settings.maxLiveAgentSessions { continue }
                await ensureAgentSession(for: review)
            } else {
                let editable = review.category(myLogin: currentLogin) != .reviewRequest
                _ = try? await worktreeProvider.ensureWorktree(
                    for: review,
                    editable: editable,
                    registeredClonePath: clonePath
                )
            }
        }
    }

    public func selectedReview() -> WorkItem? {
        guard let selection else { return nil }
        return reviews.first { $0.id == selection }
    }

    public func dismissError() {
        errorMessage = nil
    }

    public func markReviewOpened(_ id: String) async {
        guard var review = reviews.first(where: { $0.id == id }) else { return }
        review.lastOpenedAt = Date()
        do {
            try await store.upsertItem(review)
            reviews = await store.allItems()
            enforceSessionBudget()
            await refreshReviewState(for: id)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// Discards the Claude session for a review and immediately starts a fresh one:
    /// terminates the live process/watcher, clears the persisted session id and the
    /// "reviewed" stamp, archives the prior transcripts, then relaunches a clean
    /// /review (no resume). Restarting here is what makes the open pane recover —
    /// ClaudePaneView only auto-triggers ensureAgentSession when review.id changes,
    /// so a cleared-but-not-restarted session would leave the pane stuck on the
    /// "Preparing worktree…" placeholder.
    /// Switches which agent drives an item.
    ///
    /// The live session goes away and the new agent starts, but neither agent's stored session
    /// ID or transcripts are touched. So flipping to pi and back resumes the Claude Code
    /// conversation where it stopped, and vice versa — which is the whole point of keeping a
    /// session ID per agent.
    public func setAgent(_ kind: AgentKind?, for id: String) async {
        guard var review = reviews.first(where: { $0.id == id }) else { return }
        let before = review.effectiveAgent(default: settings.defaultAgent)
        review.agent = kind
        let after = review.effectiveAgent(default: settings.defaultAgent)
        guard before != after || review.agent != kind else { return }

        terminateAgentSession(for: id)
        do {
            try await store.upsertItem(review)
            reviews = await store.allItems()
        } catch {
            errorMessage = String(describing: error)
            return
        }
        guard let refreshed = reviews.first(where: { $0.id == id }) else { return }
        await ensureAgentSession(for: refreshed)
    }

    // MARK: - Failover

    /// Whether this item can be handed to another agent right now.
    ///
    /// A limit is the only reason to offer it: any other stop is either the agent working or
    /// the agent waiting for the user, and neither wants a different agent. The target must
    /// also differ from the blocked agent — one account cannot rescue itself.
    public func canHandOver(_ review: WorkItem) -> Bool {
        guard settings.failoverAgent != review.effectiveAgent(default: settings.defaultAgent) else {
            return false
        }
        if case .limited = claudeStatuses[review.id] { return true }
        return review.agentLimitMessage != nil
    }

    /// Moves a blocked item to the failover agent, leaving a note behind for it to read.
    ///
    /// The note is rendered by PR Pilot, not by the blocked agent. That is the point: asking a
    /// blocked agent to summarise its own work costs exactly the allowance it has run out of.
    /// PR Pilot already tails the transcript, so it can write the note with no model call.
    ///
    /// The target starts a fresh session rather than resuming its own older conversation for
    /// this item. A resume sends no prompt, so the note would never be read — and an unrelated
    /// earlier thread is the wrong place to continue this work anyway. The old transcripts stay
    /// on disk untouched.
    @discardableResult
    public func handOverToFailoverAgent(for id: String) async -> Bool {
        guard var review = reviews.first(where: { $0.id == id }) else { return false }
        let from = review.effectiveAgent(default: settings.defaultAgent)
        let to = settings.failoverAgent
        guard from != to else { return false }
        guard let worktreePath = review.worktreePath else { return false }

        let reason = review.agentLimitMessage ?? limitMessage(forSession: id)
        let notePath = writeHandoverNote(
            for: review, from: from, to: to, reason: reason, worktreePath: worktreePath
        )

        terminateAgentSession(for: id)
        review.agent = to
        review.pendingHandoverPath = notePath
        // The badge described the agent that is no longer running this item. Leaving it would
        // have the new session look blocked from its first frame.
        review.agentLimitedAt = nil
        review.agentLimitMessage = nil
        do {
            try await store.upsertItem(review)
            reviews = await store.allItems()
        } catch {
            errorMessage = String(describing: error)
            return false
        }
        notifiedLimitForSession.remove(id)
        limitMessageForSession.removeValue(forKey: id)
        guard let refreshed = reviews.first(where: { $0.id == id }) else { return false }
        await ensureAgentSession(for: refreshed, forceFresh: true)
        return true
    }

    /// Writes the note into the worktree and returns its path, or nil when it cannot be written.
    ///
    /// A failure here does not stop the handover. The switch is still the right thing to do —
    /// the user simply loses the summary, and the new agent starts from the launch prompt.
    private func writeHandoverNote(
        for review: WorkItem,
        from: AgentKind,
        to: AgentKind,
        reason: String?,
        worktreePath: String
    ) -> String? {
        let transcript = HandoverNote.transcriptURL(
            for: from,
            worktreePath: worktreePath,
            sessionID: review.sessionID(for: from)
        )
        let entries = transcript.map { HandoverNote.entries(inTranscriptAt: $0, kind: from) } ?? []
        let note = HandoverNote.render(
            item: review,
            from: from,
            to: to,
            reason: reason,
            entries: entries,
            transcriptPath: transcript?.path,
            now: Date()
        )
        let url = URL(fileURLWithPath: worktreePath).appendingPathComponent(HandoverNote.fileName)
        do {
            try note.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            appendPrepLog("Could not write the handover note: \(error)", for: review.id)
            return nil
        }
        appendPrepLog("Wrote \(HandoverNote.fileName) for \(to.displayName)", for: review.id)
        return url.path
    }

    /// The live limit message for a session, for the case where the badge has not been
    /// persisted yet.
    private func limitMessage(forSession id: String) -> String? {
        limitMessageForSession[id]
    }

    public func clearAgentSession(for id: String) async {
        terminateAgentSession(for: id)
        guard var review = reviews.first(where: { $0.id == id }) else { return }
        // Archive the prior transcripts so ensureAgentSession can't re-discover and resume the
        // old session; the relaunch below starts a fresh session instead. Only this agent's
        // transcripts are archived — the other agent's conversation for the same item is
        // untouched, so switching back still resumes it.
        let kind = review.effectiveAgent(default: settings.defaultAgent)
        if let worktreePath = review.worktreePath {
            AgentTranscriptPath.archiveTranscripts(for: kind, worktreePath: worktreePath)
        }
        review.setSessionID(nil, for: kind)
        review.claudeReviewedAt = nil
        review.claudeLastCompletedAt = nil
        review.waitingSeenAt = nil
        review.agentRunStartedAt = nil
        do {
            try await store.upsertItem(review)
            reviews = await store.allItems()
        } catch {
            errorMessage = String(describing: error)
            return
        }
        guard let refreshed = reviews.first(where: { $0.id == id }) else { return }
        await ensureAgentSession(for: refreshed, forceFresh: true)
    }

    /// Updates the terminal appearance. On a real change, immediately re-themes the chrome
    /// of EVERY live session so the terminal deterministically follows the app appearance,
    /// then relaunches ONLY the currently selected session (resuming) so Claude re-detects
    /// the background and re-themes its own TUI. Relaunch is skipped if the selected session
    /// isn't safely resumable.
    public func setTerminalAppearance(isDark: Bool) async {
        guard isDark != terminalIsDark else { return }
        terminalIsDark = isDark

        for session in claudeSessions.values {
            session.applyAppearance(isDark: isDark)
        }

        guard let id = selection,
              claudeSessions[id] != nil,
              let review = reviews.first(where: { $0.id == id }),
              let worktreePath = review.worktreePath,
              case let kind = review.effectiveAgent(default: settings.defaultAgent),
              let sessionID = review.sessionID(for: kind),
              AgentTranscriptPath.transcriptExists(for: kind, worktreePath: worktreePath, sessionID: sessionID)
        else { return }

        terminateAgentSession(for: id)
        await ensureAgentSession(for: review)
    }

    /// Called when a review becomes the visible/selected one. If its live session's
    /// `claude` process was launched under a different appearance than the current one,
    /// relaunch it (resuming) so Claude re-detects the background — but only when safely
    /// resumable. This is what makes background sessions catch up on selection without
    /// relaunching every session on a toggle.
    public func reconcileTerminalAppearance(for review: WorkItem) async {
        guard claudeSessions[review.id] != nil,
              let launchedIsDark = sessionLaunchedIsDark[review.id],
              launchedIsDark != terminalIsDark,
              let worktreePath = review.worktreePath,
              case let kind = review.effectiveAgent(default: settings.defaultAgent),
              let sessionID = review.sessionID(for: kind),
              AgentTranscriptPath.transcriptExists(for: kind, worktreePath: worktreePath, sessionID: sessionID)
        else { return }

        terminateAgentSession(for: review.id)
        await ensureAgentSession(for: review)
    }

    /// `claudeReviewedAt` records the *first* completion and then stays put; other code
    /// treats it as "Claude has looked at this at least once". `claudeLastCompletedAt`
    /// moves every time, which is what lets the Waiting chip come back after the user
    /// responds and Claude runs again.
    func markClaudeTurnCompleted(_ id: String) async {
        guard var review = reviews.first(where: { $0.id == id }) else { return }
        let now = Date()
        if review.claudeReviewedAt == nil {
            review.claudeReviewedAt = now
        }
        review.claudeLastCompletedAt = now
        do {
            try await store.upsertItem(review)
            reviews = await store.allItems()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// Counts the local changes in a review worktree, so the sidebar can flag one that cannot
    /// be fast-forwarded. Editable items are skipped: their worktree is the user's own branch.
    func refreshWorktreeCleanliness(for id: String) async {
        guard let review = reviews.first(where: { $0.id == id }) else { return }
        guard review.category(myLogin: currentLogin) == .reviewRequest,
              let worktreePath = review.worktreePath,
              FileManager.default.fileExists(atPath: worktreePath)
        else {
            worktreeLocalChanges.removeValue(forKey: id)
            return
        }
        guard let changes = try? await worktreeOps.localChanges(worktreePath: worktreePath) else { return }
        if changes.isEmpty {
            worktreeLocalChanges.removeValue(forKey: id)
        } else {
            worktreeLocalChanges[id] = changes.count
        }
    }

    /// Throws away every local change in a review worktree, then fast-forwards it to the PR
    /// head. Destructive: the caller must have confirmed with the user first.
    public func discardLocalChanges(id: String) async {
        guard let review = reviews.first(where: { $0.id == id }),
              let worktreePath = review.worktreePath else { return }
        do {
            try await worktreeOps.discardLocalChanges(worktreePath: worktreePath)
            if let number = review.number {
                _ = try? await worktreeOps.refreshWorktree(
                    clonePath: registeredClonePath(for: review) ?? worktreePath,
                    worktreePath: worktreePath,
                    number: number,
                    remoteName: "origin"
                )
            }
        } catch {
            errorMessage = String(describing: error)
        }
        await refreshWorktreeCleanliness(for: id)
    }

    func refreshReviewState(for id: String, now: Date = Date()) async {
        await refreshWorktreeCleanliness(for: id)
        guard let login = currentLogin,
              let review = reviews.first(where: { $0.id == id }),
              review.prState != .merged, review.prState != .closed,
              let r = review.prRef else { return }
        let ref = PRLocator(owner: r.owner, repo: r.repo, number: r.number)

        // One GraphQL call carries review state, CI/readiness and author activity. On
        // failure the previous status stays put — a transient error must not blank the chips.
        guard let snapshot = try? await client.fetchPRSnapshot(for: ref, login: login) else { return }

        if var current = reviews.first(where: { $0.id == id }),
           current.approvedByMe != snapshot.approvedByMe
            || current.prState != snapshot.prState
            || current.myReviewState != snapshot.myReviewState
            || current.myLastReviewAt != snapshot.myLastReviewAt {
            current.approvedByMe = snapshot.approvedByMe
            current.prState = snapshot.prState
            current.myReviewState = snapshot.myReviewState
            current.myLastReviewAt = snapshot.myLastReviewAt
            do {
                try await store.upsertItem(current)
                reviews = await store.allItems()
            } catch {
                errorMessage = String(describing: error)
            }
        }

        prStatuses[id] = snapshot.status
        await refreshMergeRules(owner: r.owner, repo: r.repo, branch: review.baseBranch, now: now)
    }

    /// Reads the base branch's merge rules when the app has none, or a stale copy. A read
    /// that fails caches the unknown answer: a repository the token cannot see must not
    /// cost a call on every poll, and the row falls back to a plain approval count.
    private func refreshMergeRules(owner: String, repo: String, branch: String, now: Date) async {
        let key = MergeRules.key(owner: owner, repo: repo, branch: branch)
        if let readAt = mergeRulesReadAt[key], now.timeIntervalSince(readAt) < Self.mergeRulesTTL {
            return
        }
        mergeRulesReadAt[key] = now
        mergeRules[key] = (try? await client.fetchMergeRules(owner: owner, repo: repo, branch: branch))
            ?? MergeRules()
    }

    func refreshReviewStates() async {
        if currentLogin == nil {
            currentLogin = try? await client.fetchCurrentLogin()
        }
        let openIDs = reviews
            .filter { $0.prState != .merged && $0.prState != .closed }
            .map(\.id)
        let ids = RefreshScheduler.itemsToRefresh(
            openIDs: openIDs,
            selectedID: selection,
            lastRefreshedAt: lastRefreshedAt,
            batchSize: Self.refreshBatchSize
        )
        for id in ids {
            await refreshReviewState(for: id)
            lastRefreshedAt[id] = Date()
        }
    }

    /// Runs discovery and refreshes every open item, ignoring the staleness batching that
    /// `refreshReviewStates` applies. This is the escape hatch for the poll cycle's lag.
    public func refreshAllNow() async {
        await discoverNow()
        if currentLogin == nil {
            currentLogin = try? await client.fetchCurrentLogin()
        }
        let ids = reviews
            .filter { $0.prState != .merged && $0.prState != .closed }
            .map(\.id)
        for id in ids {
            await refreshReviewState(for: id)
            lastRefreshedAt[id] = Date()
        }
    }

    func refreshedIDsForTesting() -> Set<String> {
        Set(lastRefreshedAt.keys)
    }

    public func orphanedWorktreePaths() -> [String] {
        let root = WorktreeLayout.directory(managedRoot: settings.managedRoot)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
        let live = Set(reviews.compactMap(\.worktreePath))
        return WorktreeOrphanScanner.orphanPaths(
            directoryNames: names,
            rootPath: root,
            liveWorktreePaths: live
        )
    }

    /// Deletes worktree directories no work item points at. Returns how many went.
    @discardableResult
    public func pruneOrphanedWorktrees() async -> Int {
        var removed = 0
        for path in orphanedWorktreePaths() {
            do {
                try FileManager.default.removeItem(atPath: path)
                removed += 1
            } catch {
                errorMessage = "Could not remove \(path): \(error)"
            }
        }
        return removed
    }

    /// Moves the managed worktree root to a `.noindex` name so Spotlight stops indexing it,
    /// then repairs each clone's link to its moved worktree.
    ///
    /// Called by the app at startup, never by `load()`. `load()` must not touch the
    /// filesystem outside the store: a test that does not override `managedRoot` inherits
    /// `Settings.default`, which points at the user's real Application Support directory.
    ///
    /// The two phases are independent on purpose. A run that moves the directory but dies
    /// before rewriting the paths leaves no legacy directory for the next run to key off,
    /// so keying the rewrite on the move would strand every stale path permanently.
    public func migrateWorktreeRoot() async {
        let managedRoot = settings.managedRoot
        let legacy = WorktreeLayout.legacyDirectory(managedRoot: managedRoot)
        let destination = WorktreeLayout.directory(managedRoot: managedRoot)
        let fileManager = FileManager.default

        var movedTree = false
        if fileManager.fileExists(atPath: legacy) {
            guard !fileManager.fileExists(atPath: destination) else {
                errorMessage = "Both \(legacy) and \(destination) exist. Merge them by hand — PRPilot will not guess which worktree wins."
                return
            }
            do {
                try fileManager.moveItem(atPath: legacy, toPath: destination)
            } catch {
                errorMessage = "Could not move the worktree directory: \(error)"
                return
            }
            // Repair every moved directory, not only the ones a work item points at. A work
            // item that lost its worktreePath — a rebuilt store, a pruned then reopened PR —
            // otherwise leaves its clone pointing at the old path for good.
            for name in (try? fileManager.contentsOfDirectory(atPath: destination)) ?? [] {
                try? await worktreeOps.repairWorktree(worktreePath: destination + "/" + name)
            }
            movedTree = true
        }

        var rewroteAny = false
        for review in reviews {
            guard let old = review.worktreePath,
                  let new = WorktreeLayout.migratedPath(old, managedRoot: managedRoot) else { continue }
            var updated = review
            updated.worktreePath = new
            try? await store.upsertItem(updated)
            rewroteAny = true
            guard !movedTree, fileManager.fileExists(atPath: new) else { continue }
            try? await worktreeOps.repairWorktree(worktreePath: new)
        }
        if rewroteAny {
            reviews = await store.allItems()
        }
    }

    public func rebase(id: String) async {
        guard let item = reviews.first(where: { $0.id == id }),
              let worktreePath = item.worktreePath, item.headBranch != nil else { return }
        do {
            try await worktreeOps.fetch(clonePath: registeredClonePath(for: item) ?? worktreePath, remoteName: "origin", ref: item.baseBranch)
            let outcome = try await worktreeOps.rebaseOnto(worktreePath: worktreePath, upstream: "origin/\(item.baseBranch)")
            switch outcome {
            case .clean: rebaseStates[id] = nil
            case .conflicts(let files): rebaseStates[id] = .conflicted(files)
            }
        } catch {
            rebaseStates[id] = .failed(String(describing: error))
        }
        await refreshPushability(for: id)
    }

    public func continueRebase(id: String) async {
        guard let item = reviews.first(where: { $0.id == id }), let worktreePath = item.worktreePath else { return }
        do {
            switch try await worktreeOps.rebaseContinue(worktreePath: worktreePath) {
            case .clean: rebaseStates[id] = nil
            case .conflicts(let files): rebaseStates[id] = .conflicted(files)
            }
        } catch {
            rebaseStates[id] = .failed(String(describing: error))
        }
        await refreshPushability(for: id)
    }

    public func abortRebase(id: String) async {
        guard let item = reviews.first(where: { $0.id == id }), let worktreePath = item.worktreePath else { return }
        try? await worktreeOps.rebaseAbort(worktreePath: worktreePath)
        rebaseStates[id] = nil
        await refreshPushability(for: id)
    }

    public func push(id: String) async {
        guard let item = reviews.first(where: { $0.id == id }),
              let worktreePath = item.worktreePath, let branch = item.headBranch else { return }
        let force = pushability[id]?.needsForce ?? false
        do {
            try await worktreeOps.push(worktreePath: worktreePath, remoteName: "origin", branch: branch, force: force)
        } catch {
            errorMessage = String(describing: error)
        }
        await refreshPushability(for: id)
    }

    public func refreshPushability(for id: String) async {
        guard let item = reviews.first(where: { $0.id == id }),
              let worktreePath = item.worktreePath,
              let branch = item.headBranch,
              (try? await worktreeOps.currentBranch(worktreePath: worktreePath)) ?? nil == branch else {
            pushability[id] = nil
            return
        }
        if let counts = try? await worktreeOps.aheadBehind(worktreePath: worktreePath, upstream: "origin/\(branch)") {
            pushability[id] = Pushability(canPush: counts.ahead > 0, needsForce: counts.behind > 0, ahead: counts.ahead, behind: counts.behind)
        } else if let base = try? await worktreeOps.aheadBehind(worktreePath: worktreePath, upstream: "origin/\(item.baseBranch)") {
            pushability[id] = Pushability(canPush: base.ahead > 0, needsForce: false, ahead: base.ahead, behind: 0)
        } else {
            pushability[id] = nil
        }
    }

    public func setReviewDisabled(_ disabled: Bool, for id: String) async {
        guard var review = reviews.first(where: { $0.id == id }) else { return }
        review.disabled = disabled
        do {
            try await store.upsertItem(review)
            reviews = await store.allItems()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// Whether the "Updated" chip shows for an item: the poll found author activity newer
    /// than the user's last review, and the user has not dismissed that particular update.
    public func hasUnseenAuthorUpdate(_ item: WorkItem) -> Bool {
        AuthorUpdate.isUnseen(
            updatedAt: prStatuses[item.id]?.authorUpdatedAt,
            seenAt: item.authorUpdateSeenAt
        )
    }

    /// Dismisses the current "Updated" chip. Records the update's own timestamp rather than
    /// the wall clock, so anything the author does afterwards badges the item again.
    public func markAuthorUpdateSeen(id: String) async {
        guard var review = reviews.first(where: { $0.id == id }),
              let updatedAt = prStatuses[id]?.authorUpdatedAt else { return }
        review.authorUpdateSeenAt = updatedAt
        do {
            try await store.upsertItem(review)
            reviews = await store.allItems()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// Clears the "Waiting" chip by hand. Records the timestamp of the Claude turn the user
    /// waves off, not the wall clock, so the next completed turn raises the chip again.
    public func clearWaiting(id: String) async {
        guard var review = reviews.first(where: { $0.id == id }),
              let completedAt = review.claudeLastCompletedAt else { return }
        review.waitingSeenAt = completedAt
        do {
            try await store.upsertItem(review)
            reviews = await store.allItems()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func setIssueStatus(_ status: IssueWorkStatus?, for id: String) async {
        guard var review = reviews.first(where: { $0.id == id }) else { return }
        review.manualIssueStatus = status
        do {
            try await store.upsertItem(review)
            reviews = await store.allItems()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func setLabel(_ label: String?, for id: String) async {
        guard var review = reviews.first(where: { $0.id == id }) else { return }
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = (trimmed?.isEmpty ?? true) ? nil : trimmed
        if review.label == normalized { return }
        review.label = normalized
        do {
            try await store.upsertItem(review)
            reviews = await store.allItems()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func setPane(_ pane: PaneSelection, for id: String) async {
        guard var review = reviews.first(where: { $0.id == id }) else { return }
        if review.lastPane == pane { return }
        review.lastPane = pane
        do {
            try await store.upsertItem(review)
            reviews = await store.allItems()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func setFileViewed(_ viewed: Bool, filePath: String, reviewID: String) async {
        guard var review = reviews.first(where: { $0.id == reviewID }) else { return }
        let already = review.viewedFiles.contains(filePath)
        if viewed == already { return }
        if viewed {
            review.viewedFiles.append(filePath)
        } else {
            review.viewedFiles.removeAll { $0 == filePath }
        }
        do {
            try await store.upsertItem(review)
            reviews = await store.allItems()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func setDiffMode(_ mode: DiffMode) async {
        var updated = settings
        updated.diffMode = mode
        await updateSettings(updated)
    }

    public func updateSettings(_ newSettings: Settings) async {
        let queriesChanged = settings.reviewRequestQueries != newSettings.reviewRequestQueries
            || settings.myPRQueries != newSettings.myPRQueries
            || settings.reviewRequestsEnabled != newSettings.reviewRequestsEnabled
            || settings.myPRsEnabled != newSettings.myPRsEnabled
        do {
            try await store.updateSettings(newSettings)
            settings = newSettings
        } catch {
            errorMessage = String(describing: error)
            return
        }
        if queriesChanged {
            Task { await self.discoverNow() }
        }
    }
}
