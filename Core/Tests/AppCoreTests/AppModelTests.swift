import Testing
import Foundation
import PRPilotModels
import GitHubKit
import CommandSupport
import ReviewStore
import DiffKit
import WorktreeKit
@testable import AppCore
import ClaudeSessionKit

private actor StubRunner: CommandRunner {
    private var results: [CommandResult]
    private let fallback: CommandResult?
    private(set) var recordedArguments: [[String]] = []

    init(result: CommandResult) {
        self.results = []
        self.fallback = result
    }

    init(results: [CommandResult]) {
        self.results = results
        self.fallback = nil
    }

    func run(executable: String, arguments: [String]) async throws -> CommandResult {
        recordedArguments.append(arguments)
        if !results.isEmpty {
            return results.removeFirst()
        }
        if let fallback {
            return fallback
        }
        throw NSError(domain: "StubRunner", code: -1, userInfo: [NSLocalizedDescriptionKey: "queue exhausted"])
    }
}

private func tempStoreURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("appcore-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("store.json")
}

private let prJSON = """
{
  "number": 944,
  "title": "centrifuge fix",
  "url": "https://github.com/bsv-blockchain/teranode/pull/944",
  "state": "OPEN",
  "isDraft": false,
  "author": { "login": "icellan" },
  "headRefName": "fix/centrifuge",
  "baseRefName": "main"
}
"""

private struct StubDiffLoader: DiffLoading {
    var files: [DiffFile] = []
    var shouldThrow = false
    func loadDiff(for review: WorkItem, registeredClonePath: String?) async throws -> DiffResult {
        if shouldThrow {
            throw DiffError.gitFailed(exitCode: 1, message: "stub failure")
        }
        return DiffResult(worktreePath: "/tmp/wt", files: files)
    }
}

private struct StubRegistrar: CloneRegistering {
    var shouldThrow: RegistrationError? = nil
    var detectedRepositories: [String] = []
    func validate(localPath: String, expectedOwner: String, expectedRepo: String) async throws {
        if let error = shouldThrow {
            throw error
        }
    }
    func detectRepositories(at localPath: String) async throws -> [String] {
        if let error = shouldThrow {
            throw error
        }
        return detectedRepositories
    }
}

private actor RecordingDiffLoader: DiffLoading {
    private(set) var lastRegisteredClonePath: String?
    private(set) var callCount: Int = 0
    func loadDiff(for review: WorkItem, registeredClonePath: String?) async throws -> DiffResult {
        callCount += 1
        lastRegisteredClonePath = registeredClonePath
        return DiffResult(worktreePath: "/tmp/wt", files: [])
    }
}

private actor StubNotificationPoster: NotificationPosting {
    private(set) var posted: [(reviewID: String, title: String, body: String)] = []
    func postReviewReady(reviewID: String, title: String, body: String) async {
        posted.append((reviewID: reviewID, title: title, body: body))
    }
}

private struct StubWorktreeProvider: WorktreeProviding {
    var result: WorktreeReady = WorktreeReady(clonePath: "/tmp/clone", worktreePath: "/tmp/wt", remoteName: "origin")
    var shouldThrow = false
    var progressLines: [String] = []
    func ensureWorktree(for review: WorkItem, editable: Bool, registeredClonePath: String?, progress: @escaping PrepProgress) async throws -> WorktreeReady {
        for line in progressLines {
            await progress(line)
        }
        if shouldThrow {
            throw WorktreeError.gitFailed(arguments: ["stub"], exitCode: 1, message: "stub failure")
        }
        return result
    }
}

private actor StubWorktreeOps: WorktreeManaging {
    var currentBranchResult: String? = nil
    var isCleanResult: Bool = true
    var rebaseResult: RebaseOutcome = .clean
    var aheadBehindByUpstream: [String: (ahead: Int, behind: Int)] = [:]
    var aheadBehindDefaultResult: (ahead: Int, behind: Int) = (0, 0)
    var shouldThrowAheadBehind: Set<String> = []
    private(set) var recordedPushCalls: [(remoteName: String, branch: String, force: Bool)] = []

    func set(currentBranchResult: String?) { self.currentBranchResult = currentBranchResult }
    func set(rebaseResult: RebaseOutcome) { self.rebaseResult = rebaseResult }
    func set(aheadBehindDefaultResult: (ahead: Int, behind: Int)) { self.aheadBehindDefaultResult = aheadBehindDefaultResult }
    func set(aheadBehindByUpstream: [String: (ahead: Int, behind: Int)]) { self.aheadBehindByUpstream = aheadBehindByUpstream }
    func set(shouldThrowAheadBehind: Set<String>) { self.shouldThrowAheadBehind = shouldThrowAheadBehind }

    func currentBranch(worktreePath: String) async throws -> String? { currentBranchResult }
    func isClean(worktreePath: String) async throws -> Bool { isCleanResult }
    func fetch(clonePath: String, remoteName: String, ref: String) async throws {}
    func rebaseOnto(worktreePath: String, upstream: String) async throws -> RebaseOutcome { rebaseResult }
    func rebaseContinue(worktreePath: String) async throws -> RebaseOutcome { rebaseResult }
    func rebaseAbort(worktreePath: String) async throws {}
    func push(worktreePath: String, remoteName: String, branch: String, force: Bool) async throws {
        recordedPushCalls.append((remoteName: remoteName, branch: branch, force: force))
    }
    func aheadBehind(worktreePath: String, upstream: String) async throws -> (ahead: Int, behind: Int) {
        if shouldThrowAheadBehind.contains(upstream) {
            throw WorktreeError.gitFailed(arguments: ["rev-list"], exitCode: 128, message: "no such upstream")
        }
        return aheadBehindByUpstream[upstream] ?? aheadBehindDefaultResult
    }
}

private let sampleReviewID = "AAAAAAAA-0000-0000-0000-000000000944"

