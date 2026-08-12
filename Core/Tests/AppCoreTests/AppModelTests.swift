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
    private(set) var repairedWorktreePaths: [String] = []
    func repairWorktree(worktreePath: String) async throws {
        repairedWorktreePaths.append(worktreePath)
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

@Test @MainActor func removeReviewNeverDeletesRegisteredClone() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let clonePath = FileManager.default.temporaryDirectory
        .appendingPathComponent("clone-\(UUID().uuidString)", isDirectory: true)
        .path
    try FileManager.default.createDirectory(atPath: clonePath, withIntermediateDirectories: true)
    let sentinel = clonePath + "/.git"
    try FileManager.default.createDirectory(atPath: sentinel, withIntermediateDirectories: true)
    try await store.upsert(RegisteredRepo(
        remoteIdentity: "github.com/bsv-blockchain/teranode",
        localClonePath: clonePath,
        defaultBase: "main"
    ))
    var review = sampleReview()
    review.worktreePath = clonePath
    try await store.upsertItem(review)
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())
    await model.load()

    await model.removeReview(id: review.id)

    #expect(model.reviews.isEmpty)
    #expect(FileManager.default.fileExists(atPath: clonePath))
    #expect(FileManager.default.fileExists(atPath: sentinel))
    #expect(model.errorMessage?.contains("registered repository clone") == true)

    try? FileManager.default.removeItem(atPath: clonePath)
}

@Test @MainActor func removeReviewDeletesWorktreeInsideCloneParent() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let clonePath = FileManager.default.temporaryDirectory
        .appendingPathComponent("clone-\(UUID().uuidString)", isDirectory: true)
        .path
    try FileManager.default.createDirectory(atPath: clonePath, withIntermediateDirectories: true)
    try await store.upsert(RegisteredRepo(
        remoteIdentity: "github.com/bsv-blockchain/teranode",
        localClonePath: clonePath,
        defaultBase: "main"
    ))
    let worktree = FileManager.default.temporaryDirectory
        .appendingPathComponent("wt-\(UUID().uuidString)", isDirectory: true)
        .path
    try FileManager.default.createDirectory(atPath: worktree, withIntermediateDirectories: true)
    var review = sampleReview()
    review.worktreePath = worktree
    try await store.upsertItem(review)
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())
    await model.load()

    await model.removeReview(id: review.id)

    #expect(!FileManager.default.fileExists(atPath: worktree))
    #expect(FileManager.default.fileExists(atPath: clonePath))

    try? FileManager.default.removeItem(atPath: clonePath)
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

    // Completing a turn now yields .awaitingInput, which fires the "needs you" notification.
    let posted = await poster.posted
    #expect(posted.count == 1)
    #expect(posted.first?.reviewID == review.id)
}

@Test @MainActor func awaitingInputFiresNotificationOnceAndRearms() async throws {
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

    // All transitions run synchronously (no await) so the stub process cannot
    // exit mid-sequence; the single sleep at the end flushes the notification Tasks.
    let t0 = Date()
    model.handleTranscriptEvent(reviewID: review.id, at: t0, snippet: "working", turnCompleted: false)
    model.recomputeStatus(for: review.id, now: t0)                       // working
    let t1 = t0.addingTimeInterval(1)
    model.handleTranscriptEvent(reviewID: review.id, at: t1, snippet: "done", turnCompleted: true)
    model.recomputeStatus(for: review.id, now: t1)                       // awaitingInput -> fire #1
    model.recomputeStatus(for: review.id, now: t1.addingTimeInterval(1)) // still awaiting -> no fire
    let t2 = t1.addingTimeInterval(2)
    model.handleTranscriptEvent(reviewID: review.id, at: t2, snippet: "more", turnCompleted: false)
    model.recomputeStatus(for: review.id, now: t2)                       // working -> re-arm
    let t3 = t2.addingTimeInterval(1)
    model.handleTranscriptEvent(reviewID: review.id, at: t3, snippet: "done2", turnCompleted: true)
    model.recomputeStatus(for: review.id, now: t3)                       // awaitingInput -> fire #2

    try await Task.sleep(nanoseconds: 200_000_000)
    let posted = await poster.posted
    #expect(posted.count == 2)
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
    seed.issuesEnabled = false
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
    seed.issuesEnabled = false
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

    await model.markClaudeTurnCompleted(sampleReviewID)
    let first = model.reviews.first?.claudeReviewedAt
    let firstCompletion = model.reviews.first?.claudeLastCompletedAt
    #expect(first != nil)
    #expect(firstCompletion != nil)

    await model.markClaudeTurnCompleted(sampleReviewID)
    #expect(model.reviews.first?.claudeReviewedAt == first)
    #expect(model.reviews.first?.claudeLastCompletedAt != firstCompletion)
}

