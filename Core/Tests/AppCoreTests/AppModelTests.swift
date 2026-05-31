import Testing
import Foundation
import PRReviewModels
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
    func loadDiff(for review: Review, registeredClonePath: String?) async throws -> DiffResult {
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
    func loadDiff(for review: Review, registeredClonePath: String?) async throws -> DiffResult {
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
    func ensureWorktree(for review: Review, registeredClonePath: String?) async throws -> WorktreeReady {
        if shouldThrow {
            throw WorktreeError.gitFailed(arguments: ["stub"], exitCode: 1, message: "stub failure")
        }
        return result
    }
}

private func sampleReview() -> Review {
    Review(
        owner: "bsv-blockchain", repo: "teranode", number: 944,
        url: URL(string: "https://github.com/bsv-blockchain/teranode/pull/944")!,
        title: "centrifuge fix", author: "icellan",
        headBranch: "fix/centrifuge", baseBranch: "main",
        origin: .added, prState: .open, addedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

private func stubClient() -> GitHubClient {
    GitHubClient(runner: StubRunner(result: CommandResult(exitCode: 0, standardOutput: "", standardError: "")), ghPath: "gh")
}

@Test @MainActor func addPRFetchesStoresAndSelects() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let client = GitHubClient(runner: StubRunner(result: CommandResult(exitCode: 0, standardOutput: prJSON, standardError: "")), ghPath: "gh")
    let model = AppModel(store: store, client: client, diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())

    await model.addPR(urlString: "https://github.com/bsv-blockchain/teranode/pull/944")

    #expect(model.reviews.count == 1)
    #expect(model.reviews.first?.id == "bsv-blockchain/teranode#944")
    #expect(model.selection == "bsv-blockchain/teranode#944")
    #expect(model.errorMessage == nil)
}

@Test @MainActor func addPRSetsErrorOnInvalidURL() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let client = GitHubClient(runner: StubRunner(result: CommandResult(exitCode: 0, standardOutput: "", standardError: "")), ghPath: "gh")
    let model = AppModel(store: store, client: client, diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())

    await model.addPR(urlString: "not a pr url")

    #expect(model.reviews.isEmpty)
    #expect(model.errorMessage != nil)
}

@Test @MainActor func addPRSurfacesCommandFailureAndDismisses() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let client = GitHubClient(runner: StubRunner(result: CommandResult(exitCode: 1, standardOutput: "", standardError: "no pull requests found")), ghPath: "gh")
    let model = AppModel(store: store, client: client, diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())

    await model.addPR(urlString: "https://github.com/bsv-blockchain/teranode/pull/944")

    #expect(model.reviews.isEmpty)
    #expect(model.errorMessage != nil)

    model.dismissError()
    #expect(model.errorMessage == nil)
}

@Test @MainActor func loadReadsExistingReviews() async throws {
    let url = tempStoreURL()
    let seedStore = try ReviewStore(fileURL: url)
    try await seedStore.upsert(Review(
        owner: "bsv-blockchain", repo: "teranode", number: 901,
        url: URL(string: "https://github.com/bsv-blockchain/teranode/pull/901")!,
        title: "prune", author: "jad", headBranch: "prune", baseBranch: "main",
        origin: .added, prState: .open, addedAt: Date(timeIntervalSince1970: 1_700_000_000)
    ))
    let client = GitHubClient(runner: StubRunner(result: CommandResult(exitCode: 0, standardOutput: "", standardError: "")), ghPath: "gh")
    let model = AppModel(store: try ReviewStore(fileURL: url), client: client, diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())

    await model.load()

    #expect(model.reviews.count == 1)
    #expect(model.reviews.first?.number == 901)
}

@Test @MainActor func loadDiffSetsLoadedState() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let file = DiffFile(oldPath: "foo.txt", newPath: "foo.txt", changeKind: .modified, hunks: [], addedCount: 1, removedCount: 0)
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(files: [file]), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())

    await model.loadDiff(for: sampleReview())

    #expect(model.diffStates[sampleReview().id] == .loaded([file]))
}