private func sampleReview() -> WorkItem {
    WorkItem(
        id: sampleReviewID,
        title: "centrifuge fix",
        repoKey: "github.com/bsv-blockchain/teranode",
        baseBranch: "main",
        headBranch: "fix/centrifuge",
        prRef: PRRef(
            owner: "bsv-blockchain", repo: "teranode", number: 944,
            url: URL(string: "https://github.com/bsv-blockchain/teranode/pull/944")!,
            authorLogin: "icellan"
        ),
        prState: .open,
        origin: .added,
        addedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

private func stubClient() -> GitHubClient {
    GitHubClient(runner: StubRunner(result: CommandResult(exitCode: 0, standardOutput: "", standardError: "")), ghPath: "gh")
}

@Test @MainActor func addPRFetchesStoresAndSelects() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let client = GitHubClient(runner: StubRunner(result: CommandResult(exitCode: 0, standardOutput: prJSON, standardError: "")), ghPath: "gh")
    let model = AppModel(store: store, client: client, diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())

    await model.addPR(urlString: "https://github.com/bsv-blockchain/teranode/pull/944")

    #expect(model.reviews.count == 1)
    #expect(model.reviews.first?.prRef?.number == 944)
    #expect(model.selection == model.reviews.first?.id)
    #expect(model.errorMessage == nil)
}

@Test @MainActor func addPRSetsErrorOnInvalidURL() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let client = GitHubClient(runner: StubRunner(result: CommandResult(exitCode: 0, standardOutput: "", standardError: "")), ghPath: "gh")
    let model = AppModel(store: store, client: client, diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())

    await model.addPR(urlString: "not a pr url")

    #expect(model.reviews.isEmpty)
    #expect(model.errorMessage != nil)
}

@Test @MainActor func addPRSurfacesCommandFailureAndDismisses() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let client = GitHubClient(runner: StubRunner(result: CommandResult(exitCode: 1, standardOutput: "", standardError: "no pull requests found")), ghPath: "gh")
    let model = AppModel(store: store, client: client, diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())

    await model.addPR(urlString: "https://github.com/bsv-blockchain/teranode/pull/944")

    #expect(model.reviews.isEmpty)
    #expect(model.errorMessage != nil)

    model.dismissError()
    #expect(model.errorMessage == nil)
}

@Test @MainActor func loadReadsExistingReviews() async throws {
    let url = tempStoreURL()
    let seedStore = try ReviewStore(fileURL: url)
    try await seedStore.upsertItem(WorkItem(
        title: "prune",
        repoKey: "github.com/bsv-blockchain/teranode",
        baseBranch: "main",
        headBranch: "prune",
        prRef: PRRef(
            owner: "bsv-blockchain", repo: "teranode", number: 901,
            url: URL(string: "https://github.com/bsv-blockchain/teranode/pull/901")!,
            authorLogin: "jad"
        ),
        prState: .open,
        origin: .added,
        addedAt: Date(timeIntervalSince1970: 1_700_000_000)
    ))
    let client = GitHubClient(runner: StubRunner(result: CommandResult(exitCode: 0, standardOutput: "", standardError: "")), ghPath: "gh")
    let model = AppModel(store: try ReviewStore(fileURL: url), client: client, diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())

    await model.load()

    #expect(model.reviews.count == 1)
    #expect(model.reviews.first?.number == 901)
}

@Test @MainActor func loadDiffSetsLoadedState() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let file = DiffFile(oldPath: "foo.txt", newPath: "foo.txt", changeKind: .modified, hunks: [], addedCount: 1, removedCount: 0)
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(files: [file]), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())

    await model.loadDiff(for: sampleReview())

    #expect(model.diffStates[sampleReview().id] == .loaded([file]))
}

@Test @MainActor func loadDiffSetsFailedStateOnError() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(shouldThrow: true), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())

    await model.loadDiff(for: sampleReview())

    if case .failed = model.diffStates[sampleReview().id] {
    } else {
        Issue.record("expected .failed, got \(String(describing: model.diffStates[sampleReview().id]))")
    }
}

@Test @MainActor func loadDiffPersistsWorktreePath() async throws {
    let url = tempStoreURL()
    let store = try ReviewStore(fileURL: url)
    let review = sampleReview()
    try await store.upsertItem(review)
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(files: []), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())
    await model.load()

    await model.loadDiff(for: review)

    let reloaded = try ReviewStore(fileURL: url)
    #expect(await reloaded.allItems().first?.worktreePath == "/tmp/wt")
}

@Test @MainActor func registerCloneSucceedsAndPersists() async throws {
    let url = tempStoreURL()
    let store = try ReviewStore(fileURL: url)
    let review = sampleReview()
    try await store.upsertItem(review)
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())
    await model.load()

    await model.registerClone(for: review, localPath: "/Users/me/dev/teranode")

    #expect(model.errorMessage == nil)
    #expect(model.registeredClonePath(for: review) == "/Users/me/dev/teranode")
    let reloaded = try ReviewStore(fileURL: url)
    #expect(await reloaded.repo(forRemote: "github.com/bsv-blockchain/teranode")?.localClonePath == "/Users/me/dev/teranode")
}

@Test @MainActor func registerCloneSetsErrorOnValidationFailure() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let registrar = StubRegistrar(shouldThrow: .originMismatch(expected: "bsv-blockchain/teranode", actual: "x/y"))
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: registrar, worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())

    await model.registerClone(for: sampleReview(), localPath: "/wrong/path")

    #expect(model.errorMessage != nil)
    #expect(model.registeredClonePath(for: sampleReview()) == nil)
}

@Test @MainActor func loadDiffPassesRegisteredClonePathToLoader() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let review = sampleReview()
    try await store.upsertItem(review)
    try await store.upsert(RegisteredRepo(
        remoteIdentity: "github.com/bsv-blockchain/teranode",
        localClonePath: "/Users/me/dev/teranode",
        defaultBase: "main"
    ))
    let recorder = RecordingDiffLoader()
    let model = AppModel(store: store, client: stubClient(), diffLoader: recorder, worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())
    await model.load()

    await model.loadDiff(for: review)

    let captured = await recorder.lastRegisteredClonePath
    #expect(captured == "/Users/me/dev/teranode")
}

@Test @MainActor func loadDiffPassesNilWhenNoRegisteredClone() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let review = sampleReview()
    try await store.upsertItem(review)
    let recorder = RecordingDiffLoader()
    let model = AppModel(store: store, client: stubClient(), diffLoader: recorder, worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())
    await model.load()

    await model.loadDiff(for: review)

    let captured = await recorder.lastRegisteredClonePath
    #expect(captured == nil)
}

@Test @MainActor func registerLocalCloneRegistersAllDetected() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let registrar = StubRegistrar(detectedRepositories: ["ordishs/teranode", "bsv-blockchain/teranode"])
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: registrar, worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())

    await model.registerLocalClone(at: "/Users/me/dev/teranode")

    #expect(model.errorMessage == nil)
    #expect(model.registeredRepos.count == 2)
    let identities = model.registeredRepos.map(\.remoteIdentity).sorted()
    #expect(identities == ["github.com/bsv-blockchain/teranode", "github.com/ordishs/teranode"])
    #expect(model.registeredRepos.allSatisfy { $0.localClonePath == "/Users/me/dev/teranode" })
}

@Test @MainActor func registerLocalCloneSetsErrorWhenNoReposFound() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let registrar = StubRegistrar(detectedRepositories: [])
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: registrar, worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())

    await model.registerLocalClone(at: "/Users/me/empty")

    #expect(model.errorMessage != nil)
    #expect(model.registeredRepos.isEmpty)
}