@Test @MainActor func refreshReviewStateSetsApprovedByMe() async throws {
    let url = tempStoreURL()
    let store = try ReviewStore(fileURL: url)
    try await store.upsertItem(sampleReview())
    let snapshotJSON = """
    {"data":{"repository":{"pullRequest":{
      "state":"OPEN","isDraft":false,"reviewDecision":"APPROVED","mergeStateStatus":"CLEAN",
      "author":{"login":"icellan"},
      "commits":{"nodes":[{"commit":{"committedDate":null,"statusCheckRollup":null}}]},
      "reviews":{"nodes":[{"author":{"login":"ordishs"},"state":"APPROVED","submittedAt":"2026-08-06T09:00:00Z"}]},
      "reviewThreads":{"nodes":[]},
      "timelineItems":{"nodes":[]}
    }}}}
    """
    let client = GitHubClient(runner: StubRunner(results: [
        CommandResult(exitCode: 0, standardOutput: "ordishs\n", standardError: ""),
        CommandResult(exitCode: 0, standardOutput: snapshotJSON, standardError: "")
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
    seed.issuesEnabled = false
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
    seed.issuesEnabled = false
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
    let snapshotJSON = """
    {"data":{"repository":{"pullRequest":{
      "state":"OPEN","isDraft":false,"reviewDecision":null,"mergeStateStatus":"BEHIND",
      "author":{"login":"icellan"},
      "commits":{"nodes":[{"commit":{"committedDate":"2026-08-06T11:00:00Z","statusCheckRollup":
        {"state":"FAILURE","contexts":{"totalCount":1,"nodes":[{"status":"COMPLETED","conclusion":"FAILURE"}]}}}}]},
      "reviews":{"nodes":[{"author":{"login":"ordishs"},"state":"CHANGES_REQUESTED","submittedAt":"2026-08-06T09:00:00Z"}]},
      "reviewThreads":{"nodes":[]},
      "timelineItems":{"nodes":[]}
    }}}}
    """
    let client = GitHubClient(runner: StubRunner(results: [
        CommandResult(exitCode: 0, standardOutput: "ordishs\n", standardError: ""),
        CommandResult(exitCode: 0, standardOutput: snapshotJSON, standardError: "")
    ]), ghPath: "gh")
    let model = AppModel(store: store, client: client, diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())
    await model.load()

    await model.refreshReviewState(for: sampleReviewID)

    #expect(model.prStatuses[sampleReviewID]?.ci == .failing)
    #expect(model.prStatuses[sampleReviewID]?.isBehind == true)
    // The author pushed at 11:00, after the 09:00 change request — the "Updated" chip data
    // has to reach the model, not just the client.
    #expect(model.prStatuses[sampleReviewID]?.authorUpdatedAt == ISO8601DateFormatter().date(from: "2026-08-06T11:00:00Z"))
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

@Test @MainActor func ensureClaudeSessionPopulatesPushabilityForEditableItem() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let item = editableItem()
    try await store.upsertItem(item)
    let stub = StubWorktreeOps()
    await stub.set(currentBranchResult: "feat/x")
    await stub.set(aheadBehindByUpstream: ["origin/feat/x": (ahead: 1, behind: 0)])
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

    await model.ensureClaudeSession(for: item)

    #expect(model.pushability[item.id]?.canPush == true)
    #expect(model.pushability[item.id]?.needsForce == false)
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

@Test @MainActor func setTerminalAppearanceFlipsOnlyOnChange() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())

    #expect(model.terminalIsDark == true)
    await model.setTerminalAppearance(isDark: true)   // no-op
    #expect(model.terminalIsDark == true)
    await model.setTerminalAppearance(isDark: false)  // flips; no selection → no relaunch
    #expect(model.terminalIsDark == false)
}

private let issueViewJSON = """
{
  "number": 42,
  "title": "Login crash",
  "url": "https://github.com/bsv-blockchain/teranode/issues/42",
  "state": "OPEN",
  "author": { "login": "alice" }
}
"""
private let repoViewJSON = """
{ "isFork": false, "parent": null, "defaultBranchRef": { "name": "main" } }
"""

@Test @MainActor func addIssueFetchesStoresAndSelects() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    // fetchIssue → gh issue view, then gh repo view (fetchDefaultBase).
    let client = GitHubClient(runner: StubRunner(results: [
        CommandResult(exitCode: 0, standardOutput: issueViewJSON, standardError: ""),
        CommandResult(exitCode: 0, standardOutput: repoViewJSON, standardError: ""),
    ]), ghPath: "gh")
    let model = AppModel(store: store, client: client, diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())

    await model.addIssue(urlString: "https://github.com/bsv-blockchain/teranode/issues/42")

    #expect(model.reviews.count == 1)
    let item = try #require(model.reviews.first)
    #expect(item.issueRef?.number == 42)
    #expect(item.prRef == nil)
    #expect(item.headBranch == "issue-42-login-crash")
    #expect(item.category(myLogin: nil) == .issue)
    #expect(model.selection == item.id)
    #expect(model.errorMessage == nil)
}

@Test @MainActor func addIssueSetsErrorOnInvalidURL() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let client = GitHubClient(runner: StubRunner(result: CommandResult(exitCode: 0, standardOutput: "", standardError: "")), ghPath: "gh")
    let model = AppModel(store: store, client: client, diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())

    await model.addIssue(urlString: "https://github.com/o/r/pull/7")

    #expect(model.reviews.isEmpty)
    #expect(model.errorMessage != nil)
}

private let issueSearchHitJSON = """
[
  {
    "number": 42,
    "title": "Login crash",
    "url": "https://github.com/bsv-blockchain/teranode/issues/42",
    "state": "open",
    "author": { "login": "alice" },
    "repository": { "nameWithOwner": "bsv-blockchain/teranode" }
  }
]
"""