@Test @MainActor func loadDiffSetsFailedStateOnError() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(shouldThrow: true), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())

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
    try await store.upsert(review)
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(files: []), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())
    await model.load()

    await model.loadDiff(for: review)

    let reloaded = try ReviewStore(fileURL: url)
    #expect(await reloaded.allReviews().first?.worktreePath == "/tmp/wt")
}

@Test @MainActor func registerCloneSucceedsAndPersists() async throws {
    let url = tempStoreURL()
    let store = try ReviewStore(fileURL: url)
    let review = sampleReview()
    try await store.upsert(review)
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())
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
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: registrar, claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())

    await model.registerClone(for: sampleReview(), localPath: "/wrong/path")

    #expect(model.errorMessage != nil)
    #expect(model.registeredClonePath(for: sampleReview()) == nil)
}

@Test @MainActor func loadDiffPassesRegisteredClonePathToLoader() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let review = sampleReview()
    try await store.upsert(review)
    try await store.upsert(RegisteredRepo(
        remoteIdentity: "github.com/bsv-blockchain/teranode",
        localClonePath: "/Users/me/dev/teranode",
        defaultBase: "main"
    ))
    let recorder = RecordingDiffLoader()
    let model = AppModel(store: store, client: stubClient(), diffLoader: recorder, worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())
    await model.load()

    await model.loadDiff(for: review)

    let captured = await recorder.lastRegisteredClonePath
    #expect(captured == "/Users/me/dev/teranode")
}

@Test @MainActor func loadDiffPassesNilWhenNoRegisteredClone() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let review = sampleReview()
    try await store.upsert(review)
    let recorder = RecordingDiffLoader()
    let model = AppModel(store: store, client: stubClient(), diffLoader: recorder, worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())
    await model.load()

    await model.loadDiff(for: review)

    let captured = await recorder.lastRegisteredClonePath
    #expect(captured == nil)
}

@Test @MainActor func registerLocalCloneRegistersAllDetected() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let registrar = StubRegistrar(detectedRepositories: ["ordishs/teranode", "bsv-blockchain/teranode"])
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: registrar, claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())

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
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: registrar, claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())

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
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())
    await model.load()
    #expect(model.registeredRepos.count == 1)

    await model.removeRegisteredRepo(remoteIdentity: "github.com/bsv-blockchain/teranode")

    #expect(model.registeredRepos.isEmpty)
}

@Test @MainActor func removeReviewRemovesFromStoreAndClearsSelection() async throws {
    let url = tempStoreURL()
    let store = try ReviewStore(fileURL: url)
    let review = sampleReview()
    try await store.upsert(review)
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())
    await model.load()
    model.selection = review.id

    await model.removeReview(id: review.id)

    #expect(model.reviews.isEmpty)
    #expect(model.selection == nil)
    let reloaded = try ReviewStore(fileURL: url)
    #expect(await reloaded.allReviews().isEmpty)
}

@Test @MainActor func removeReviewBestEffortRemovesWorktreeDir() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let tempWorktree = FileManager.default.temporaryDirectory
        .appendingPathComponent("wt-\(UUID().uuidString)", isDirectory: true)
        .path
    try FileManager.default.createDirectory(atPath: tempWorktree, withIntermediateDirectories: true)
    var review = sampleReview()
    review.worktreePath = tempWorktree
    try await store.upsert(review)
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())
    await model.load()

    await model.removeReview(id: review.id)

    #expect(model.reviews.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: tempWorktree))
}

@Test @MainActor func ensureClaudeSessionFlagsWorktreeFailure() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(shouldThrow: true),
        cloneRegistrar: StubRegistrar(),
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
    try await store.upsert(review)
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
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
    try await store.upsert(review)
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
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