@Test @MainActor func removeRegisteredRepoDeletes() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    try await store.upsert(RegisteredRepo(
        remoteIdentity: "github.com/bsv-blockchain/teranode",
        localClonePath: "/Users/me/dev/teranode",
        defaultBase: "main"
    ))
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())
    await model.load()
    #expect(model.registeredRepos.count == 1)

    await model.removeRegisteredRepo(remoteIdentity: "github.com/bsv-blockchain/teranode")

    #expect(model.registeredRepos.isEmpty)
}

@Test @MainActor func removeReviewRemovesFromStoreAndClearsSelection() async throws {
    let url = tempStoreURL()
    let store = try ReviewStore(fileURL: url)
    let review = sampleReview()
    try await store.upsertItem(review)
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())
    await model.load()
    model.selection = review.id

    await model.removeReview(id: review.id)

    #expect(model.reviews.isEmpty)
    #expect(model.selection == nil)
    let reloaded = try ReviewStore(fileURL: url)
    #expect(await reloaded.allItems().isEmpty)
}

@Test @MainActor func removeReviewBestEffortRemovesWorktreeDir() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let tempWorktree = FileManager.default.temporaryDirectory
        .appendingPathComponent("wt-\(UUID().uuidString)", isDirectory: true)
        .path
    try FileManager.default.createDirectory(atPath: tempWorktree, withIntermediateDirectories: true)
    var review = sampleReview()
    review.worktreePath = tempWorktree
    try await store.upsertItem(review)
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())
    await model.load()

    await model.removeReview(id: review.id)

    #expect(model.reviews.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: tempWorktree))
}

@Test @MainActor func prepLogRetainedOnWorktreeFailure() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let review = sampleReview()
    try await store.upsertItem(review)
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(shouldThrow: true, progressLines: ["Fetching PR #944…"]),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.ensureClaudeSession(for: review)

    if case .worktreeFailed = model.claudePaneState[review.id] {} else {
        Issue.record("expected .worktreeFailed, got \(String(describing: model.claudePaneState[review.id]))")
    }
    let messages = (model.claudePrepLog[review.id] ?? []).map(\.message)
    #expect(messages.contains("Locating claude…"))
    #expect(messages.contains("Fetching PR #944…"))
}

@Test @MainActor func ensureClaudeSessionStartsFreshWhenPersistedTranscriptMissing() async throws {
    // A persisted session whose transcript no longer exists (archived/pruned) must not be
    // resumed — `claude --resume` would exit "No conversation found". The model should
    // assign a fresh session id instead. The stub worktree path points at /tmp/wt, whose
    // ~/.claude/projects transcript dir has no transcript for this id.
    let store = try ReviewStore(fileURL: tempStoreURL())
    var review = sampleReview()
    review.claudeSessionID = "ghost-session-\(UUID().uuidString.lowercased())"
    try await store.upsertItem(review)
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.ensureClaudeSession(for: review)

    let refreshed = model.reviews.first(where: { $0.id == review.id })
    #expect(refreshed?.claudeSessionID != nil)
    #expect(refreshed?.claudeSessionID != review.claudeSessionID)
}

@Test @MainActor func prepLogRetainedOnSessionLive() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let review = sampleReview()
    try await store.upsertItem(review)
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(progressLines: ["Fetching PR #944…"]),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.ensureClaudeSession(for: review)

    // The prep log persists after the session goes live so the pane can re-open it
    // on demand; it is reset at the start of the next prep run, not cleared here.
    #expect(model.claudePaneState[review.id] == .sessionLive)
    let messages = (model.claudePrepLog[review.id] ?? []).map(\.message)
    #expect(messages.contains("Fetching PR #944…"))
    #expect(messages.contains("Starting fresh /review"))
}

@Test @MainActor func ensureClaudeSessionFlagsWorktreeFailure() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(shouldThrow: true),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    let review = sampleReview()

    await model.ensureClaudeSession(for: review)

    let state = model.claudePaneState[review.id]
    if case .worktreeFailed(let message) = state {
        #expect(message.contains("stub failure"))
    } else {
        Issue.record("expected .worktreeFailed, got \(String(describing: state))")
    }
    #expect(model.claudeSessions[review.id] == nil)
}

@Test @MainActor func ensureClaudeSessionInitializesStatus() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let review = sampleReview()
    try await store.upsertItem(review)
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.ensureClaudeSession(for: review)

    let status = model.claudeStatuses[review.id]
    #expect(status == .starting)
}

@Test @MainActor func recomputeStatusFlipsToIdle() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let review = sampleReview()
    try await store.upsertItem(review)
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster(),
        statusReader: ClaudeStatusReader(idleThresholdSeconds: 0.1)
    )
    await model.load()
    await model.ensureClaudeSession(for: review)

    model.handleTranscriptEvent(reviewID: review.id, at: Date(), snippet: "Hello")
    model.recomputeStatus(for: review.id, now: Date())

    let firstStatus = model.claudeStatuses[review.id]
    #expect(firstStatus == .working)

    let later = Date().addingTimeInterval(1)
    model.recomputeStatus(for: review.id, now: later)

    let secondStatus = model.claudeStatuses[review.id]
    if case .idle(_, let snippet) = secondStatus {
        #expect(snippet == "Hello")
    } else {
        Issue.record("expected .idle, got \(String(describing: secondStatus))")
    }
}

@Test @MainActor func clearClaudeSessionResetsSessionAndReviewedState() async throws {
    let url = tempStoreURL()
    let store = try ReviewStore(fileURL: url)
    var review = sampleReview()
    review.claudeSessionID = "existing-session"
    review.claudeReviewedAt = Date(timeIntervalSince1970: 1_700_000_000)
    try await store.upsertItem(review)
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.clearClaudeSession(for: review.id)

    let cleared = model.reviews.first(where: { $0.id == review.id })
    // Clearing archives the old session and starts a fresh one (new id), and
    // resets the "reviewed" stamp so the fresh review can re-stamp it.
    #expect(cleared?.claudeSessionID != nil)
    #expect(cleared?.claudeSessionID != "existing-session")
    #expect(cleared?.claudeReviewedAt == nil)
}

@Test @MainActor func clearClaudeSessionStartsFreshSessionForOpenPane() async throws {
    // Clearing the session for the currently-open PR must immediately start a fresh
    // session. The pane only re-triggers ensureClaudeSession when review.id changes,
    // so if clear left the pane state nil it would hang on "Preparing worktree…".
    let store = try ReviewStore(fileURL: tempStoreURL())
    var review = sampleReview()
    review.claudeSessionID = "existing-session"
    try await store.upsertItem(review)
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()
    await model.ensureClaudeSession(for: review)

    await model.clearClaudeSession(for: review.id)

    #expect(model.claudePaneState[review.id] == .sessionLive)
    let refreshed = model.reviews.first(where: { $0.id == review.id })
    #expect(refreshed?.claudeSessionID != nil)
    #expect(refreshed?.claudeSessionID != "existing-session")
}

