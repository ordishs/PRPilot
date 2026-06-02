import Foundation
import Observation
import PRPilotModels
import ReviewStore
import GitHubKit
import ClaudeSessionKit
import CommandSupport

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
    public private(set) var claudeSessions: [String: ClaudeSession] = [:]
    public private(set) var claudePaneState: [String: ClaudePaneState] = [:]
    public private(set) var claudePrepLog: [String: [PrepLogEntry]] = [:]
    public private(set) var claudeStatuses: [String: ClaudeStatus] = [:]
    public private(set) var prStatuses: [String: PRStatus] = [:]
    public private(set) var currentLogin: String?
    public private(set) var settings: Settings = .default
    public private(set) var discoveryWarnings: [String] = []
    public var diffMode: DiffMode { settings.diffMode }

    public var webPreloadHandler: ((WorkItem) -> Void)?

    private var transcriptWatchers: [String: TranscriptWatcher] = [:]
    private var claudePreparing: Set<String> = []
    private var lastEventAt: [String: Date] = [:]
    private var lastVerdictSnippet: [String: String] = [:]
    private var notifiedIdleForSession: Set<String> = []
    private var tickTask: Task<Void, Never>?
    private var discoveryTask: Task<Void, Never>?
    private static let tickIntervalNanoseconds: UInt64 = 5_000_000_000

    private let store: ReviewStore
    private let client: GitHubClient
    private let diffLoader: DiffLoading
    private let worktreeProvider: WorktreeProviding
    private let cloneRegistrar: CloneRegistering
    private let claudePath: String
    private let notificationPoster: NotificationPosting
    private let statusReader: ClaudeStatusReader
    private let commandRunner: CommandRunner
    private var resolvedClaudePath: String?

    public init(
        store: ReviewStore,
        client: GitHubClient,
        diffLoader: DiffLoading,
        worktreeProvider: WorktreeProviding,
        cloneRegistrar: CloneRegistering,
        claudePath: String,
        notificationPoster: NotificationPosting,
        statusReader: ClaudeStatusReader = ClaudeStatusReader(),
        commandRunner: CommandRunner = ProcessCommandRunner()
    ) {
        self.store = store
        self.client = client
        self.diffLoader = diffLoader
        self.worktreeProvider = worktreeProvider
        self.cloneRegistrar = cloneRegistrar
        self.claudePath = claudePath
        self.notificationPoster = notificationPoster
        self.statusReader = statusReader
        self.commandRunner = commandRunner
    }

    public func load() async {
        reviews = await store.allItems()
        registeredRepos = await store.allRepos()
        settings = await store.settings()
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
    }

    private func startTickTimerIfNeeded() {
        guard tickTask == nil else { return }
        tickTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.tickIntervalNanoseconds)
                self.tickAllActiveStatuses()
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
                guard let results = try? await client.searchPRs(query: text) else { continue }
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
        discoveryWarnings = warnings
        await mergeDiscoveryHits(Array(hitsByID.values))
        if anyQuerySucceeded {
            await pruneStaleDiscoveredReviews(currentHitIDs: Set(hitsByID.keys))
        }
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
            await ensureClaudeSession(for: task)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func registerClone(for review: WorkItem, localPath: String) async {
        do {
            try await cloneRegistrar.validate(localPath: localPath, expectedOwner: review.owner, expectedRepo: review.repo)
            let identity = "github.com/\(review.owner)/\(review.repo)"
            let entry = RegisteredRepo(remoteIdentity: identity, localClonePath: localPath, defaultBase: review.baseBranch)
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
                let entry = RegisteredRepo(remoteIdentity: "github.com/\(identity)", localClonePath: localPath, defaultBase: "main")
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
        terminateClaudeSession(for: id)
        diffStates.removeValue(forKey: id)
        if let worktreePath = review.worktreePath, FileManager.default.fileExists(atPath: worktreePath) {
            try? FileManager.default.removeItem(atPath: worktreePath)
        }
        do {
            try await store.removeItem(id: id)
            reviews = await store.allItems()
            if selection == id {
                selection = nil
            }
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
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

    static let claudeNotFoundMessage = """
    Couldn't find the `claude` command on your login PATH.

    Open a terminal and run `which claude`, then paste that path into Settings ▸ Tools ▸ claude.
    """

    private func claudeExecutable() async -> String? {
        if let override = explicitClaudeOverride() {
            return override
        }
        if let cached = resolvedClaudePath {
            return cached
        }
        let resolved = await LoginShellResolver.resolve("claude", runner: commandRunner)
        resolvedClaudePath = resolved
        return resolved
    }

    private func explicitClaudeOverride() -> String? {
        for candidate in [settings.claudePath, claudePath] {
            guard let candidate, !candidate.isEmpty, candidate != "claude" else { continue }
            return (candidate as NSString).expandingTildeInPath
        }
        return nil
    }

    private func appendPrepLog(_ message: String, for id: String) {
        claudePrepLog[id, default: []].append(PrepLogEntry(date: Date(), message: message))
    }

    public func ensureClaudeSession(for review: WorkItem, forceFresh: Bool = false) async {
        guard !review.disabled else { return }
        if claudeSessions[review.id] != nil {
            claudePaneState[review.id] = .sessionLive
            return
        }
        if claudePreparing.contains(review.id) { return }
        claudePreparing.insert(review.id)
        defer { claudePreparing.remove(review.id) }

        claudePaneState[review.id] = .preparingWorktree
        claudePrepLog[review.id] = []
        appendPrepLog("Locating claude…", for: review.id)
        guard let executable = await claudeExecutable() else {
            claudePaneState[review.id] = .claudeUnavailable(Self.claudeNotFoundMessage)
            claudePrepLog[review.id] = nil
            return
        }
        let reviewID = review.id
        let progress: PrepProgress = { [weak self] message in
            await self?.appendPrepLog(message, for: reviewID)
        }
        let ready: WorktreeReady
        do {
            ready = try await worktreeProvider.ensureWorktree(
                for: review,
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
            appendPrepLog("Starting fresh /review", for: review.id)
        } else if let existing = updated.claudeSessionID {
            // Resume the persisted session only if its transcript still exists. If it was
            // archived or pruned, `claude --resume` would exit 256 ("No conversation found"),
            // so fall back to a fresh review instead.
            if ClaudeTranscriptPath.transcriptExists(forWorktreePath: ready.worktreePath, sessionID: existing) {
                sessionID = existing
                resume = true
                appendPrepLog("Resuming session \(existing)", for: review.id)
            } else {
                sessionID = UUID().uuidString.lowercased()
                resume = false
                appendPrepLog("Previous session not found; starting fresh /review", for: review.id)
            }
        } else if let latest = ClaudeTranscriptPath.latestSessionID(forWorktreePath: ready.worktreePath) {
            sessionID = latest
            resume = true
            appendPrepLog("Resuming session \(latest)", for: review.id)
        } else {
            sessionID = UUID().uuidString.lowercased()
            resume = false
            appendPrepLog("Starting fresh /review", for: review.id)
        }
        updated.claudeSessionID = sessionID

        if updated != review {
            try? await store.upsertItem(updated)
            reviews = await store.allItems()
        }
        let spec = ClaudeLaunchBuilder.build(
            settings: settings,
            review: updated,
            worktreePath: ready.worktreePath,
            resolvedClaudePath: executable,
            sessionID: sessionID,
            resume: resume
        )
        let session = ClaudeSession(spec: spec)
        claudeSessions[review.id] = session
        claudePaneState[review.id] = .sessionLive
        session.start()
        attachTranscriptWatcher(reviewID: review.id, worktreePath: ready.worktreePath)
        recomputeStatus(for: review.id, now: Date())
    }

    private func attachTranscriptWatcher(reviewID: String, worktreePath: String) {
        if transcriptWatchers[reviewID] != nil { return }
        let dir = ClaudeTranscriptPath.directoryURL(forWorktreePath: worktreePath)
        let watcher = TranscriptWatcher(transcriptDir: dir)
        watcher.start { [weak self] date, snippet, turnCompleted in
            guard let self else { return }
            self.handleTranscriptEvent(reviewID: reviewID, at: date, snippet: snippet, turnCompleted: turnCompleted)
        }
        transcriptWatchers[reviewID] = watcher
    }

    func handleTranscriptEvent(reviewID: String, at date: Date, snippet: String?, turnCompleted: Bool = false) {
        guard claudeSessions[reviewID] != nil else { return }
        let isNewer = lastEventAt[reviewID].map { $0 < date } ?? true
        if isNewer {
            lastEventAt[reviewID] = date
        }
        if let snippet, !snippet.isEmpty {
            lastVerdictSnippet[reviewID] = snippet
        }
        // "Reviewed" means Claude actually completed a turn (stop_reason end_turn) — not
        // merely that the session went idle, which also happens when a review is
        // interrupted mid-task and later resumed.
        if turnCompleted, reviews.first(where: { $0.id == reviewID })?.claudeReviewedAt == nil {
            Task { await self.markClaudeReviewed(reviewID) }
        }
        recomputeStatus(for: reviewID, now: Date())
    }

    func recomputeStatus(for reviewID: String, now: Date = Date()) {
        let processState = claudeSessions[reviewID]?.state ?? .starting
        let newStatus = statusReader.status(
            processState: processState,
            lastEventAt: lastEventAt[reviewID],
            lastVerdictSnippet: lastVerdictSnippet[reviewID],
            now: now
        )
        let oldStatus = claudeStatuses[reviewID]
        claudeStatuses[reviewID] = newStatus
        if shouldFireReviewReady(old: oldStatus, new: newStatus, reviewID: reviewID) {
            notifiedIdleForSession.insert(reviewID)
            postReviewReadyNotification(for: reviewID, status: newStatus)
        }
    }

    private func shouldFireReviewReady(old: ClaudeStatus?, new: ClaudeStatus, reviewID: String) -> Bool {
        guard !notifiedIdleForSession.contains(reviewID) else { return false }
        guard case .idle = new else { return false }
        guard case .working = old else { return false }
        return true
    }

    private func postReviewReadyNotification(for reviewID: String, status: ClaudeStatus) {
        guard let review = reviews.first(where: { $0.id == reviewID }) else { return }
        var snippet: String? = nil
        if case .idle(_, let s) = status { snippet = s }
        let title = "Review ready · #\(review.number.map(String.init) ?? "?")"
        let body = snippet ?? "\(review.owner)/\(review.repo) · \(review.author ?? "")"
        let poster = notificationPoster
        Task {
            await poster.postReviewReady(reviewID: reviewID, title: title, body: body)
        }
    }

    func terminateClaudeSession(for id: String) {
        claudeSessions[id]?.terminate()
        claudeSessions.removeValue(forKey: id)
        claudePreparing.remove(id)
        claudePaneState.removeValue(forKey: id)
        transcriptWatchers[id]?.stop()
        transcriptWatchers.removeValue(forKey: id)
        claudeStatuses.removeValue(forKey: id)
        prStatuses.removeValue(forKey: id)
        lastEventAt.removeValue(forKey: id)
        lastVerdictSnippet.removeValue(forKey: id)
        notifiedIdleForSession.remove(id)
    }

    public func terminateAllClaudeSessions() {
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
        lastEventAt.removeAll()
        lastVerdictSnippet.removeAll()
        notifiedIdleForSession.removeAll()
    }

    public func prefetch(for review: WorkItem) {
        guard !review.disabled else { return }
        Task { await ensureClaudeSession(for: review) }
    }

    private func autoLoadIfEnabled(_ review: WorkItem) {
        guard settings.autoLoad, !review.disabled else { return }
        Task { await ensureClaudeSession(for: review) }
        webPreloadHandler?(review)
    }

    public func prewarmDiffs() {
        for review in reviews where !review.disabled {
            Task(priority: .background) { await loadDiff(for: review) }
        }
    }

    public func prewarmClaude() {
        Task(priority: .background) { [weak self] in
            guard let self else { return }
            _ = await self.claudeExecutable()
            for review in self.reviews where !review.disabled {
                if self.claudeSessions[review.id] != nil { continue }
                guard let clonePath = self.registeredClonePath(for: review),
                      FileManager.default.fileExists(atPath: clonePath) else { continue }
                if self.settings.autoLoad {
                    await self.ensureClaudeSession(for: review)
                } else {
                    _ = try? await self.worktreeProvider.ensureWorktree(for: review, registeredClonePath: clonePath)
                }
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
            await refreshReviewState(for: id)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    /// Discards the Claude session for a review and immediately starts a fresh one:
    /// terminates the live process/watcher, clears the persisted session id and the
    /// "reviewed" stamp, archives the prior transcripts, then relaunches a clean
    /// /review (no resume). Restarting here is what makes the open pane recover —
    /// ClaudePaneView only auto-triggers ensureClaudeSession when review.id changes,
    /// so a cleared-but-not-restarted session would leave the pane stuck on the
    /// "Preparing worktree…" placeholder.
    public func clearClaudeSession(for id: String) async {
        terminateClaudeSession(for: id)
        guard var review = reviews.first(where: { $0.id == id }) else { return }
        // Archive the prior transcripts so ensureClaudeSession can't re-discover and
        // --resume the old session; the relaunch below starts a fresh /review instead.
        if let worktreePath = review.worktreePath {
            ClaudeTranscriptPath.archiveTranscripts(forWorktreePath: worktreePath)
        }
        review.claudeSessionID = nil
        review.claudeReviewedAt = nil
        do {
            try await store.upsertItem(review)
            reviews = await store.allItems()
        } catch {
            errorMessage = String(describing: error)
            return
        }
        guard let refreshed = reviews.first(where: { $0.id == id }) else { return }
        await ensureClaudeSession(for: refreshed, forceFresh: true)
    }

    func markClaudeReviewed(_ id: String) async {
        guard var review = reviews.first(where: { $0.id == id }), review.claudeReviewedAt == nil else { return }
        review.claudeReviewedAt = Date()
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

        if let state = try? await client.fetchReviewState(for: ref, login: login),
           var current = reviews.first(where: { $0.id == id }),
           current.approvedByMe != state.approvedByMe || current.prState != state.prState {
            current.approvedByMe = state.approvedByMe
            current.prState = state.prState
            do {
                try await store.upsertItem(current)
                reviews = await store.allItems()
            } catch {
                errorMessage = String(describing: error)
            }
        }

        if let status = try? await client.fetchPRStatus(for: ref) {
            prStatuses[id] = status
        }
    }

    func refreshReviewStates() async {
        if currentLogin == nil {
            currentLogin = try? await client.fetchCurrentLogin()
        }
        let ids = reviews
            .filter { $0.prState != .merged && $0.prState != .closed }
            .map(\.id)
        for id in ids {
            await refreshReviewState(for: id)
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