@Test @MainActor func discoverNowCreatesDiscoveredIssue() async throws {
    let url = tempStoreURL()
    let seedStore = try ReviewStore(fileURL: url)
    var seed = Settings.default
    seed.reviewRequestsEnabled = false
    seed.myPRsEnabled = false
    seed.issuesEnabled = true
    seed.issueQueries = [DiscoveryQuery(text: "assignee:@me is:open")]
    try await seedStore.updateSettings(seed)
    let store = try ReviewStore(fileURL: url)
    let runner = StubRunner(results: [
        CommandResult(exitCode: 0, standardOutput: "user\n", standardError: ""),
        CommandResult(exitCode: 0, standardOutput: issueSearchHitJSON, standardError: ""),
        CommandResult(exitCode: 0, standardOutput: issueViewJSON, standardError: ""),
        CommandResult(exitCode: 0, standardOutput: repoViewJSON, standardError: ""),
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
    let item = try #require(model.reviews.first)
    #expect(item.issueRef?.number == 42)
    #expect(item.prRef == nil)
    #expect(item.origin == .discovered)
    #expect(item.headBranch == "issue-42-login-crash")
    #expect(item.category(myLogin: "user") == .issue)
}

@Test @MainActor func setIssueStatusSetsAndClearsManualOverride() async throws {
    let url = tempStoreURL()
    let store = try ReviewStore(fileURL: url)
    let issue = WorkItem(
        title: "Login crash",
        repoKey: "github.com/bsv-blockchain/teranode",
        baseBranch: "main",
        headBranch: "issue-42-login-crash",
        issueRef: IssueRef(owner: "bsv-blockchain", repo: "teranode", number: 42,
            url: URL(string: "https://github.com/bsv-blockchain/teranode/issues/42")!, authorLogin: "alice"),
        prState: .open,
        origin: .discovered,
        addedAt: Date()
    )
    try await store.upsertItem(issue)
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())
    await model.load()

    await model.setIssueStatus(.onHold, for: issue.id)
    #expect(model.reviews.first(where: { $0.id == issue.id })?.manualIssueStatus == .onHold)

    // Persistence: a fresh store over the same file reflects the override.
    let reopened = try ReviewStore(fileURL: url)
    #expect(await reopened.item(id: issue.id)?.manualIssueStatus == .onHold)

    await model.setIssueStatus(nil, for: issue.id)
    #expect(model.reviews.first(where: { $0.id == issue.id })?.manualIssueStatus == nil)
}

@Test @MainActor func refreshPushabilityStoresAheadBehindCounts() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let review = sampleReview()
    try await store.upsertItem(review)
    let ops = StubWorktreeOps()
    await ops.set(currentBranchResult: "fix/centrifuge")
    await ops.set(aheadBehindByUpstream: ["origin/fix/centrifuge": (ahead: 3, behind: 2)])
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: ops,
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()
    await model.ensureClaudeSession(for: review)   // sets worktreePath via the stub provider
    await model.refreshPushability(for: review.id)

    let p = model.pushability[review.id]
    #expect(p?.ahead == 3)
    #expect(p?.behind == 2)
    #expect(p?.canPush == true)
    #expect(p?.needsForce == true)
}

@Test @MainActor func refreshPushabilityFallsBackToBaseWithZeroBehind() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let review = sampleReview()   // headBranch "fix/centrifuge", baseBranch "main"
    try await store.upsertItem(review)
    let ops = StubWorktreeOps()
    await ops.set(currentBranchResult: "fix/centrifuge")
    await ops.set(shouldThrowAheadBehind: ["origin/fix/centrifuge"])   // upstream path unavailable
    await ops.set(aheadBehindByUpstream: ["origin/main": (ahead: 1, behind: 5)])
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: ops,
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()
    await model.ensureClaudeSession(for: review)
    await model.refreshPushability(for: review.id)

    let p = model.pushability[review.id]
    #expect(p?.ahead == 1)
    #expect(p?.behind == 0)        // base-fallback forces behind to 0
    #expect(p?.canPush == true)
    #expect(p?.needsForce == false)
}

@Test @MainActor func setLabelPersistsTrimmedValue() async throws {
    let url = tempStoreURL()
    let store = try ReviewStore(fileURL: url)
    try await store.upsertItem(sampleReview())
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())
    await model.load()

    await model.setLabel("  Blocks the mainnet upgrade  ", for: sampleReviewID)

    #expect(model.reviews.first?.label == "Blocks the mainnet upgrade")
    let reloaded = try ReviewStore(fileURL: url)
    #expect(await reloaded.allItems().first?.label == "Blocks the mainnet upgrade")
}

@Test @MainActor func setLabelClearsOnNilOrBlank() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    var seeded = sampleReview()
    seeded.label = "old label"
    try await store.upsertItem(seeded)
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())
    await model.load()

    await model.setLabel("   ", for: sampleReviewID)
    #expect(model.reviews.first?.label == nil)

    await model.setLabel("again", for: sampleReviewID)
    #expect(model.reviews.first?.label == "again")

    await model.setLabel(nil, for: sampleReviewID)
    #expect(model.reviews.first?.label == nil)
}

@Test @MainActor func setPanePersistsSelectionPerItem() async throws {
    let url = tempStoreURL()
    let store = try ReviewStore(fileURL: url)
    try await store.upsertItem(sampleReview())
    let other = WorkItem(
        id: "other-item",
        title: "second",
        repoKey: "github.com/bsv-blockchain/teranode",
        baseBranch: "main",
        origin: .added,
        addedAt: Date(timeIntervalSince1970: 1_700_000_100)
    )
    try await store.upsertItem(other)
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())
    await model.load()

    await model.setPane(.claude, for: sampleReviewID)
    await model.setPane(.github, for: "other-item")

    #expect(model.reviews.first(where: { $0.id == sampleReviewID })?.lastPane == .claude)
    #expect(model.reviews.first(where: { $0.id == "other-item" })?.lastPane == .github)

    let reloaded = try ReviewStore(fileURL: url)
    let persisted = await reloaded.allItems()
    #expect(persisted.first(where: { $0.id == sampleReviewID })?.lastPane == .claude)
    #expect(persisted.first(where: { $0.id == "other-item" })?.lastPane == .github)
}

@Test @MainActor func setPaneIsNoOpForUnknownItem() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    try await store.upsertItem(sampleReview())
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())
    await model.load()

    await model.setPane(.claude, for: "does-not-exist")

    #expect(model.reviews.first?.lastPane == nil)
    #expect(model.errorMessage == nil)
}

@Test @MainActor func pendingWorkflowKeepsStatusWorkingAndDoesNotStampReviewed() async throws {
    // /code-review hands the review to a background workflow and ends its turn in
    // seconds. That is not a finished review: the item must stay working, must not be
    // stamped reviewed, and must not fire the "review ready" notification.
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

    let launchedAt = Date().addingTimeInterval(-600)
    model.handleTranscriptEvent(
        reviewID: review.id,
        at: launchedAt,
        snippet: "Review workflow is running in the background",
        turnCompleted: false,
        workflowPending: true
    )
    model.recomputeStatus(for: review.id, now: Date())

    #expect(model.claudeStatuses[review.id] == .working)

    try await Task.sleep(nanoseconds: 300_000_000)
    #expect(model.reviews.first(where: { $0.id == review.id })?.claudeReviewedAt == nil)
    #expect(await poster.posted.isEmpty)
}