@Test func ensureWorktreeTwoArgOverloadForwardsToProgressVariant() async throws {
    final class Box: @unchecked Sendable { var called = false }
    struct Recorder: WorktreeProviding {
        let box: Box
        func ensureWorktree(for review: WorkItem, editable: Bool, registeredClonePath: String?, progress: @escaping PrepProgress) async throws -> WorktreeReady {
            box.called = true
            return WorktreeReady(clonePath: "/c", worktreePath: "/w", remoteName: "origin")
        }
    }
    let box = Box()
    let recorder = Recorder(box: box)
    _ = try await recorder.ensureWorktree(for: sampleReview(), editable: false, registeredClonePath: nil)
    #expect(box.called == true)
}

@Test @MainActor func idleWithoutCompletedTurnDoesNotStampReviewed() async throws {
    // An interrupted-then-resumed review goes idle without ever completing a turn
    // (no end_turn). It must NOT be marked reviewed just for being idle.
    let store = try ReviewStore(fileURL: tempStoreURL())
    let review = sampleReview()
    try await store.upsertItem(review)
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster(),
        statusReader: ClaudeStatusReader(idleThresholdSeconds: 0.1)
    )
    await model.load()
    await model.ensureClaudeSession(for: review)

    let staleEvent = Date().addingTimeInterval(-3600)
    model.handleTranscriptEvent(reviewID: review.id, at: staleEvent, snippet: "Gathering details", turnCompleted: false)
    model.recomputeStatus(for: review.id, now: Date())

    if case .idle = model.claudeStatuses[review.id] {} else {
        Issue.record("expected .idle, got \(String(describing: model.claudeStatuses[review.id]))")
    }

    try await Task.sleep(nanoseconds: 300_000_000)
    #expect(model.reviews.first(where: { $0.id == review.id })?.claudeReviewedAt == nil)
}

@Test @MainActor func completedTurnStampsReviewed() async throws {
    // A genuinely finished review (assistant reached end_turn) is marked reviewed,
    // even without a live working->idle edge (e.g. replayed on resume).
    let store = try ReviewStore(fileURL: tempStoreURL())
    let review = sampleReview()
    try await store.upsertItem(review)
    let poster = StubNotificationPoster()
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: poster,
        statusReader: ClaudeStatusReader(idleThresholdSeconds: 0.1)
    )
    await model.load()
    await model.ensureClaudeSession(for: review)

    model.handleTranscriptEvent(reviewID: review.id, at: Date(), snippet: "Review complete", turnCompleted: true)

    try await Task.sleep(nanoseconds: 300_000_000)
    #expect(model.reviews.first(where: { $0.id == review.id })?.claudeReviewedAt != nil)

    // Completing a turn is silent — the notification only fires on a live working->idle edge.
    let posted = await poster.posted
    #expect(posted.isEmpty)
}

@Test @MainActor func firstIdleTransitionFiresNotificationOnce() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let review = sampleReview()
    try await store.upsertItem(review)
    let poster = StubNotificationPoster()
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: poster,
        statusReader: ClaudeStatusReader(idleThresholdSeconds: 0.1)
    )
    await model.load()
    await model.ensureClaudeSession(for: review)

    let t0 = Date()
    model.handleTranscriptEvent(reviewID: review.id, at: t0, snippet: "first")
    model.recomputeStatus(for: review.id, now: t0)

    let t1 = t0.addingTimeInterval(1)
    model.recomputeStatus(for: review.id, now: t1)

    let t2 = t1.addingTimeInterval(0.05)
    model.handleTranscriptEvent(reviewID: review.id, at: t2, snippet: "second")
    model.recomputeStatus(for: review.id, now: t2)

    let t3 = t2.addingTimeInterval(1)
    model.recomputeStatus(for: review.id, now: t3)

    try await Task.sleep(nanoseconds: 100_000_000)
    let posted = await poster.posted
    #expect(posted.count == 1)
    #expect(posted.first?.reviewID == review.id)
}

private let sampleSearchHitJSON = """
[
  {
    "number": 944,
    "title": "centrifuge fix",
    "url": "https://github.com/bsv-blockchain/teranode/pull/944",
    "state": "open",
    "isDraft": false,
    "author": { "login": "icellan" },
    "repository": { "nameWithOwner": "bsv-blockchain/teranode" }
  }
]
"""

private let sampleMergedSearchHitJSON = """
[
  {
    "number": 944,
    "title": "centrifuge fix",
    "url": "https://github.com/bsv-blockchain/teranode/pull/944",
    "state": "merged",
    "isDraft": false,
    "author": { "login": "icellan" },
    "repository": { "nameWithOwner": "bsv-blockchain/teranode" }
  }
]
"""

private let emptySearchJSON = "[]"

private let prFetchJSON = """
{
  "number": 944,
  "title": "centrifuge fix",
  "url": "https://github.com/bsv-blockchain/teranode/pull/944",
  "state": "OPEN",
  "isDraft": false,
  "author": { "login": "icellan" },
  "headRefName": "fix/centrifuge",
  "baseRefName": "main",
  "closingIssuesReferences": []
}
"""