@Test @MainActor func firstIdleTransitionFiresNotificationOnce() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let review = sampleReview()
    try await store.upsert(review)
    let poster = StubNotificationPoster()
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
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
    let store = try ReviewStore(fileURL: tempStoreURL())
    let runner = StubRunner(results: [
        CommandResult(exitCode: 0, standardOutput: "user\n", standardError: ""),
        CommandResult(exitCode: 0, standardOutput: sampleSearchHitJSON, standardError: ""),
        CommandResult(exitCode: 0, standardOutput: emptySearchJSON, standardError: ""),
        CommandResult(exitCode: 0, standardOutput: prFetchJSON, standardError: "")
    ])
    let client = GitHubClient(runner: runner, ghPath: "gh")
    let model = AppModel(
        store: store,
        client: client,
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.discoverNow()

    #expect(model.reviews.count == 1)
    #expect(model.reviews.first?.id == "bsv-blockchain/teranode#944")
    #expect(model.reviews.first?.origin == .discovered)
}

@Test @MainActor func discoverNowPromotesAddedToBoth() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    try await store.upsert(sampleReview())
    let runner = StubRunner(results: [
        CommandResult(exitCode: 0, standardOutput: "user\n", standardError: ""),
        CommandResult(exitCode: 0, standardOutput: sampleSearchHitJSON, standardError: ""),
        CommandResult(exitCode: 0, standardOutput: emptySearchJSON, standardError: "")
    ])
    let client = GitHubClient(runner: runner, ghPath: "gh")
    let model = AppModel(
        store: store,
        client: client,
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.discoverNow()

    #expect(model.reviews.count == 1)
    #expect(model.reviews.first?.origin == .both)
}

@Test @MainActor func discoverNowKeepsPRsFallingOutOfQuery() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    var existing = sampleReview()
    existing.origin = .discovered
    try await store.upsert(existing)
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
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.discoverNow()

    #expect(model.reviews.count == 1)
    #expect(model.reviews.first?.id == "bsv-blockchain/teranode#944")
}

@Test @MainActor func discoverNowUpdatesPRState() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    var existing = sampleReview()
    existing.prState = .open
    existing.origin = .discovered
    try await store.upsert(existing)
    let runner = StubRunner(results: [
        CommandResult(exitCode: 0, standardOutput: "user\n", standardError: ""),
        CommandResult(exitCode: 0, standardOutput: sampleMergedSearchHitJSON, standardError: ""),
        CommandResult(exitCode: 0, standardOutput: emptySearchJSON, standardError: "")
    ])
    let client = GitHubClient(runner: runner, ghPath: "gh")
    let model = AppModel(
        store: store,
        client: client,
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.discoverNow()

    #expect(model.reviews.first?.prState == .merged)
}

@Test @MainActor func discoverNowDeduplicatesAcrossQueries() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
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
    seed.discoveryQueries = ["author:@me"]
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
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )

    await model.load()

    #expect(model.settings.discoveryQueries == ["author:@me"])
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
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    var newSettings = model.settings
    newSettings.discoveryQueries = ["assignee:foo is:open"]
    newSettings.pollIntervalSeconds = 300
    await model.updateSettings(newSettings)

    #expect(model.settings.discoveryQueries == ["assignee:foo is:open"])
    #expect(model.settings.pollIntervalSeconds == 300)

    let reloaded = try ReviewStore(fileURL: url)
    let persisted = await reloaded.settings()
    #expect(persisted.discoveryQueries == ["assignee:foo is:open"])
    #expect(persisted.pollIntervalSeconds == 300)
}

@Test @MainActor func setReviewDisabledPersistsFlag() async throws {
    let url = tempStoreURL()
    let store = try ReviewStore(fileURL: url)
    let review = sampleReview()
    try await store.upsert(review)
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()
    #expect(model.reviews.first?.disabled == false)

    await model.setReviewDisabled(true, for: review.id)

    #expect(model.reviews.first?.disabled == true)
    let reloaded = try ReviewStore(fileURL: url)
    let persisted = await reloaded.allReviews().first
    #expect(persisted?.disabled == true)
}

@Test @MainActor func prefetchSkipsDisabledReview() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    var review = sampleReview()
    review.disabled = true
    try await store.upsert(review)
    let recorder = RecordingDiffLoader()
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: recorder,
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
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
    seed.discoveryQueries = ["custom:query"]
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
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    var updated = model.settings
    updated.discoveryQueries = ["custom:newquery is:open"]
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
    try await store.upsert(sampleReview())
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()
    let id = sampleReview().id

    await model.markReviewOpened(id)

    let reloaded = try ReviewStore(fileURL: url)
    let persisted = await reloaded.allReviews().first
    #expect(persisted?.lastOpenedAt != nil)
}