@Test @MainActor func completionAfterWorkflowSettlesStampsReviewedAndNotifies() async throws {
    // When the workflow reports back and Claude finishes the turn for real, the item is
    // reviewed and the notification carries the real verdict.
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

    model.handleTranscriptEvent(
        reviewID: review.id,
        at: Date().addingTimeInterval(-600),
        snippet: "Review workflow is running in the background",
        turnCompleted: false,
        workflowPending: true
    )
    model.handleTranscriptEvent(
        reviewID: review.id,
        at: Date(),
        snippet: "3 confirmed findings",
        turnCompleted: true,
        workflowPending: false
    )

    try await Task.sleep(nanoseconds: 300_000_000)
    #expect(model.reviews.first(where: { $0.id == review.id })?.claudeReviewedAt != nil)
    let posted = await poster.posted
    #expect(posted.count == 1)
    #expect(posted.first?.body == "3 confirmed findings")
}

@Test @MainActor func discoverySurfacesSearchFailureAsWarning() async throws {
    // A failing `gh search prs` (rate limit, auth, network) used to be swallowed: no new
    // PRs appeared and nothing said why. It must surface as a discovery warning.
    let url = tempStoreURL()
    let seedStore = try ReviewStore(fileURL: url)
    var seed = Settings.default
    seed.reviewRequestQueries = [DiscoveryQuery(text: "review-requested:@me is:open")]
    seed.myPRsEnabled = false
    seed.issuesEnabled = false
    try await seedStore.updateSettings(seed)
    let store = try ReviewStore(fileURL: url)
    let runner = StubRunner(results: [
        CommandResult(exitCode: 0, standardOutput: "user\n", standardError: ""),
        CommandResult(
            exitCode: 1,
            standardOutput: "",
            standardError: "HTTP 403: You have exceeded a secondary rate limit."
        ),
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
    #expect(model.discoveryWarnings.count == 1)
    #expect(model.discoveryWarnings.first?.contains("review-requested:@me is:open") == true)
    #expect(model.discoveryWarnings.first?.contains("secondary rate limit") == true)
}

private func authorUpdateSnapshotJSON(committedDate: String) -> String {
    """
    {"data":{"repository":{"pullRequest":{
      "state":"OPEN","isDraft":false,"reviewDecision":"CHANGES_REQUESTED","mergeStateStatus":"CLEAN",
      "author":{"login":"icellan"},
      "commits":{"nodes":[{"commit":{"committedDate":"\(committedDate)","statusCheckRollup":null}}]},
      "reviews":{"nodes":[{"author":{"login":"ordishs"},"state":"CHANGES_REQUESTED","submittedAt":"2026-08-06T09:00:00Z"}]},
      "reviewThreads":{"nodes":[]},
      "timelineItems":{"nodes":[]}
    }}}}
    """
}

@Test @MainActor func clearingTheUpdatedBadgePersistsAWatermarkAndHidesTheChip() async throws {
    let url = tempStoreURL()
    let store = try ReviewStore(fileURL: url)
    try await store.upsertItem(sampleReview())
    let client = GitHubClient(runner: StubRunner(results: [
        CommandResult(exitCode: 0, standardOutput: "ordishs\n", standardError: ""),
        CommandResult(exitCode: 0, standardOutput: authorUpdateSnapshotJSON(committedDate: "2026-08-06T11:00:00Z"), standardError: ""),
    ]), ghPath: "gh")
    let model = AppModel(store: store, client: client, diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())
    await model.load()
    await model.refreshReviewState(for: sampleReviewID)

    let before = try #require(model.reviews.first { $0.id == sampleReviewID })
    #expect(model.hasUnseenAuthorUpdate(before))

    await model.markAuthorUpdateSeen(id: sampleReviewID)

    let after = try #require(model.reviews.first { $0.id == sampleReviewID })
    #expect(model.hasUnseenAuthorUpdate(after) == false)
    // The watermark is the update's own timestamp, not "now".
    #expect(after.authorUpdateSeenAt == ISO8601DateFormatter().date(from: "2026-08-06T11:00:00Z"))

    let reloaded = try ReviewStore(fileURL: url)
    let persisted = await reloaded.allItems().first { $0.id == sampleReviewID }
    #expect(persisted?.authorUpdateSeenAt != nil)
}

@Test @MainActor func aNewerAuthorUpdateReBadgesAfterDismissal() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    try await store.upsertItem(sampleReview())
    let client = GitHubClient(runner: StubRunner(results: [
        CommandResult(exitCode: 0, standardOutput: "ordishs\n", standardError: ""),
        CommandResult(exitCode: 0, standardOutput: authorUpdateSnapshotJSON(committedDate: "2026-08-06T11:00:00Z"), standardError: ""),
        CommandResult(exitCode: 0, standardOutput: authorUpdateSnapshotJSON(committedDate: "2026-08-06T15:30:00Z"), standardError: ""),
    ]), ghPath: "gh")
    let model = AppModel(store: store, client: client, diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())
    await model.load()
    await model.refreshReviewState(for: sampleReviewID)
    await model.markAuthorUpdateSeen(id: sampleReviewID)
    #expect(model.hasUnseenAuthorUpdate(try #require(model.reviews.first)) == false)

    // The author pushes again after the dismissal.
    await model.refreshReviewState(for: sampleReviewID)

    #expect(model.hasUnseenAuthorUpdate(try #require(model.reviews.first)))
}

@Test @MainActor func clearingTheUpdatedBadgeIsANoOpWithoutAnUpdate() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    try await store.upsertItem(sampleReview())
    let model = AppModel(store: store, client: stubClient(), diffLoader: StubDiffLoader(), worktreeProvider: StubWorktreeProvider(), cloneRegistrar: StubRegistrar(), worktreeOps: StubWorktreeOps(), claudePath: "/usr/bin/true", notificationPoster: StubNotificationPoster())
    await model.load()

    await model.markAuthorUpdateSeen(id: sampleReviewID)
    await model.markAuthorUpdateSeen(id: "does-not-exist")

    #expect(model.reviews.first?.authorUpdateSeenAt == nil)
    #expect(model.errorMessage == nil)
}