@Test @MainActor func discoverNowPopulatesNewReviews() async throws {
    let url = tempStoreURL()
    let seedStore = try ReviewStore(fileURL: url)
    var seed = Settings.default
    seed.reviewRequestQueries = [DiscoveryQuery(text: "review-requested:@me is:open")]
    seed.myPRsEnabled = false
    try await seedStore.updateSettings(seed)
    let store = try ReviewStore(fileURL: url)
    let runner = StubRunner(results: [
        CommandResult(exitCode: 0, standardOutput: "user\n", standardError: ""),
        CommandResult(exitCode: 0, standardOutput: sampleSearchHitJSON, standardError: ""),
        CommandResult(exitCode: 0, standardOutput: prFetchJSON, standardError: "")
    ])
    let client = GitHubClient(runner: runner, ghPath: "gh")
    let model = AppModel(
        store: store,
        client: client,
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.discoverNow()

    #expect(model.reviews.count == 1)
    #expect(model.reviews.first?.prRef?.number == 944)
    #expect(model.reviews.first?.origin == .discovered)
}

@Test @MainActor func discoverNowPromotesAddedToBoth() async throws {
    let url = tempStoreURL()
    let seedStore = try ReviewStore(fileURL: url)
    var seed = Settings.default
    seed.reviewRequestQueries = [DiscoveryQuery(text: "review-requested:@me is:open")]
    seed.myPRsEnabled = false
    try await seedStore.updateSettings(seed)
    let store = try ReviewStore(fileURL: url)
    try await store.upsertItem(sampleReview())
    let runner = StubRunner(results: [
        CommandResult(exitCode: 0, standardOutput: "user\n", standardError: ""),
        CommandResult(exitCode: 0, standardOutput: sampleSearchHitJSON, standardError: "")
    ])
    let client = GitHubClient(runner: runner, ghPath: "gh")
    let model = AppModel(
        store: store,
        client: client,
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.discoverNow()

    #expect(model.reviews.count == 1)
    #expect(model.reviews.first?.origin == .both)
}

@Test @MainActor func discoverNowKeepsPRsFallingOutOfQuery() async throws {
    let url = tempStoreURL()
    let seedStore = try ReviewStore(fileURL: url)
    var seed = Settings.default
    seed.reviewRequestQueries = [DiscoveryQuery(text: "review-requested:@me is:open")]
    seed.myPRsEnabled = false
    try await seedStore.updateSettings(seed)
    let store = try ReviewStore(fileURL: url)
    var existing = sampleReview()
    existing.origin = .discovered
    try await store.upsertItem(existing)
    let runner = StubRunner(results: [
        CommandResult(exitCode: 0, standardOutput: emptySearchJSON, standardError: ""),
        CommandResult(exitCode: 0, standardOutput: emptySearchJSON, standardError: "")
    ])
    let client = GitHubClient(runner: runner, ghPath: "gh")
    let model = AppModel(
        store: store,
        client: client,
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.discoverNow()

    #expect(model.reviews.count == 1)
    #expect(model.reviews.first?.prRef?.number == 944)
}

@Test @MainActor func discoverNowUpdatesPRState() async throws {
    let url = tempStoreURL()
    let seedStore = try ReviewStore(fileURL: url)
    var seed = Settings.default
    seed.reviewRequestQueries = [DiscoveryQuery(text: "review-requested:@me is:open")]
    seed.myPRsEnabled = false
    try await seedStore.updateSettings(seed)
    let store = try ReviewStore(fileURL: url)
    var existing = sampleReview()
    existing.prState = .open
    existing.origin = .discovered
    try await store.upsertItem(existing)
    let runner = StubRunner(results: [
        CommandResult(exitCode: 0, standardOutput: "user\n", standardError: ""),
        CommandResult(exitCode: 0, standardOutput: sampleMergedSearchHitJSON, standardError: "")
    ])
    let client = GitHubClient(runner: runner, ghPath: "gh")
    let model = AppModel(
        store: store,
        client: client,
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.discoverNow()

    #expect(model.reviews.first?.prState == .merged)
}

@Test @MainActor func discoverNowDeduplicatesAcrossQueries() async throws {
    let url = tempStoreURL()
    let seedStore = try ReviewStore(fileURL: url)
    var seed = Settings.default
    seed.reviewRequestQueries = [
        DiscoveryQuery(text: "review-requested:@me is:open"),
        DiscoveryQuery(text: "assignee:@me is:open"),
    ]
    seed.myPRsEnabled = false
    try await seedStore.updateSettings(seed)
    let store = try ReviewStore(fileURL: url)
    let runner = StubRunner(results: [
        CommandResult(exitCode: 0, standardOutput: "user\n", standardError: ""),
        CommandResult(exitCode: 0, standardOutput: sampleSearchHitJSON, standardError: ""),
        CommandResult(exitCode: 0, standardOutput: sampleSearchHitJSON, standardError: ""),
        CommandResult(exitCode: 0, standardOutput: prFetchJSON, standardError: "")
    ])
    let client = GitHubClient(runner: runner, ghPath: "gh")
    let model = AppModel(
        store: store,
        client: client,
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.discoverNow()

    #expect(model.reviews.count == 1)
}

@Test @MainActor func setDiffModePersists() async throws {
    let url = tempStoreURL()
    let store = try ReviewStore(fileURL: url)
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()
    #expect(model.diffMode == .unified)

    await model.setDiffMode(.split)

    #expect(model.diffMode == .split)
    let reloaded = try ReviewStore(fileURL: url)
    let settings = await reloaded.settings()
    #expect(settings.diffMode == .split)
}

@Test @MainActor func loadReadsPersistedDiffMode() async throws {
    let url = tempStoreURL()
    let seedStore = try ReviewStore(fileURL: url)
    var seedSettings = Settings.default
    seedSettings.diffMode = .split
    try await seedStore.updateSettings(seedSettings)
    let store = try ReviewStore(fileURL: url)
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )

    await model.load()

    #expect(model.diffMode == .split)
}

@Test @MainActor func loadReadsAllPersistedSettings() async throws {
    let url = tempStoreURL()
    let seedStore = try ReviewStore(fileURL: url)
    var seed = Settings.default
    seed.reviewRequestQueries = [DiscoveryQuery(text: "author:@me")]
    seed.myPRsEnabled = false
    seed.pollIntervalSeconds = 240
    seed.claudeLaunchArgs = "--model opus"
    seed.notificationsEnabled = false
    try await seedStore.updateSettings(seed)
    let store = try ReviewStore(fileURL: url)
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )

    await model.load()

    #expect(model.settings.reviewRequestQueries == [DiscoveryQuery(text: "author:@me")])
    #expect(model.settings.myPRsEnabled == false)
    #expect(model.settings.pollIntervalSeconds == 240)
    #expect(model.settings.claudeLaunchArgs == "--model opus")
    #expect(model.settings.notificationsEnabled == false)
}

@Test @MainActor func updateSettingsPersistsAndUpdatesInMemory() async throws {
    let url = tempStoreURL()
    let store = try ReviewStore(fileURL: url)
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    var newSettings = model.settings
    newSettings.reviewRequestQueries = [DiscoveryQuery(text: "assignee:foo is:open")]
    newSettings.myPRsEnabled = false
    newSettings.pollIntervalSeconds = 300
    await model.updateSettings(newSettings)

    #expect(model.settings.reviewRequestQueries == [DiscoveryQuery(text: "assignee:foo is:open")])
    #expect(model.settings.myPRsEnabled == false)
    #expect(model.settings.pollIntervalSeconds == 300)

    let reloaded = try ReviewStore(fileURL: url)
    let persisted = await reloaded.settings()
    #expect(persisted.reviewRequestQueries == [DiscoveryQuery(text: "assignee:foo is:open")])
    #expect(persisted.myPRsEnabled == false)
    #expect(persisted.pollIntervalSeconds == 300)
}

@Test @MainActor func setReviewDisabledPersistsFlag() async throws {
    let url = tempStoreURL()
    let store = try ReviewStore(fileURL: url)
    let review = sampleReview()
    try await store.upsertItem(review)
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()
    #expect(model.reviews.first?.disabled == false)

    await model.setReviewDisabled(true, for: review.id)

    #expect(model.reviews.first?.disabled == true)
    let reloaded = try ReviewStore(fileURL: url)
    let persisted = await reloaded.allItems().first
    #expect(persisted?.disabled == true)
}

@Test @MainActor func prefetchSkipsDisabledReview() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    var review = sampleReview()
    review.disabled = true
    try await store.upsertItem(review)
    let recorder = RecordingDiffLoader()
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: recorder,
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    model.prefetch(for: review)
    try await Task.sleep(nanoseconds: 200_000_000)

    let captured = await recorder.lastRegisteredClonePath
    #expect(captured == nil)
}

@Test @MainActor func discoverNowUsesCurrentSettingsQueries() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    var seed = Settings.default
    seed.reviewRequestQueries = [DiscoveryQuery(text: "author:@me custom:query")]
    seed.myPRsEnabled = false
    try await store.updateSettings(seed)
    let runner = StubRunner(results: [
        CommandResult(exitCode: 0, standardOutput: "user\n", standardError: ""),
        CommandResult(exitCode: 0, standardOutput: "[]", standardError: "")
    ])
    let client = GitHubClient(runner: runner, ghPath: "gh")
    let model = AppModel(
        store: store,
        client: client,
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.discoverNow()

    let args = await runner.recordedArguments
    let containsQuery = args.contains { $0.contains("custom:query") }
    #expect(containsQuery)
}

@Test @MainActor func updateSettingsTriggersPollWhenQueriesChange() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let runner = StubRunner(results: [
        CommandResult(exitCode: 0, standardOutput: "[]", standardError: ""),
        CommandResult(exitCode: 0, standardOutput: "[]", standardError: "")
    ])
    let client = GitHubClient(runner: runner, ghPath: "gh")
    let model = AppModel(
        store: store,
        client: client,
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    var updated = model.settings
    updated.reviewRequestQueries = [DiscoveryQuery(text: "author:@me custom:newquery")]
    updated.myPRsEnabled = false
    await model.updateSettings(updated)

    try await Task.sleep(nanoseconds: 250_000_000)

    let args = await runner.recordedArguments
    let containsNewQuery = args.contains { call in
        call.contains("custom:newquery")
    }
    #expect(containsNewQuery)
}

@Test @MainActor func markReviewOpenedPersistsTimestamp() async throws {
    let url = tempStoreURL()
    let store = try ReviewStore(fileURL: url)
    try await store.upsertItem(sampleReview())
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()
    let id = sampleReview().id

    await model.markReviewOpened(id)

    let reloaded = try ReviewStore(fileURL: url)
    let persisted = await reloaded.allItems().first
    #expect(persisted?.lastOpenedAt != nil)
}

@Test @MainActor func loadAutoSelectsMostRecentlyOpenedReview() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    var first = sampleReview()
    first.lastOpenedAt = Date(timeIntervalSince1970: 1_000_000)
    var second = WorkItem(
        title: "second",
        repoKey: "github.com/other/repo",
        baseBranch: "main",
        headBranch: "f",
        prRef: PRRef(
            owner: "other", repo: "repo", number: 1,
            url: URL(string: "https://github.com/other/repo/pull/1")!,
            authorLogin: "bob"
        ),
        prState: .open,
        origin: .added,
        addedAt: Date()
    )
    second.lastOpenedAt = Date(timeIntervalSince1970: 2_000_000)
    try await store.upsertItem(first)
    try await store.upsertItem(second)
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )

    await model.load()

    #expect(model.selection == second.id)
}