@Test @MainActor func loadAutoSelectsMostRecentlyOpenedReview() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    var first = sampleReview()
    first.lastOpenedAt = Date(timeIntervalSince1970: 1_000_000)
    var second = Review(
        owner: "other", repo: "repo", number: 1,
        url: URL(string: "https://github.com/other/repo/pull/1")!,
        title: "second", author: "bob",
        headBranch: "f", baseBranch: "main",
        origin: .added, prState: .open, addedAt: Date()
    )
    second.lastOpenedAt = Date(timeIntervalSince1970: 2_000_000)
    try await store.upsert(first)
    try await store.upsert(second)
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
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
    try await store.upsert(sampleReview())
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.setFileViewed(true, filePath: "src/foo.swift", reviewID: sampleReview().id)

    #expect(model.reviews.first?.viewedFiles.contains("src/foo.swift") == true)
    let reloaded = try ReviewStore(fileURL: url)
    let persisted = await reloaded.allReviews().first
    #expect(persisted?.viewedFiles.contains("src/foo.swift") == true)
}

@Test @MainActor func setFileViewedFalseRemovesEntry() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    var seeded = sampleReview()
    seeded.viewedFiles = ["a.swift", "b.swift"]
    try await store.upsert(seeded)
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
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
    try await store.upsert(sampleReview())
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
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
    let model = AppModel(store: store, client: client, diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())

    await model.load()

    #expect(model.currentLogin == "ordishs")
}

@Test @MainActor func markClaudeReviewedStampsOnce() async throws {
    let url = tempStoreURL()
    let store = try ReviewStore(fileURL: url)
    try await store.upsert(sampleReview())
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())
    await model.load()

    await model.markClaudeReviewed("bsv-blockchain/teranode#944")
    let first = model.reviews.first?.claudeReviewedAt
    #expect(first != nil)

    await model.markClaudeReviewed("bsv-blockchain/teranode#944")
    #expect(model.reviews.first?.claudeReviewedAt == first)
}

@Test @MainActor func refreshReviewStateSetsApprovedByMe() async throws {
    let url = tempStoreURL()
    let store = try ReviewStore(fileURL: url)
    try await store.upsert(sampleReview())
    let reviewsJSON = """
    {"state":"OPEN","isDraft":false,"reviews":[{"author":{"login":"ordishs"},"state":"APPROVED"}]}
    """
    let client = GitHubClient(runner: StubRunner(results: [
        CommandResult(exitCode: 0, standardOutput: "ordishs\n", standardError: ""),
        CommandResult(exitCode: 0, standardOutput: reviewsJSON, standardError: "")
    ]), ghPath: "gh")
    let model = AppModel(store: store, client: client, diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())
    await model.load()

    await model.refreshReviewState(for: "bsv-blockchain/teranode#944")

    #expect(model.reviews.first?.approvedByMe == true)
}

@Test @MainActor func refreshReviewStatesSkipsTerminalPRs() async throws {
    let url = tempStoreURL()
    let store = try ReviewStore(fileURL: url)
    var merged = sampleReview()
    merged.prState = .merged
    try await store.upsert(merged)
    let approvedJSON = """
    {"state":"OPEN","isDraft":false,"reviews":[{"author":{"login":"ordishs"},"state":"APPROVED"}]}
    """
    let client = GitHubClient(runner: StubRunner(results: [
        CommandResult(exitCode: 0, standardOutput: "ordishs\n", standardError: ""),
        CommandResult(exitCode: 0, standardOutput: approvedJSON, standardError: "")
    ]), ghPath: "gh")
    let model = AppModel(store: store, client: client, diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())
    await model.load()

    await model.refreshReviewStates()

    #expect(model.reviews.first?.approvedByMe == false)
    #expect(model.reviews.first?.prState == .merged)
}