private func cappedReview(_ suffix: String, number: Int, openedMinutesAgo: Int) -> WorkItem {
    WorkItem(
        id: "item-\(suffix)",
        title: "item \(suffix)",
        repoKey: "github.com/bsv-blockchain/teranode",
        baseBranch: "main",
        headBranch: "branch-\(suffix)",
        prRef: PRRef(
            owner: "bsv-blockchain", repo: "teranode", number: number,
            url: URL(string: "https://github.com/bsv-blockchain/teranode/pull/\(number)")!,
            authorLogin: "icellan"
        ),
        prState: .open,
        origin: .added,
        addedAt: Date(timeIntervalSince1970: 1_700_000_000),
        lastOpenedAt: Date(timeIntervalSince1970: 1_700_000_000 - Double(openedMinutesAgo) * 60)
    )
}

@MainActor
private func cappedModel(store: ReviewStore) -> AppModel {
    AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
}

/// `prewarmClaudeAndWait` skips any item whose registered clone is missing from disk, so a
/// prewarm test must register a repo that really exists.
private func registerExistingClone(in store: ReviewStore) async throws -> URL {
    let clone = FileManager.default.temporaryDirectory
        .appendingPathComponent("clone-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: clone, withIntermediateDirectories: true)
    try await store.upsert(RegisteredRepo(
        remoteIdentity: "github.com/bsv-blockchain/teranode",
        localClonePath: clone.path,
        defaultBase: "main"
    ))
    return clone
}

/// The distinction the Waiting chip depends on: the one-shot stamp must stay put while the
/// latest-completion stamp moves.
@Test @MainActor func queueIsEmptyWhenAutoLoadIsOff() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    try await store.upsertItem(cappedReview("q1", number: 1, openedMinutesAgo: 1))
    let clone = try await registerExistingClone(in: store)
    defer { try? FileManager.default.removeItem(at: clone) }

    let model = cappedModel(store: store)
    await model.load()

    #expect(model.queuedReviewIDs.isEmpty)
}

@Test @MainActor func queueHoldsNeverReviewedItemsMostRecentFirst() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    for index in 1...3 {
        try await store.upsertItem(cappedReview("q\(index)", number: index, openedMinutesAgo: index))
    }
    let clone = try await registerExistingClone(in: store)
    defer { try? FileManager.default.removeItem(at: clone) }
    var settings = await store.settings()
    settings.autoLoad = true
    try await store.updateSettings(settings)

    let model = cappedModel(store: store)
    await model.load()

    #expect(model.queuedReviewIDs == ["item-q1", "item-q2", "item-q3"])
}

@Test @MainActor func queueExcludesReviewedDisabledAndCloneLessItems() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    var reviewed = cappedReview("done", number: 1, openedMinutesAgo: 1)
    reviewed.claudeReviewedAt = Date(timeIntervalSince1970: 500)
    var disabled = cappedReview("off", number: 2, openedMinutesAgo: 2)
    disabled.disabled = true
    let plain = cappedReview("keep", number: 3, openedMinutesAgo: 3)
    var otherRepo = cappedReview("noclone", number: 4, openedMinutesAgo: 4)
    otherRepo.repoKey = "github.com/other/repo"
    for item in [reviewed, disabled, plain, otherRepo] { try await store.upsertItem(item) }
    let clone = try await registerExistingClone(in: store)
    defer { try? FileManager.default.removeItem(at: clone) }
    var settings = await store.settings()
    settings.autoLoad = true
    try await store.updateSettings(settings)

    let model = cappedModel(store: store)
    await model.load()

    #expect(model.queuedReviewIDs == ["item-keep"])
}

@Test @MainActor func drainStartsAQueuedSessionWhenASlotIsFree() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    for index in 1...3 {
        try await store.upsertItem(cappedReview("d\(index)", number: index, openedMinutesAgo: index))
    }
    let clone = try await registerExistingClone(in: store)
    defer { try? FileManager.default.removeItem(at: clone) }
    var settings = await store.settings()
    settings.autoLoad = true
    settings.maxLiveClaudeSessions = 2
    try await store.updateSettings(settings)

    let model = cappedModel(store: store)
    await model.load()

    await model.drainSessionQueue()

    #expect(model.claudeSessions.count == 1)
    #expect(model.claudeSessions["item-d1"] != nil)
}

/// One step per tick, so the backlog moves steadily rather than in a burst.
@Test @MainActor func drainStartsOneSessionPerCall() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    for index in 1...3 {
        try await store.upsertItem(cappedReview("d\(index)", number: index, openedMinutesAgo: index))
    }
    let clone = try await registerExistingClone(in: store)
    defer { try? FileManager.default.removeItem(at: clone) }
    var settings = await store.settings()
    settings.autoLoad = true
    settings.maxLiveClaudeSessions = 3
    try await store.updateSettings(settings)

    let model = cappedModel(store: store)
    await model.load()

    await model.drainSessionQueue()
    await model.drainSessionQueue()

    #expect(model.claudeSessions.count == 2)
}

@Test @MainActor func drainReleasesAnIdleSessionAtTheCapAndStartsTheNext() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    for index in 1...2 {
        try await store.upsertItem(cappedReview("r\(index)", number: index, openedMinutesAgo: index))
    }
    let clone = try await registerExistingClone(in: store)
    defer { try? FileManager.default.removeItem(at: clone) }
    var settings = await store.settings()
    settings.autoLoad = true
    settings.maxLiveClaudeSessions = 1
    try await store.updateSettings(settings)

    let model = cappedModel(store: store)
    await model.load()
    // load() selects the most recently opened item, and the selected session is never
    // released. Clear it so this test exercises the release path rather than the
    // selection exemption, which SessionQueueTests already covers.
    model.selection = nil
    await model.drainSessionQueue()
    let firstStarted = model.claudeSessions["item-r1"] != nil

    // ClaudeSession.start runs `cd <cwd> && exec <claude>`, and StubWorktreeProvider's
    // /tmp/wt does not exist, so the shell exits and the status settles to .ready —
    // releasable. The wait covers `zsh -l` sourcing a slow profile before it can fail.
    try await Task.sleep(nanoseconds: 1_500_000_000)
    model.recomputeStatus(for: "item-r1", now: Date())
    #expect(model.claudeStatuses["item-r1"] != .working)

    await model.drainSessionQueue()

    #expect(firstStarted == true)
    #expect(model.claudeSessions["item-r1"] == nil)
    #expect(model.claudeSessions["item-r2"] != nil)
    #expect(model.claudeSessions.count == 1)
}