@Test @MainActor func updateSettingsDoesNotPollWhenQueriesUnchanged() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let runner = StubRunner(result: CommandResult(exitCode: 0, standardOutput: "[]", standardError: ""))
    let client = GitHubClient(runner: runner, ghPath: "gh")
    let model = AppModel(
        store: store,
        client: client,
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    var updated = model.settings
    updated.pollIntervalSeconds = 60
    await model.updateSettings(updated)

    try await Task.sleep(nanoseconds: 150_000_000)

    let args = await runner.recordedArguments
    let searchCallCount = args.filter { $0.first == "search" }.count
    #expect(searchCallCount == 0)
}

@Test @MainActor func loadDiffSkipsRunWhenAlreadyLoaded() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let recorder = RecordingDiffLoader()
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: recorder,
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()
    let review = sampleReview()

    await model.loadDiff(for: review)
    let firstCount = await recorder.callCount

    await model.loadDiff(for: review)
    let secondCount = await recorder.callCount

    #expect(firstCount == 1)
    #expect(secondCount == 1)
}

@Test @MainActor func loadDiffForceReruns() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let recorder = RecordingDiffLoader()
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: recorder,
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()
    let review = sampleReview()

    await model.loadDiff(for: review)
    await model.loadDiff(for: review, force: true)

    let count = await recorder.callCount
    #expect(count == 2)
}

@Test @MainActor func setFileViewedPersists() async throws {
    let url = tempStoreURL()
    let store = try ReviewStore(fileURL: url)
    try await store.upsertItem(sampleReview())
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.setFileViewed(true, filePath: "src/foo.swift", reviewID: sampleReview().id)

    #expect(model.reviews.first?.viewedFiles.contains("src/foo.swift") == true)
    let reloaded = try ReviewStore(fileURL: url)
    let persisted = await reloaded.allItems().first
    #expect(persisted?.viewedFiles.contains("src/foo.swift") == true)
}

@Test @MainActor func setFileViewedFalseRemovesEntry() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    var seeded = sampleReview()
    seeded.viewedFiles = ["a.swift", "b.swift"]
    try await store.upsertItem(seeded)
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.setFileViewed(false, filePath: "a.swift", reviewID: seeded.id)

    let viewed = model.reviews.first?.viewedFiles ?? []
    #expect(viewed == ["b.swift"])
}

@Test @MainActor func setFileViewedNoOpsWhenAlreadyInDesiredState() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    try await store.upsertItem(sampleReview())
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.setFileViewed(false, filePath: "x.swift", reviewID: sampleReview().id)
    #expect(model.reviews.first?.viewedFiles.isEmpty == true)

    await model.setFileViewed(true, filePath: "x.swift", reviewID: sampleReview().id)
    await model.setFileViewed(true, filePath: "x.swift", reviewID: sampleReview().id)
    #expect(model.reviews.first?.viewedFiles == ["x.swift"])
}

