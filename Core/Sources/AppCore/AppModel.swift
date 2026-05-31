import Foundation
import Observation
import PRReviewModels
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
    public private(set) var reviews: [Review] = []
    public var selection: String?
    public private(set) var errorMessage: String?
    public private(set) var isAdding = false
    public private(set) var diffStates: [String: DiffLoadState] = [:]
    public private(set) var registeredRepos: [RegisteredRepo] = []
    public private(set) var claudeSessions: [String: ClaudeSession] = [:]
    public private(set) var claudePaneState: [String: ClaudePaneState] = [:]
    public private(set) var claudeStatuses: [String: ClaudeStatus] = [:]
    public private(set) var settings: Settings = .default
    public var diffMode: DiffMode { settings.diffMode }

    public var webPreloadHandler: ((Review) -> Void)?

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
        reviews = await store.allReviews()
        registeredRepos = await store.allRepos()
        settings = await store.settings()
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
            while !Task.isCancelled {
                let intervalNs = UInt64(self.settings.pollIntervalSeconds) * 1_000_000_000
                try? await Task.sleep(nanoseconds: intervalNs)
                await self.discoverNow()
            }
        }
    }

    func discoverNow() async {
        let queries = settings.discoveryQueries
        var hitsByID: [String: DiscoveryHit] = [:]
        var anyQuerySucceeded = false
        for query in queries {
            guard let results = try? await client.searchPRs(query: query) else { continue }
            anyQuerySucceeded = true
            for hit in results {
                hitsByID[hit.id] = hit
            }
        }
        await mergeDiscoveryHits(Array(hitsByID.values))
        if anyQuerySucceeded {
            await pruneStaleDiscoveredReviews(currentHitIDs: Set(hitsByID.keys))
        }
    }

    private func pruneStaleDiscoveredReviews(currentHitIDs: Set<String>) async {
        let staleIDs = reviews.compactMap { review -> String? in
            guard review.origin == .discovered else { return nil }
            guard review.prState == .closed || review.prState == .merged else { return nil }
            guard !currentHitIDs.contains(review.id) else { return nil }
            return review.id
        }
        for id in staleIDs {
            do {
                try await store.removeReview(id: id)
            } catch {
                continue
            }
        }
        if !staleIDs.isEmpty {
            reviews = await store.allReviews()
        }
    }

    private func mergeDiscoveryHits(_ hits: [DiscoveryHit]) async {
        let existingByID = Dictionary(reviews.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for hit in hits {
            if let existing = existingByID[hit.id] {
                var updated = existing
                updated.title = hit.title
                updated.prState = GitHubClient.mapDiscoveryState(state: hit.state, isDraft: hit.isDraft)
                if existing.origin == .added { updated.origin = .both }
                try? await store.upsert(updated)
            } else if let lateAdded = reviews.first(where: { $0.id == hit.id }) {
                var updated = lateAdded
                updated.title = hit.title
                updated.prState = GitHubClient.mapDiscoveryState(state: hit.state, isDraft: hit.isDraft)
                updated.origin = .both
                try? await store.upsert(updated)
            } else {
                guard let fresh = try? await client.fetchReview(for: hit.ref, origin: .discovered) else { continue }
                try? await store.upsert(fresh)
                autoLoadIfEnabled(fresh)
            }
        }
        reviews = await store.allReviews()
    }

    public func addPR(urlString: String) async {
        isAdding = true
        defer { isAdding = false }
        do {
            let ref = try PRRef.parse(urlString)
            let review = try await client.fetchReview(for: ref)
            try await store.upsert(review)
            reviews = await store.allReviews()
            selection = review.id
            errorMessage = nil
            prefetch(for: review)
            autoLoadIfEnabled(review)
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func registeredClonePath(for review: Review) -> String? {
        let identity = "github.com/\(review.owner)/\(review.repo)"
        return registeredRepos.first { $0.remoteIdentity == identity }?.localClonePath
    }

    public func registerClone(for review: Review, localPath: String) async {
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
            try await store.removeReview(id: id)
            reviews = await store.allReviews()
            if selection == id {
                selection = nil
            }
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func loadDiff(for review: Review, force: Bool = false) async {
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
                try await store.upsert(updated)
                reviews = await store.allReviews()
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

    public func ensureClaudeSession(for review: Review) async {
        guard !review.disabled else { return }
        if claudeSessions[review.id] != nil {
            claudePaneState[review.id] = .sessionLive
            return
        }
        if claudePreparing.contains(review.id) { return }
        claudePreparing.insert(review.id)
        defer { claudePreparing.remove(review.id) }
        guard let executable = await claudeExecutable() else {
            claudePaneState[review.id] = .claudeUnavailable(Self.claudeNotFoundMessage)
            return
        }
        claudePaneState[review.id] = .preparingWorktree
        let ready: WorktreeReady
        do {
            ready = try await worktreeProvider.ensureWorktree(
                for: review,
                registeredClonePath: registeredClonePath(for: review)
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

        let sessionID: String
        let resume: Bool
        if let existing = updated.claudeSessionID {
            sessionID = existing
            resume = true
        } else if let latest = ClaudeTranscriptPath.latestSessionID(forWorktreePath: ready.worktreePath) {
            sessionID = latest
            resume = true
        } else {
            sessionID = UUID().uuidString.lowercased()
            resume = false
        }
        updated.claudeSessionID = sessionID

        if updated != review {
            try? await store.upsert(updated)
            reviews = await store.allReviews()
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
        watcher.start { [weak self] date, snippet in
            guard let self else { return }
            self.handleTranscriptEvent(reviewID: reviewID, at: date, snippet: snippet)
        }
        transcriptWatchers[reviewID] = watcher
    }

    func handleTranscriptEvent(reviewID: String, at date: Date, snippet: String?) {
        guard claudeSessions[reviewID] != nil else { return }
        let isNewer = lastEventAt[reviewID].map { $0 < date } ?? true
        if isNewer {
            lastEventAt[reviewID] = date
        }
        if let snippet, !snippet.isEmpty {
            lastVerdictSnippet[reviewID] = snippet
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
        let title = "Review ready · #\(review.number)"
        let body = snippet ?? "\(review.owner)/\(review.repo) · \(review.author)"
        let poster = notificationPoster
        Task {
            await poster.postReviewReady(reviewID: reviewID, title: title, body: body)
        }
    }

    func terminateClaudeSession(for id: String) {
        claudeSessions[id]?.terminate()
        claudeSessions.removeValue(forKey: id)
        claudePaneState.removeValue(forKey: id)
        transcriptWatchers[id]?.stop()
        transcriptWatchers.removeValue(forKey: id)
        claudeStatuses.removeValue(forKey: id)
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
        lastEventAt.removeAll()
        lastVerdictSnippet.removeAll()
        notifiedIdleForSession.removeAll()
    }

    public func prefetch(for review: Review) {
        guard !review.disabled else { return }
        Task { await ensureClaudeSession(for: review) }
        Task { await loadDiff(for: review) }
    }

    private func autoLoadIfEnabled(_ review: Review) {
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
                _ = try? await self.worktreeProvider.ensureWorktree(for: review, registeredClonePath: clonePath)
            }
        }
    }

    public func selectedReview() -> Review? {
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
            try await store.upsert(review)
            reviews = await store.allReviews()
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func setReviewDisabled(_ disabled: Bool, for id: String) async {
        guard var review = reviews.first(where: { $0.id == id }) else { return }
        review.disabled = disabled
        do {
            try await store.upsert(review)
            reviews = await store.allReviews()
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
            try await store.upsert(review)
            reviews = await store.allReviews()
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
        let queriesChanged = settings.discoveryQueries != newSettings.discoveryQueries
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