@Test @MainActor func aSecondCompletedTurnMovesOnlyTheLatestStamp() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let item = cappedReview("turns", number: 1, openedMinutesAgo: 1)
    try await store.upsertItem(item)

    let model = cappedModel(store: store)
    await model.load()
    await model.ensureClaudeSession(for: item)

    let first = Date(timeIntervalSince1970: 1_000)
    model.handleTranscriptEvent(reviewID: item.id, at: first, snippet: "done", turnCompleted: true)
    try await Task.sleep(nanoseconds: 200_000_000)
    let afterFirst = model.reviews.first { $0.id == item.id }

    let second = Date(timeIntervalSince1970: 2_000)
    model.handleTranscriptEvent(reviewID: item.id, at: second, snippet: "done again", turnCompleted: true)
    try await Task.sleep(nanoseconds: 200_000_000)
    let afterSecond = model.reviews.first { $0.id == item.id }

    #expect(afterFirst?.claudeReviewedAt != nil)
    #expect(afterFirst?.claudeLastCompletedAt != nil)
    #expect(afterSecond?.claudeReviewedAt == afterFirst?.claudeReviewedAt)
    #expect(afterSecond?.claudeLastCompletedAt != afterFirst?.claudeLastCompletedAt)
}

@Test @MainActor func clearingASessionClearsBothClaudeStamps() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    var item = cappedReview("clear", number: 1, openedMinutesAgo: 1)
    item.claudeReviewedAt = Date(timeIntervalSince1970: 1_000)
    item.claudeLastCompletedAt = Date(timeIntervalSince1970: 2_000)
    try await store.upsertItem(item)

    let model = cappedModel(store: store)
    await model.load()

    await model.clearClaudeSession(for: item.id)

    let stored = await store.item(id: item.id)

    #expect(stored?.claudeReviewedAt == nil)
    #expect(stored?.claudeLastCompletedAt == nil)
}

@Test @MainActor func refreshPersistsMyReviewStateAndDate() async throws {
    let snapshotJSON = """
    {"data":{"repository":{"pullRequest":{
      "state":"OPEN","isDraft":false,"reviewDecision":null,"mergeStateStatus":"CLEAN",
      "author":{"login":"icellan"},
      "commits":{"nodes":[]},
      "reviews":{"nodes":[
        {"author":{"login":"ordishs"},"state":"CHANGES_REQUESTED","submittedAt":"2026-08-04T10:00:00Z"}
      ]},
      "reviewThreads":{"nodes":[]},
      "timelineItems":{"nodes":[]}
    }}}}
    """
    let store = try ReviewStore(fileURL: tempStoreURL())
    let item = cappedReview("rev", number: 1, openedMinutesAgo: 1)
    try await store.upsertItem(item)

    let client = GitHubClient(
        runner: StubRunner(result: CommandResult(exitCode: 0, standardOutput: snapshotJSON, standardError: "")),
        ghPath: "gh"
    )
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
    model.setCurrentLoginForTesting("ordishs")

    await model.refreshReviewState(for: item.id)

    let stored = await store.item(id: item.id)

    #expect(model.reviews.first { $0.id == item.id }?.myReviewState == .changesRequested)
    #expect(stored?.myReviewState == .changesRequested)
    #expect(stored?.myLastReviewAt == ISO8601DateFormatter().date(from: "2026-08-04T10:00:00Z"))
}

@Test @MainActor func pruneRemovesOnlyTheOrphanedWorktrees() async throws {
    let managedRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("wtprune-\(UUID().uuidString)", isDirectory: true)
    let root = managedRoot.appendingPathComponent("worktrees.noindex")
    for name in ["live", "orphan-a", "orphan-b"] {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(name),
            withIntermediateDirectories: true
        )
    }
    defer { try? FileManager.default.removeItem(at: managedRoot) }

    let store = try ReviewStore(fileURL: tempStoreURL())
    var item = cappedReview("live", number: 1, openedMinutesAgo: 1)
    item.worktreePath = root.appendingPathComponent("live").path
    try await store.upsertItem(item)
    var settings = await store.settings()
    settings.managedRoot = managedRoot.path
    try await store.updateSettings(settings)

    let model = cappedModel(store: store)
    await model.load()

    #expect(model.orphanedWorktreePaths().count == 2)

    let removed = await model.pruneOrphanedWorktrees()

    #expect(removed == 2)
    #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("live").path))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("orphan-a").path))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("orphan-b").path))
}

@Test @MainActor func migrationMovesTheWorktreeRootAndRewritesPaths() async throws {
    let managedRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("wtmigrate-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: managedRoot.appendingPathComponent("worktrees/owner-repo-pr1"),
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: managedRoot) }

    let store = try ReviewStore(fileURL: tempStoreURL())
    var item = cappedReview("mig", number: 1, openedMinutesAgo: 1)
    item.worktreePath = managedRoot.appendingPathComponent("worktrees/owner-repo-pr1").path
    try await store.upsertItem(item)
    var settings = await store.settings()
    settings.managedRoot = managedRoot.path
    try await store.updateSettings(settings)

    let model = cappedModel(store: store)
    await model.load()

    await model.migrateWorktreeRoot()

    let expected = managedRoot.appendingPathComponent("worktrees.noindex/owner-repo-pr1").path
    let stored = await store.item(id: item.id)?.worktreePath

    #expect(FileManager.default.fileExists(atPath: expected))
    #expect(!FileManager.default.fileExists(atPath: managedRoot.appendingPathComponent("worktrees").path))
    #expect(model.reviews.first { $0.id == item.id }?.worktreePath == expected)
    #expect(stored == expected)
}