@Test @MainActor func loadCachesCurrentLogin() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let client = GitHubClient(runner: StubRunner(result: CommandResult(exitCode: 0, standardOutput: "ordishs\n", standardError: "")), ghPath: "gh")
    let model = AppModel(store: store, client: client, diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())

    await model.load()

    #expect(model.currentLogin == "ordishs")
}

@Test @MainActor func markClaudeReviewedStampsOnce() async throws {
    let url = tempStoreURL()
    let store = try ReviewStore(fileURL: url)
    try await store.upsertItem(sampleReview())
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())
    await model.load()

    await model.markClaudeReviewed(sampleReviewID)
    let first = model.reviews.first?.claudeReviewedAt
    #expect(first != nil)

    await model.markClaudeReviewed(sampleReviewID)
    #expect(model.reviews.first?.claudeReviewedAt == first)
}

@Test @MainActor func refreshReviewStateSetsApprovedByMe() async throws {
    let url = tempStoreURL()
    let store = try ReviewStore(fileURL: url)
    try await store.upsertItem(sampleReview())
    let reviewsJSON = """
    {"state":"OPEN","isDraft":false,"reviews":[{"author":{"login":"ordishs"},"state":"APPROVED"}]}
    """
    let prStatusJSON = """
    {"statusCheckRollup":[],"mergeStateStatus":"CLEAN","isDraft":false,"reviewDecision":"APPROVED"}
    """
    let client = GitHubClient(runner: StubRunner(results: [
        CommandResult(exitCode: 0, standardOutput: "ordishs\n", standardError: ""),
        CommandResult(exitCode: 0, standardOutput: reviewsJSON, standardError: ""),
        CommandResult(exitCode: 0, standardOutput: prStatusJSON, standardError: "")
    ]), ghPath: "gh")
    let model = AppModel(store: store, client: client, diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())
    await model.load()

    await model.refreshReviewState(for: sampleReviewID)

    #expect(model.reviews.first?.approvedByMe == true)
}

@Test @MainActor func refreshReviewStatesSkipsTerminalPRs() async throws {
    let url = tempStoreURL()
    let store = try ReviewStore(fileURL: url)
    var merged = sampleReview()
    merged.prState = .merged
    try await store.upsertItem(merged)
    let approvedJSON = """
    {"state":"OPEN","isDraft":false,"reviews":[{"author":{"login":"ordishs"},"state":"APPROVED"}]}
    """
    let client = GitHubClient(runner: StubRunner(results: [
        CommandResult(exitCode: 0, standardOutput: "ordishs\n", standardError: ""),
        CommandResult(exitCode: 0, standardOutput: approvedJSON, standardError: "")
    ]), ghPath: "gh")
    let model = AppModel(store: store, client: client, diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())
    await model.load()

    await model.refreshReviewStates()

    #expect(model.reviews.first?.approvedByMe == false)
    #expect(model.reviews.first?.prState == .merged)
}

@Test @MainActor func discoverSkipsUnscopedQueryAndWarns() async throws {
    let url = tempStoreURL()
    let seedStore = try ReviewStore(fileURL: url)
    var seed = Settings.default
    seed.reviewRequestQueries = [DiscoveryQuery(text: "is:open")]
    seed.myPRsEnabled = false
    try await seedStore.updateSettings(seed)
    let store = try ReviewStore(fileURL: url)
    let runner = StubRunner(results: [
        CommandResult(exitCode: 0, standardOutput: "user\n", standardError: ""),
    ])
    let client = GitHubClient(runner: runner, ghPath: "gh")
    let model = AppModel(
        store: store,
        client: client,
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.discoverNow()

    #expect(model.reviews.isEmpty)
    #expect(!model.discoveryWarnings.isEmpty)
    #expect(model.discoveryWarnings.first?.contains("is:open") == true)
}

@Test @MainActor func discoverRunsUnscopedQueryWhenAllowed() async throws {
    let url = tempStoreURL()
    let seedStore = try ReviewStore(fileURL: url)
    var seed = Settings.default
    seed.reviewRequestQueries = [DiscoveryQuery(text: "is:open", allowUnscoped: true)]
    seed.myPRsEnabled = false
    try await seedStore.updateSettings(seed)
    let store = try ReviewStore(fileURL: url)
    let runner = StubRunner(results: [
        CommandResult(exitCode: 0, standardOutput: "user\n", standardError: ""),
        CommandResult(exitCode: 0, standardOutput: sampleSearchHitJSON, standardError: ""),
        CommandResult(exitCode: 0, standardOutput: prFetchJSON, standardError: "")
    ])
    let client = GitHubClient(runner: runner, ghPath: "gh")
    let model = AppModel(
        store: store,
        client: client,
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.discoverNow()

    #expect(model.reviews.count == 1)
    #expect(model.discoveryWarnings.isEmpty)
}

@Test @MainActor func createTaskAddsAPRlessTaskSelected() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    try await store.upsert(RegisteredRepo(
        remoteIdentity: "github.com/o/r",
        localClonePath: "/tmp/clone",
        defaultBase: "main"
    ))
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.createTask(repoKey: "github.com/o/r", branch: "feat/spike")

    #expect(model.reviews.count == 1)
    let t = try #require(model.reviews.first)
    #expect(t.prRef == nil)
    #expect(t.headBranch == "feat/spike")
    #expect(t.baseBranch == "main")
    #expect(t.category(myLogin: "anyone") == .task)
    #expect(model.selection == t.id)
}

@Test @MainActor func createTaskRejectsEmptyBranch() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    try await store.upsert(RegisteredRepo(
        remoteIdentity: "github.com/o/r",
        localClonePath: "/tmp/clone",
        defaultBase: "main"
    ))
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.createTask(repoKey: "github.com/o/r", branch: "   ")

    #expect(model.reviews.isEmpty)
    #expect(model.errorMessage != nil)
}

private let taskSearchHitJSON = """
[
  {
    "number": 5,
    "title": "feat/x",
    "url": "https://github.com/o/r/pull/5",
    "state": "open",
    "isDraft": false,
    "author": { "login": "me" },
    "repository": { "nameWithOwner": "o/r" }
  }
]
"""

private let taskFetchJSON = """
{
  "number": 5,
  "title": "feat/x",
  "url": "https://github.com/o/r/pull/5",
  "state": "OPEN",
  "isDraft": false,
  "author": { "login": "me" },
  "headRefName": "feat/x",
  "baseRefName": "main",
  "closingIssuesReferences": []
}
"""

