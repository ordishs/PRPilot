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
    /// Items autoLoad wants reviewed that have no session yet, most recently opened first.
    public private(set) var queuedReviewIDs: [String] = []

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
    public private(set) var currentLogin: String?
    public private(set) var settings: Settings = .default
    public private(set) var discoveryWarnings: [String] = []
    public var diffMode: DiffMode { settings.diffMode }

    public var webPreloadHandler: ((WorkItem) -> Void)?

    private var transcriptWatchers: [String: TranscriptWatcher] = [:]
    private var claudePreparing: Set<String> = []
    private var lastEventAt: [String: Date] = [:]
    private var lastVerdictSnippet: [String: String] = [:]
    private var lastEventWasTurnCompletion: [String: Bool] = [:]
    private var workflowPendingForSession: [String: Bool] = [:]
    private var notifiedAwaitingForSession: Set<String> = []
    private var lastRefreshedAt: [String: Date] = [:]
    private static let refreshBatchSize = 4
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
            // pi is usually installed by a node version manager, which puts it on the PATH from
            // `.zshrc`. A login shell never reads that file, so PR Pilot cannot resolve pi on
            // its own and the explicit setting is the only reliable route.
            return """
            Couldn't find the `\(name)` command on your login PATH.

            pi is normally installed through a node version manager, which PR Pilot cannot see.
            Open a terminal and run `which \(name)`, then paste that path into Settings ▸ Tools ▸ \(name).
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
        updated.setSessionID(sessionID, for: kind)

        if updated != review {
            try? await store.upsertItem(updated)
            reviews = await store.allItems()
        }
        let spec = AgentLaunchBuilder.build(
            settings: settings,
            review: updated,
            worktreePath: ready.worktreePath,
            kind: kind,
            resolvedExecutablePath: executable,
            sessionID: sessionID,
            resume: resume
        )
        let session = AgentSession(spec: spec)
        claudeSessions[review.id] = session
        claudePaneState[review.id] = .sessionLive
        session.applyAppearance(isDark: terminalIsDark)
        sessionLaunchedIsDark[review.id] = terminalIsDark
        sessionStartedAt[review.id] = Date()
        session.start()
        attachTranscriptWatcher(reviewID: review.id, worktreePath: ready.worktreePath, kind: kind)
        recomputeStatus(for: review.id, now: Date())
        enforceSessionBudget()
        if editable {
            await refreshPushability(for: review.id)
        }
    }

    private func attachTranscriptWatcher(reviewID: String, worktreePath: String, kind: AgentKind) {
        if transcriptWatchers[reviewID] != nil { return }
        let dir = AgentTranscriptPath.directoryURL(for: kind, worktreePath: worktreePath)
        let watcher = TranscriptWatcher(transcriptDir: dir, kind: kind)
        watcher.start { [weak self] event in
            guard let self else { return }
            self.handleTranscriptEvent(
                reviewID: reviewID,
                at: event.date,
                snippet: event.snippet,
                turnCompleted: event.turnCompleted,
                workflowPending: event.workflowPending
            )
        }
        transcriptWatchers[reviewID] = watcher
    }

    func handleTranscriptEvent(
        reviewID: String,
        at date: Date,
        snippet: String?,
        turnCompleted: Bool = false,
        workflowPending: Bool = false
    ) {
        guard claudeSessions[reviewID] != nil else { return }
        let isNewer = lastEventAt[reviewID].map { $0 < date } ?? true
        if isNewer {
            lastEventAt[reviewID] = date
            lastEventWasTurnCompletion[reviewID] = turnCompleted
        }
        workflowPendingForSession[reviewID] = workflowPending
        if let snippet, !snippet.isEmpty {
            lastVerdictSnippet[reviewID] = snippet
        }
        // "Reviewed" means Claude actually completed a turn (stop_reason end_turn) — not
        // merely that the session went idle, which also happens when a review is
        // interrupted mid-task and later resumed.
        if turnCompleted {
            Task { await self.markClaudeTurnCompleted(reviewID) }
        }
        recomputeStatus(for: reviewID, now: Date())
    }

    func recomputeStatus(for reviewID: String, now: Date = Date()) {
        let processState = claudeSessions[reviewID]?.state ?? .starting
        let newStatus = statusReader.status(
            processState: processState,
            lastEventAt: lastEventAt[reviewID],
            lastVerdictSnippet: lastVerdictSnippet[reviewID],
            now: now,
            lastEventWasTurnCompletion: lastEventWasTurnCompletion[reviewID] ?? false,
            workflowPending: workflowPendingForSession[reviewID] ?? false
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
    }

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
        claudePreparing.remove(id)
        claudePaneState.removeValue(forKey: id)
        transcriptWatchers[id]?.stop()
        transcriptWatchers.removeValue(forKey: id)
        claudeStatuses.removeValue(forKey: id)
        sessionLaunchedIsDark.removeValue(forKey: id)
        sessionStartedAt.removeValue(forKey: id)
        prStatuses.removeValue(forKey: id)
        rebaseStates.removeValue(forKey: id)
        pushability.removeValue(forKey: id)
        lastRefreshedAt.removeValue(forKey: id)
        lastEventAt.removeValue(forKey: id)
        lastVerdictSnippet.removeValue(forKey: id)
        lastEventWasTurnCompletion.removeValue(forKey: id)
        workflowPendingForSession.removeValue(forKey: id)
        notifiedAwaitingForSession.remove(id)
    }

    /// Shuts a session down to reclaim its process, and nothing more. Unlike
    /// `terminateAgentSession`, this keeps `prStatuses`, `rebaseStates` and `pushability`,
    /// which describe the PR on GitHub rather than the session, and keeps the persisted
    /// `claudeSessionID` so the next open resumes instead of starting over.
    private func evictAgentSession(for id: String) {
        claudeSessions[id]?.terminate()
        claudeSessions.removeValue(forKey: id)
        claudePreparing.remove(id)
        claudePaneState.removeValue(forKey: id)
        transcriptWatchers[id]?.stop()
        transcriptWatchers.removeValue(forKey: id)
        claudeStatuses.removeValue(forKey: id)
        sessionLaunchedIsDark.removeValue(forKey: id)
        sessionStartedAt.removeValue(forKey: id)
        lastEventAt.removeValue(forKey: id)
        lastVerdictSnippet.removeValue(forKey: id)
        lastEventWasTurnCompletion.removeValue(forKey: id)
        workflowPendingForSession.removeValue(forKey: id)
        notifiedAwaitingForSession.remove(id)
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
            now: now
        )
        for id in victims {
            evictAgentSession(for: id)
        }
    }

    /// Keyed on `claudeReviewedAt` being nil, which is what makes the queue finite: the
    /// stamp survives a session ending, so a reviewed item leaves the queue for good.
    func recomputeReviewQueue() {
        guard settings.autoLoad else {
            queuedReviewIDs = []
            return
        }
        queuedReviewIDs = reviews
            .filter { !$0.disabled }
            .filter { $0.claudeReviewedAt == nil }
            .filter { claudeSessions[$0.id] == nil }
            .filter { review in
                guard let clonePath = registeredClonePath(for: review) else { return false }
                return FileManager.default.fileExists(atPath: clonePath)
            }
            .sorted { ($0.lastOpenedAt ?? $0.addedAt) > ($1.lastOpenedAt ?? $1.addedAt) }
            .map(\.id)
    }

    /// One step per call. Starting a session does real work, so pacing it keeps the launch
    /// path calm and lets a released slot settle before the next start.
    func drainSessionQueue(now: Date = Date()) async {
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
            selectedID: selection,
            now: now
        )
        if let release = step.release {
            evictAgentSession(for: release)
        }
        guard let start = step.start,
              let review = reviews.first(where: { $0.id == start }) else { return }
        await ensureAgentSession(for: review)
        recomputeReviewQueue()
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
        claudeSessions.removeAll()
        claudePaneState.removeAll()
        transcriptWatchers.removeAll()
        claudeStatuses.removeAll()
        prStatuses.removeAll()
        rebaseStates.removeAll()
        pushability.removeAll()
        lastEventAt.removeAll()
        lastVerdictSnippet.removeAll()
        lastEventWasTurnCompletion.removeAll()
        workflowPendingForSession.removeAll()
        notifiedAwaitingForSession.removeAll()
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

    func refreshReviewState(for id: String) async {
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