@Test @MainActor func migrationRepairsEachMovedWorktree() async throws {
    let managedRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("wtmigrate3-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: managedRoot.appendingPathComponent("worktrees/owner-repo-pr1"),
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: managedRoot) }

    let store = try ReviewStore(fileURL: tempStoreURL())
    var item = cappedReview("mig", number: 1, openedMinutesAgo: 1)
    item.worktreePath = managedRoot.appendingPathComponent("worktrees/owner-repo-pr1").path
    try await store.upsertItem(item)
    var settings = await store.settings()
    settings.managedRoot = managedRoot.path
    try await store.updateSettings(settings)

    let ops = StubWorktreeOps()
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: StubWorktreeProvider(),
        cloneRegistrar: StubRegistrar(),
        worktreeOps: ops,
        claudePath: "/usr/bin/true",
        notificationPoster: StubNotificationPoster()
    )
    await model.load()

    await model.migrateWorktreeRoot()

    let expected = managedRoot.appendingPathComponent("worktrees.noindex/owner-repo-pr1").path
    let repaired = await ops.repairedWorktreePaths

    #expect(repaired == [expected])
}

/// A half-finished migration must be recoverable. If the directory move landed but the
/// path rewrite did not, the next run has no legacy directory to key off, so a guard on
/// that alone would strand every stale path forever.
@Test @MainActor func migrationRewritesStalePathsAfterTheDirectoryAlreadyMoved() async throws {
    let managedRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("wtresume-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: managedRoot.appendingPathComponent("worktrees.noindex/owner-repo-pr1"),
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: managedRoot) }

    let store = try ReviewStore(fileURL: tempStoreURL())
    var item = cappedReview("stale", number: 1, openedMinutesAgo: 1)
    item.worktreePath = managedRoot.appendingPathComponent("worktrees/owner-repo-pr1").path
    try await store.upsertItem(item)
    var settings = await store.settings()
    settings.managedRoot = managedRoot.path
    try await store.updateSettings(settings)

    let model = cappedModel(store: store)
    await model.load()

    await model.migrateWorktreeRoot()

    let expected = managedRoot.appendingPathComponent("worktrees.noindex/owner-repo-pr1").path
    let stored = await store.item(id: item.id)?.worktreePath

    #expect(stored == expected)
    #expect(model.reviews.first { $0.id == item.id }?.worktreePath == expected)
}

/// `load()` must never touch the filesystem outside the store. A test that does not
/// override `managedRoot` inherits `Settings.default`, which points at the user's real
/// Application Support directory — running the suite once moved 11 GB of live checkouts.
@Test @MainActor func loadDoesNotMigrateTheWorktreeRoot() async throws {
    let managedRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("wtnoload-\(UUID().uuidString)", isDirectory: true)
    let legacy = managedRoot.appendingPathComponent("worktrees/owner-repo-pr1")
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: managedRoot) }

    let store = try ReviewStore(fileURL: tempStoreURL())
    var item = cappedReview("noload", number: 1, openedMinutesAgo: 1)
    item.worktreePath = legacy.path
    try await store.upsertItem(item)
    var settings = await store.settings()
    settings.managedRoot = managedRoot.path
    try await store.updateSettings(settings)

    let model = cappedModel(store: store)
    await model.load()

    #expect(FileManager.default.fileExists(atPath: legacy.path))
    #expect(!FileManager.default.fileExists(atPath: managedRoot.appendingPathComponent("worktrees.noindex").path))
}

@Test @MainActor func migrationIsANoOpOnASecondRun() async throws {
    let managedRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("wtmigrate2-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: managedRoot.appendingPathComponent("worktrees/owner-repo-pr1"),
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: managedRoot) }

    let store = try ReviewStore(fileURL: tempStoreURL())
    var item = cappedReview("mig", number: 1, openedMinutesAgo: 1)
    item.worktreePath = managedRoot.appendingPathComponent("worktrees/owner-repo-pr1").path
    try await store.upsertItem(item)
    var settings = await store.settings()
    settings.managedRoot = managedRoot.path
    try await store.updateSettings(settings)

    let model = cappedModel(store: store)
    await model.load()

    await model.migrateWorktreeRoot()
    let afterFirst = model.reviews.first { $0.id == item.id }?.worktreePath
    await model.migrateWorktreeRoot()

    #expect(model.reviews.first { $0.id == item.id }?.worktreePath == afterFirst)
}

@Test @MainActor func refreshCyclesThroughItemsInsteadOfRefreshingAll() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    for index in 1...10 {
        try await store.upsertItem(cappedReview("rf\(index)", number: index, openedMinutesAgo: index))
    }

    let model = cappedModel(store: store)
    await model.load()
    model.selection = "item-rf1"

    await model.refreshReviewStates()

    #expect(model.refreshedIDsForTesting().count == 5)
    #expect(model.refreshedIDsForTesting().contains("item-rf1"))
}

@Test @MainActor func refreshAllNowRefreshesEveryOpenItem() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    for index in 1...10 {
        try await store.upsertItem(cappedReview("ra\(index)", number: index, openedMinutesAgo: index))
    }

    let model = cappedModel(store: store)
    await model.load()

    await model.refreshAllNow()

    #expect(model.refreshedIDsForTesting().count == 10)
}

@Test @MainActor func prewarmStopsAtTheSessionCap() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    for index in 1...5 {
        try await store.upsertItem(cappedReview("pw\(index)", number: index, openedMinutesAgo: index))
    }
    let clone = try await registerExistingClone(in: store)
    defer { try? FileManager.default.removeItem(at: clone) }
    var settings = await store.settings()
    settings.autoLoad = true
    settings.maxLiveClaudeSessions = 2
    try await store.updateSettings(settings)

    let model = cappedModel(store: store)
    await model.load()

    await model.prewarmClaudeAndWait()

    #expect(model.claudeSessions.count == 2)
}