@Test @MainActor func discoveryGraduatesMatchingTaskInPlace() async throws {
    let url = tempStoreURL()
    let seedStore = try ReviewStore(fileURL: url)
    var seed = Settings.default
    seed.reviewRequestQueries = [DiscoveryQuery(text: "author:@me is:open")]
    seed.myPRsEnabled = false
    try await seedStore.updateSettings(seed)

    let store = try ReviewStore(fileURL: url)
    let task = WorkItem(
        title: "feat/x",
        repoKey: "github.com/o/r",
        baseBranch: "main",
        headBranch: "feat/x",
        prRef: nil,
        prState: nil,
        origin: .added,
        addedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    try await store.upsertItem(task)
    let taskID = task.id

    let runner = StubRunner(results: [
        CommandResult(exitCode: 0, standardOutput: "me\n", standardError: ""),
        CommandResult(exitCode: 0, standardOutput: taskSearchHitJSON, standardError: ""),
        CommandResult(exitCode: 0, standardOutput: taskFetchJSON, standardError: "")
    ])
    let client = GitHubClient(runner: runner, ghPath: "gh")
    let model = AppModel(
        store: store,
        client: client,
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.discoverNow()

    #expect(model.reviews.count == 1)
    let g = try #require(model.reviews.first)
    #expect(g.id == taskID)
    #expect(g.prRef?.number == 5)
    #expect(g.origin == .both)
    #expect(g.headBranch == "feat/x")
}

@Test @MainActor func refreshPopulatesPRStatus() async throws {
    let url = tempStoreURL()
    let store = try ReviewStore(fileURL: url)
    try await store.upsertItem(sampleReview())
    let reviewStateJSON = """
    {"state":"OPEN","isDraft":false,"reviews":[]}
    """
    let prStatusJSON = """
    {"statusCheckRollup":[{"status":"COMPLETED","conclusion":"FAILURE"}],"mergeStateStatus":"BEHIND","isDraft":false,"reviewDecision":null}
    """
    let client = GitHubClient(runner: StubRunner(results: [
        CommandResult(exitCode: 0, standardOutput: "ordishs\n", standardError: ""),
        CommandResult(exitCode: 0, standardOutput: reviewStateJSON, standardError: ""),
        CommandResult(exitCode: 0, standardOutput: prStatusJSON, standardError: "")
    ]), ghPath: "gh")
    let model = AppModel(store: store, client: client, diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())
    await model.load()

    await model.refreshReviewState(for: sampleReviewID)

    #expect(model.prStatuses[sampleReviewID]?.ci == .failing)
    #expect(model.prStatuses[sampleReviewID]?.isBehind == true)
}

@Test @MainActor func discoverSkipsCappedResultsAndWarns() async throws {
    let hundredHitsJSON: String = {
        let items = (0..<100).map { i in
            """
            {"number":\(i),"title":"t\(i)","url":"https://github.com/o/r/pull/\(i)","state":"open","isDraft":false,"author":{"login":"a"},"repository":{"nameWithOwner":"o/r"}}
            """
        }
        return "[" + items.joined(separator: ",") + "]"
    }()
    let url = tempStoreURL()
    let seedStore = try ReviewStore(fileURL: url)
    var seed = Settings.default
    seed.reviewRequestQueries = [DiscoveryQuery(text: "author:@me is:open")]
    seed.myPRsEnabled = false
    try await seedStore.updateSettings(seed)
    let store = try ReviewStore(fileURL: url)
    let runner = StubRunner(results: [
        CommandResult(exitCode: 0, standardOutput: "user\n", standardError: ""),
        CommandResult(exitCode: 0, standardOutput: hundredHitsJSON, standardError: "")
    ])
    let client = GitHubClient(runner: runner, ghPath: "gh")
    let model = AppModel(
        store: store,
        client: client,
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.discoverNow()

    #expect(model.reviews.isEmpty)
    #expect(!model.discoveryWarnings.isEmpty)
    #expect(model.discoveryWarnings.first?.contains("100+") == true)
}

private func editableItem(worktreePath: String = "/tmp/wt", headBranch: String = "feat/x", baseBranch: String = "main") -> WorkItem {
    WorkItem(
        title: headBranch,
        repoKey: "github.com/o/r",
        baseBranch: baseBranch,
        headBranch: headBranch,
        worktreePath: worktreePath,
        prRef: nil,
        prState: nil,
        origin: .added,
        addedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

@Test @MainActor func rebaseCleanClearsConflictState() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let item = editableItem()
    try await store.upsertItem(item)
    let stub = StubWorktreeOps()
    await stub.set(rebaseResult: .clean)
    await stub.set(currentBranchResult: "feat/x")
    await stub.set(aheadBehindDefaultResult: (0, 0))
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: stub,
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.rebase(id: item.id)

    #expect(model.rebaseStates[item.id] == nil)
}

@Test @MainActor func rebaseConflictSetsConflictedStateAndAbortClears() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let item = editableItem()
    try await store.upsertItem(item)
    let stub = StubWorktreeOps()
    await stub.set(rebaseResult: .conflicts(["a.swift"]))
    await stub.set(currentBranchResult: nil)
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: stub,
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.rebase(id: item.id)

    #expect(model.rebaseStates[item.id] == .conflicted(["a.swift"]))

    await model.abortRebase(id: item.id)

    #expect(model.rebaseStates[item.id] == nil)
}

@Test @MainActor func pushabilityReflectsAheadBehind() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let item = editableItem()
    try await store.upsertItem(item)
    let stub = StubWorktreeOps()
    await stub.set(currentBranchResult: "feat/x")

    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: stub,
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await stub.set(aheadBehindByUpstream: ["origin/feat/x": (ahead: 2, behind: 0)])
    await model.refreshPushability(for: item.id)
    #expect(model.pushability[item.id]?.canPush == true)
    #expect(model.pushability[item.id]?.needsForce == false)

    await stub.set(aheadBehindByUpstream: ["origin/feat/x": (ahead: 1, behind: 3)])
    await model.refreshPushability(for: item.id)
    #expect(model.pushability[item.id]?.canPush == true)
    #expect(model.pushability[item.id]?.needsForce == true)

    await stub.set(aheadBehindByUpstream: ["origin/feat/x": (ahead: 0, behind: 0)])
    await model.refreshPushability(for: item.id)
    #expect(model.pushability[item.id]?.canPush == false)
}

@Test @MainActor func pushabilityFallsBackForNeverPushedBranch() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let item = editableItem()
    try await store.upsertItem(item)
    let stub = StubWorktreeOps()
    await stub.set(currentBranchResult: "feat/x")
    await stub.set(shouldThrowAheadBehind: ["origin/feat/x"])
    await stub.set(aheadBehindByUpstream: ["origin/main": (ahead: 1, behind: 0)])
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: stub,
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.refreshPushability(for: item.id)

    #expect(model.pushability[item.id]?.canPush == true)
    #expect(model.pushability[item.id]?.needsForce == false)
}