@Test @MainActor func prewarmStartsTheMostRecentlyOpenedItemsFirst() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    for index in 1...4 {
        try await store.upsertItem(cappedReview("pw\(index)", number: index, openedMinutesAgo: index))
    }
    let clone = try await registerExistingClone(in: store)
    defer { try? FileManager.default.removeItem(at: clone) }
    var settings = await store.settings()
    settings.autoLoad = true
    settings.maxLiveClaudeSessions = 2
    try await store.updateSettings(settings)

    let model = cappedModel(store: store)
    await model.load()

    await model.prewarmClaudeAndWait()

    #expect(model.claudeSessions["item-pw1"] != nil)
    #expect(model.claudeSessions["item-pw2"] != nil)
    #expect(model.claudeSessions["item-pw3"] == nil)
    #expect(model.claudeSessions["item-pw4"] == nil)
}

@Test @MainActor func sessionBudgetEvictsTheOldestSessionBeyondTheCap() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let newest = cappedReview("newest", number: 1, openedMinutesAgo: 1)
    let middle = cappedReview("middle", number: 2, openedMinutesAgo: 2)
    let oldest = cappedReview("oldest", number: 3, openedMinutesAgo: 3)
    for item in [newest, middle, oldest] { try await store.upsertItem(item) }
    var settings = await store.settings()
    settings.maxLiveClaudeSessions = 2
    try await store.updateSettings(settings)

    let model = cappedModel(store: store)
    await model.load()
    model.selection = newest.id
    for item in [oldest, middle, newest] {
        await model.ensureClaudeSession(for: item)
    }

    model.enforceSessionBudget(now: Date().addingTimeInterval(120))

    #expect(model.claudeSessions.count == 2)
    #expect(model.claudeSessions[oldest.id] == nil)
    #expect(model.claudeSessions[middle.id] != nil)
    #expect(model.claudeSessions[newest.id] != nil)
}

@Test @MainActor func sessionEvictionKeepsThePersistedSessionIDForResume() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let newest = cappedReview("newest", number: 1, openedMinutesAgo: 1)
    let oldest = cappedReview("oldest", number: 2, openedMinutesAgo: 2)
    for item in [newest, oldest] { try await store.upsertItem(item) }
    var settings = await store.settings()
    settings.maxLiveClaudeSessions = 1
    try await store.updateSettings(settings)

    let model = cappedModel(store: store)
    await model.load()
    model.selection = newest.id
    for item in [oldest, newest] {
        await model.ensureClaudeSession(for: item)
    }
    let persistedBefore = model.reviews.first { $0.id == oldest.id }?.claudeSessionID

    model.enforceSessionBudget(now: Date().addingTimeInterval(120))

    let stored = await store.item(id: oldest.id)?.claudeSessionID

    #expect(persistedBefore != nil)
    #expect(model.claudeSessions[oldest.id] == nil)
    #expect(model.reviews.first { $0.id == oldest.id }?.claudeSessionID == persistedBefore)
    #expect(stored == persistedBefore)
}

@Test @MainActor func sessionEvictionKeepsTheGitHubStatusChips() async throws {
    let store = try ReviewStore(fileURL: tempStoreURL())
    let newest = cappedReview("newest", number: 1, openedMinutesAgo: 1)
    let oldest = cappedReview("oldest", number: 2, openedMinutesAgo: 2)
    for item in [newest, oldest] { try await store.upsertItem(item) }
    var settings = await store.settings()
    settings.maxLiveClaudeSessions = 1
    try await store.updateSettings(settings)

    let model = cappedModel(store: store)
    await model.load()
    model.selection = newest.id
    for item in [oldest, newest] {
        await model.ensureClaudeSession(for: item)
    }
    model.setPRStatusForTesting(
        PRStatus(ci: .passing, isBehind: false, readiness: .reviewRequired),
        for: oldest.id
    )

    model.enforceSessionBudget(now: Date().addingTimeInterval(120))

    #expect(model.claudeSessions[oldest.id] == nil)
    #expect(model.prStatuses[oldest.id] != nil)
}

/// The session must genuinely still be running for its status to read `.working`.
/// `ClaudeSession.start()` runs `cd <cwd> && exec <claude> …`, so the default stub's
/// non-existent `/tmp/wt` makes the shell exit at once and the status decays to `.ready`.
/// `yes` ignores its arguments and never exits, which pins the status deterministically.
@Test @MainActor func sessionBudgetProtectsAWorkingSession() async throws {
    let cwd = FileManager.default.temporaryDirectory
        .appendingPathComponent("livewt-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: cwd) }

    let store = try ReviewStore(fileURL: tempStoreURL())
    let newest = cappedReview("newest", number: 1, openedMinutesAgo: 1)
    let oldest = cappedReview("oldest", number: 2, openedMinutesAgo: 2)
    for item in [newest, oldest] { try await store.upsertItem(item) }
    var settings = await store.settings()
    settings.maxLiveClaudeSessions = 1
    try await store.updateSettings(settings)

    var provider = StubWorktreeProvider()
    provider.result = WorktreeReady(clonePath: cwd.path, worktreePath: cwd.path, remoteName: "origin")
    let model = AppModel(
        store: store,
        client: stubClient(),
        diffLoader: StubDiffLoader(),
        worktreeProvider: provider,
        cloneRegistrar: StubRegistrar(),
        worktreeOps: StubWorktreeOps(),
        claudePath: "/usr/bin/yes",
        notificationPoster: StubNotificationPoster()
    )
    defer { model.terminateAllClaudeSessions() }
    await model.load()
    model.selection = newest.id
    for item in [oldest, newest] {
        await model.ensureClaudeSession(for: item)
    }
    let now = Date()
    model.handleTranscriptEvent(reviewID: oldest.id, at: now, snippet: "working", turnCompleted: false)
    model.recomputeStatus(for: oldest.id, now: now)

    #expect(model.claudeStatuses[oldest.id] == .working)

    model.enforceSessionBudget(now: now.addingTimeInterval(120))

    #expect(model.claudeSessions[oldest.id] != nil)
}
