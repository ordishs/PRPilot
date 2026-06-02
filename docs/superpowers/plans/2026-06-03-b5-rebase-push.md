# B5 — Rebase + Push (the finale) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Let the user keep their own branches current from inside the app. Context actions on **editable** My Work items (tasks, graduated tasks, and My PRs): **Rebase on `<base>`** (local only, with a conflict resolution flow) and a separate **Push** (`--force-with-lease` when diverged). Make My-PR worktrees branch-based (convert existing detached ones safely) so this works on the user's real PRs. And land the **refresh guard** so `refreshWorktree` never `git reset --hard`s a worktree that holds unpushed local commits.

**Architecture:**
- `WorktreeManager` gains the git plumbing: `currentBranch`, `isClean`, `checkoutBranchWorktree` (My-PR: check out an existing remote branch), `rebaseOnto`/`rebaseAbort`/`rebaseContinue` (returning a `RebaseOutcome`), `push`, `aheadBehind`; plus a guard in `refreshWorktree`.
- `WorktreeProvider.ensureWorktree(for:editable:…)` dispatches three worktree modes: review-request → detached PR head (today); task → new branch off base (B3); **My PR (editable) → branch checkout of the PR head ref**, converting an existing *clean* detached worktree in place. AppModel passes `editable = item.category(myLogin:) != .reviewRequest`.
- `AppModel` orchestrates rebase/push: `rebaseStates: [String: RebaseState]` (runtime), `rebase(id:)`, `continueRebase(id:)`, `abortRebase(id:)`, `push(id:)`, and `pushability: [String: Pushability]` (ahead/diverged) for button state.
- UI: context-menu **Rebase on `<base>`** / **Push** on editable items; a conflict banner in `DetailView` with **Resolve in Claude** (flip to the Claude pane) / **Continue** / **Abort**.

**Safety stance:** Rebase is local and never pushes. Push is always `--force-with-lease`, never bare `--force`. The detached→branch conversion only happens when the worktree is clean; a dirty worktree is left untouched and Rebase/Push are disabled with a tooltip. `refreshWorktree` skips any worktree on a branch.

**Tech Stack:** Swift / SwiftUI; Apple Swift Testing; XcodeGen app target.
**Build/test:** `swift test --package-path Core`; `xcodegen generate && xcodebuild -project PRPilot.xcodeproj -scheme PRPilot -configuration Debug build`.
**Conventions:** No comments unless surrounding code has them; `--no-verify`; no AI attribution.

---

## File Structure

**Modify:**
- `Core/Sources/WorktreeKit/WorktreeManager.swift` — plumbing + refresh guard.
- `Core/Sources/WorktreeKit/WorktreeError.swift` — add a case if needed (e.g. `notOnABranch`).
- `Core/Sources/AppCore/WorktreeProviding.swift` — `editable` param + My-PR branch mode + conversion.
- `Core/Sources/AppCore/AppModel.swift` — rebase/push orchestration, `rebaseStates`, `pushability`, editability wiring.
- `App/ContentView.swift` — context-menu Rebase/Push on editable items.
- `App/DetailView.swift` — conflict banner.
- Tests: `WorktreeKitTests/WorktreeManagerTests.swift`, `AppCoreTests/AppModelTests.swift`.

**New:**
- `Core/Sources/WorktreeKit/RebaseOutcome.swift` — `RebaseOutcome` enum.

---

## Task 1: WorktreeManager git plumbing

**Files:** `Core/Sources/WorktreeKit/RebaseOutcome.swift` (new), `Core/Sources/WorktreeKit/WorktreeManager.swift`, `Core/Tests/WorktreeKitTests/WorktreeManagerTests.swift`.

- [ ] **Step 1: `RebaseOutcome.swift`**
```swift
public enum RebaseOutcome: Sendable, Equatable {
    case clean
    case conflicts([String])   // conflicted file paths (relative to the worktree)
}
```

- [ ] **Step 2: Failing integration tests** (mirror the file's temp-repo `git(...)` harness from the B3 `createBranchWorktree` test). Add, building real repos:

```swift
@Test func currentBranchReportsBranchAndNilWhenDetached() async throws {
    // repo with main + a commit. worktree A added with -b feat/x off main → currentBranch == "feat/x".
    // worktree B added --detach at HEAD → currentBranch == nil.
}

@Test func rebaseOntoCleanReplaysCommits() async throws {
    // main has commits; branch feat/x off an OLDER main, then main advances with a NON-conflicting file.
    // fetch not needed (local). rebaseOnto(worktree, "main") → .clean; HEAD now contains main's new commit.
}

@Test func rebaseOntoReportsConflicts() async throws {
    // branch feat/x edits file F; main edits the SAME line of F differently. rebaseOnto(worktree,"main")
    // → .conflicts(["F"]); the worktree is left mid-rebase (git status shows rebase in progress).
    // Then rebaseAbort(worktree) returns the worktree to feat/x cleanly (currentBranch == "feat/x", isClean).
}

@Test func pushToLocalBareRemoteSucceeds() async throws {
    // create a bare repo as "origin"; clone it; worktree on a branch with a new commit;
    // push(worktree, remote:"origin", branch:"feat/x", force:false) → the bare repo now has feat/x at HEAD.
}

@Test func aheadBehindCountsDivergence() async throws {
    // branch ahead of origin/branch by N, behind by M → aheadBehind returns (ahead:N, behind:M).
}
```
(Use the existing temp-dir + `git(...)` helper; for the push test create a bare repo with `git init --bare`. Match the harness exactly.)

- [ ] **Step 3: Run → FAIL.**

- [ ] **Step 4: Implement** — add to `WorktreeManager`:

```swift
    public func currentBranch(worktreePath: String) async throws -> String? {
        let result = try await runner.run(
            executable: gitPath,
            arguments: ["-C", worktreePath, "symbolic-ref", "--quiet", "--short", "HEAD"]
        )
        guard result.exitCode == 0 else { return nil }   // detached HEAD
        let name = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    public func isClean(worktreePath: String) async throws -> Bool {
        let out = try await runGit(["-C", worktreePath, "status", "--porcelain"])
        return out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func checkoutBranchWorktree(
        clonePath: String,
        owner: String,
        repo: String,
        branch: String,
        remoteName: String = "origin",
        progress: @escaping @Sendable (String) async -> Void = { _ in }
    ) async throws -> String {
        let worktreesDir = managedRoot + "/worktrees"
        let worktreePath = worktreesDir + "/" + owner + "-" + repo + "-" + WorktreeManager.branchSlug(branch)
        if FileManager.default.fileExists(atPath: worktreePath) {
            let listing = try await runGit(["-C", clonePath, "worktree", "list", "--porcelain"])
            if listing.contains("worktree \(worktreePath)") {
                await progress("Found existing worktree")
                return worktreePath
            }
            throw WorktreeError.gitFailed(arguments: ["worktree", "validate", worktreePath], exitCode: 1,
                message: "directory exists but is not a registered git worktree: \(worktreePath)")
        }
        try await runGit(["-C", clonePath, "worktree", "prune"])
        await progress("Fetching \(branch)…")
        try await runGit(["-C", clonePath, "fetch", remoteName, branch])
        try FileManager.default.createDirectory(atPath: worktreesDir, withIntermediateDirectories: true)
        await progress("Checking out \(branch)…")
        // Create a local branch tracking the remote head; if it already exists, just add it.
        let exists = (try? await runGit(["-C", clonePath, "rev-parse", "--verify", "--quiet", branch])) != nil
        if exists {
            try await runGit(["-C", clonePath, "worktree", "add", worktreePath, branch])
        } else {
            try await runGit(["-C", clonePath, "worktree", "add", "--track", "-b", branch, worktreePath, "\(remoteName)/\(branch)"])
        }
        return worktreePath
    }

    public func removeWorktreeForcing(clonePath: String, worktreePath: String) async throws {
        try await runGit(["-C", clonePath, "worktree", "remove", "--force", worktreePath])
    }

    public func rebaseOnto(worktreePath: String, upstream: String) async throws -> RebaseOutcome {
        let result = try await runner.run(
            executable: gitPath,
            arguments: ["-C", worktreePath, "-c", "core.editor=true", "rebase", upstream]
        )
        if result.exitCode == 0 { return .clean }
        let conflicted = try await conflictedFiles(worktreePath)
        if !conflicted.isEmpty { return .conflicts(conflicted) }
        throw WorktreeError.gitFailed(arguments: ["rebase", upstream], exitCode: result.exitCode, message: result.standardError)
    }

    public func rebaseContinue(worktreePath: String) async throws -> RebaseOutcome {
        let result = try await runner.run(
            executable: gitPath,
            arguments: ["-C", worktreePath, "-c", "core.editor=true", "rebase", "--continue"]
        )
        if result.exitCode == 0 { return .clean }
        let conflicted = try await conflictedFiles(worktreePath)
        if !conflicted.isEmpty { return .conflicts(conflicted) }
        throw WorktreeError.gitFailed(arguments: ["rebase", "--continue"], exitCode: result.exitCode, message: result.standardError)
    }

    public func rebaseAbort(worktreePath: String) async throws {
        try await runGit(["-C", worktreePath, "rebase", "--abort"])
    }

    private func conflictedFiles(worktreePath: String) async throws -> [String] {
        let out = try await runGit(["-C", worktreePath, "diff", "--name-only", "--diff-filter=U"])
        return out.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    public func push(worktreePath: String, remoteName: String, branch: String, force: Bool) async throws {
        var args = ["-C", worktreePath, "push"]
        if force { args.append("--force-with-lease") }
        args += [remoteName, branch]
        try await runGit(args)
    }

    public func aheadBehind(worktreePath: String, upstream: String) async throws -> (ahead: Int, behind: Int) {
        let ahead = try await runGit(["-C", worktreePath, "rev-list", "--count", "\(upstream)..HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)
        let behind = try await runGit(["-C", worktreePath, "rev-list", "--count", "HEAD..\(upstream)"]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (Int(ahead) ?? 0, Int(behind) ?? 0)
    }
```

- [ ] **Step 5: Run → PASS** (all new tests). Adjust TEST git setup (not impl) if the harness needs tweaks.
- [ ] **Step 6: Commit**
```bash
git add Core/Sources/WorktreeKit/RebaseOutcome.swift Core/Sources/WorktreeKit/WorktreeManager.swift Core/Tests/WorktreeKitTests/WorktreeManagerTests.swift
git commit -m "feat(worktree): rebase/push/branch-checkout plumbing" --no-verify
```

---

## Task 2: refreshWorktree guard

**Files:** `Core/Sources/WorktreeKit/WorktreeManager.swift`, `Core/Tests/WorktreeKitTests/WorktreeManagerTests.swift`.

- [ ] **Step 1: Failing test** — `refreshWorktreeSkipsBranchWorktrees`: a worktree on a branch (not detached) with a local commit; call `refreshWorktree(...)`; assert it returns `false` (no-op) and the local commit is STILL present (HEAD unchanged) — i.e. no `git reset --hard`.

- [ ] **Step 2: Implement the guard** — at the TOP of `refreshWorktree(...)`, before any fetch/reset:
```swift
        // Editable (branch-based) worktrees may hold unpushed local commits — never hard-reset them.
        if (try? await currentBranch(worktreePath: worktreePath)) ?? nil != nil {
            return false
        }
```
(Detached review-request worktrees — `currentBranch == nil` — keep the existing fetch + fast-forward behaviour.)

- [ ] **Step 3: Run → PASS** (plus the existing refresh tests still pass — confirm the detached path is unchanged).
- [ ] **Step 4: Commit**
```bash
git add Core/Sources/WorktreeKit/WorktreeManager.swift Core/Tests/WorktreeKitTests/WorktreeManagerTests.swift
git commit -m "fix(worktree): never hard-reset a branch worktree (protects unpushed commits)" --no-verify
```

---

## Task 3: WorktreeProvider — editable dispatch + My-PR branch mode + conversion

**Files:** `Core/Sources/AppCore/WorktreeProviding.swift`.

- [ ] **Step 1: Add `editable` to the protocol** (with a defaulted convenience), and dispatch.

```swift
public protocol WorktreeProviding: Sendable {
    func ensureWorktree(
        for review: WorkItem,
        editable: Bool,
        registeredClonePath: String?,
        progress: @escaping PrepProgress
    ) async throws -> WorktreeReady
}

public extension WorktreeProviding {
    func ensureWorktree(for review: WorkItem, editable: Bool, registeredClonePath: String?) async throws -> WorktreeReady {
        try await ensureWorktree(for: review, editable: editable, registeredClonePath: registeredClonePath, progress: { _ in })
    }
}
```

`WorktreeProvider.ensureWorktree` (clone-resolve + remote-detect prologue unchanged), then:

```swift
        // Existing worktree?
        if let existing = review.worktreePath, FileManager.default.fileExists(atPath: existing) {
            if !editable {
                if let number = review.number {
                    await progress("Refreshing existing worktree…")
                    _ = try await worktreeManager.refreshWorktree(clonePath: clonePath, worktreePath: existing, number: number, remoteName: remoteName)
                }
                return WorktreeReady(clonePath: clonePath, worktreePath: existing, remoteName: remoteName)
            }
            // Editable: ensure it is on a branch. Convert a clean detached worktree in place.
            let branch = review.headBranch
            let onBranch = (try? await worktreeManager.currentBranch(worktreePath: existing)) ?? nil
            if let branch, onBranch == branch {
                return WorktreeReady(clonePath: clonePath, worktreePath: existing, remoteName: remoteName)
            }
            if let branch, (try? await worktreeManager.isClean(worktreePath: existing)) == true {
                await progress("Converting worktree to branch \(branch)…")
                try? await worktreeManager.removeWorktreeForcing(clonePath: clonePath, worktreePath: existing)
                let path = try await editableWorktree(review: review, branch: branch, clonePath: clonePath, remoteName: remoteName, progress: progress)
                return WorktreeReady(clonePath: clonePath, worktreePath: path, remoteName: remoteName)
            }
            // Editable but dirty or no headBranch — leave as-is (Rebase/Push gating handles it).
            return WorktreeReady(clonePath: clonePath, worktreePath: existing, remoteName: remoteName)
        }

        // No existing worktree.
        let worktreePath: String
        if editable, let branch = review.headBranch {
            worktreePath = try await editableWorktree(review: review, branch: branch, clonePath: clonePath, remoteName: remoteName, progress: progress)
        } else if let number = review.number {
            worktreePath = try await worktreeManager.createWorktree(clonePath: clonePath, owner: review.owner, repo: review.repo, number: number, remoteName: remoteName, progress: progress)
        } else {
            throw WorktreeError.notAPullRequest
        }
        return WorktreeReady(clonePath: clonePath, worktreePath: worktreePath, remoteName: remoteName)
```

Add a private helper that picks new-branch (task: no PR) vs checkout-existing (My PR):
```swift
    private func editableWorktree(review: WorkItem, branch: String, clonePath: String, remoteName: String, progress: @escaping PrepProgress) async throws -> String {
        if review.number == nil {
            // Task: brand-new branch off the item's base.
            return try await worktreeManager.createBranchWorktree(clonePath: clonePath, owner: review.owner, repo: review.repo, branch: branch, base: review.baseBranch, remoteName: remoteName, progress: progress)
        } else {
            // My PR: check out the existing PR head branch.
            return try await worktreeManager.checkoutBranchWorktree(clonePath: clonePath, owner: review.owner, repo: review.repo, branch: branch, remoteName: remoteName, progress: progress)
        }
    }
```

- [ ] **Step 2: Update the call site in `AppModel.ensureClaudeSession`** to pass `editable`. Find the `worktreeProvider.ensureWorktree(for: review, registeredClonePath: …)` call and change to:
```swift
        let editable = review.category(myLogin: currentLogin) != .reviewRequest
        ready = try await worktreeProvider.ensureWorktree(for: review, editable: editable, registeredClonePath: registeredClonePath(for: review), progress: progress)
```
(And update the `StubWorktreeProvider` in AppModelTests to the new signature — add the `editable:` param.)

- [ ] **Step 3: Build the package**: `swift build --package-path Core` → all sources compile. Then `swift test --package-path Core` (the StubWorktreeProvider signature change must be reflected; fix it).
- [ ] **Step 4: Commit**
```bash
git add Core/Sources/AppCore/WorktreeProviding.swift Core/Sources/AppCore/AppModel.swift Core/Tests/AppCoreTests/AppModelTests.swift
git commit -m "feat(worktree): editable items get branch worktrees; convert clean detached in place" --no-verify
```

---

## Task 4: AppModel — rebase/push orchestration

**Files:** `Core/Sources/AppCore/AppModel.swift`, `Core/Tests/AppCoreTests/AppModelTests.swift`.

This task needs direct `WorktreeManager` access from `AppModel`. Check how `AppModel` reaches git: it holds a `worktreeProvider` (protocol) and a `commandRunner`. For rebase/push it needs the concrete `WorktreeManager` (clone path + worktree path + remote). Add a `WorktreeManager` to `AppModel` (constructed from `commandRunner` + git path + managed root, mirroring how the app wires `WorktreeProvider`) OR expose the needed ops through `WorktreeProviding`. **Read how the app constructs `WorktreeProvider`/`WorktreeManager` in the App target's composition root first**, then pick the lowest-churn path (likely: inject a `WorktreeManager` into `AppModel` alongside `worktreeProvider`, since the App already builds one). Wire it through `AppModel.init` with a default for tests.

- [ ] **Step 1: Add runtime state + a Pushability/RebaseState model** (in AppCore, near other state):
```swift
    public enum RebaseState: Sendable, Equatable {
        case conflicted([String])
        case failed(String)
    }
    public struct Pushability: Sendable, Equatable {
        public var canPush: Bool
        public var needsForce: Bool
    }
    public private(set) var rebaseStates: [String: RebaseState] = [:]
    public private(set) var pushability: [String: Pushability] = [:]
```

- [ ] **Step 2: Helpers + actions.** Resolve the worktree (must be ready + on a branch) before acting. Use `registeredClonePath(for:)` + the stored `worktreePath` + the item's `headBranch` + remote (`origin` default). Add:

```swift
    public func rebase(id: String) async {
        guard let item = reviews.first(where: { $0.id == id }),
              let worktreePath = item.worktreePath,
              let branch = item.headBranch else { return }
        let upstream = "origin/\(item.baseBranch)"
        do {
            try await worktreeManager.fetch(clonePath: registeredClonePath(for: item) ?? worktreePath, remoteName: "origin", ref: item.baseBranch)
            let outcome = try await worktreeManager.rebaseOnto(worktreePath: worktreePath, upstream: upstream)
            switch outcome {
            case .clean:
                rebaseStates[id] = nil
            case .conflicts(let files):
                rebaseStates[id] = .conflicted(files)
            }
        } catch {
            rebaseStates[id] = .failed(String(describing: error))
        }
        await refreshPushability(for: id)
        _ = branch
    }

    public func continueRebase(id: String) async {
        guard let item = reviews.first(where: { $0.id == id }), let worktreePath = item.worktreePath else { return }
        do {
            let outcome = try await worktreeManager.rebaseContinue(worktreePath: worktreePath)
            rebaseStates[id] = outcome == .clean ? nil : { if case .conflicts(let f) = outcome { return .conflicted(f) }; return nil }()
        } catch {
            rebaseStates[id] = .failed(String(describing: error))
        }
        await refreshPushability(for: id)
    }

    public func abortRebase(id: String) async {
        guard let item = reviews.first(where: { $0.id == id }), let worktreePath = item.worktreePath else { return }
        try? await worktreeManager.rebaseAbort(worktreePath: worktreePath)
        rebaseStates[id] = nil
        await refreshPushability(for: id)
    }

    public func push(id: String) async {
        guard let item = reviews.first(where: { $0.id == id }),
              let worktreePath = item.worktreePath,
              let branch = item.headBranch else { return }
        let force = pushability[id]?.needsForce ?? false
        do {
            try await worktreeManager.push(worktreePath: worktreePath, remoteName: "origin", branch: branch, force: force)
        } catch {
            errorMessage = String(describing: error)
        }
        await refreshPushability(for: id)
    }

    public func refreshPushability(for id: String) async {
        guard let item = reviews.first(where: { $0.id == id }),
              let worktreePath = item.worktreePath,
              let branch = item.headBranch,
              (try? await worktreeManager.currentBranch(worktreePath: worktreePath)) ?? nil == branch else {
            pushability[id] = nil
            return
        }
        if let counts = try? await worktreeManager.aheadBehind(worktreePath: worktreePath, upstream: "origin/\(branch)") {
            // Remote branch exists: ahead → can push; behind → diverged (rebased) → needs force-with-lease.
            pushability[id] = Pushability(canPush: counts.ahead > 0, needsForce: counts.behind > 0)
        } else if let base = try? await worktreeManager.aheadBehind(worktreePath: worktreePath, upstream: "origin/\(item.baseBranch)") {
            // Never pushed (no origin/<branch>): can push if there are commits beyond base; no force needed.
            pushability[id] = Pushability(canPush: base.ahead > 0, needsForce: false)
        } else {
            pushability[id] = nil
        }
    }
```
(Clear `rebaseStates`/`pushability` for an id in the same removal cleanup that clears `prStatuses`.)

- [ ] **Step 3: Tests** (`AppModelTests.swift`). The rebase/push ops hit `WorktreeManager` against real git, which is heavy for unit tests. Prefer testing the orchestration via a **fake/injected WorktreeManager seam** if one is feasible, OR test the pure decision (`Pushability` from ahead/behind) and leave the git execution to Task 1's integration tests + the manual check. Concretely: if `AppModel` takes a `WorktreeManager`, and `WorktreeManager` is a concrete struct (not a protocol), consider adding a tiny protocol seam OR a temp-repo integration test in `AppModelTests` that creates a real branch worktree and asserts `rebase`/`push`/`refreshPushability` update `rebaseStates`/`pushability` correctly. Pick the approach that fits the existing test architecture (read how AppModelTests injects collaborators). At minimum, add:
  - `pushabilityReflectsAheadBehind` (ahead>0 → canPush; behind>0 → needsForce) — drive via a real temp branch worktree if no seam exists.
  - `rebaseCleanClearsState` and `rebaseConflictSetsConflictedState` — temp repo with/without a conflicting change.
  If a real-git integration test in AppModelTests is impractical, report DONE_WITH_CONCERNS proposing a `WorktreeManaging` protocol seam (small refactor) rather than shipping untested orchestration.

- [ ] **Step 4:** `swift test --package-path Core` → all pass (report count).
- [ ] **Step 5: Commit**
```bash
git add Core/Sources/AppCore/AppModel.swift Core/Tests/AppCoreTests/AppModelTests.swift
git commit -m "feat(appcore): rebase/continue/abort/push orchestration with conflict + pushability state" --no-verify
```

---

## Task 5: UI — Rebase/Push menu + conflict banner

**Files:** `App/ContentView.swift`, `App/DetailView.swift`.

- [ ] **Step 1: Context menu** — in `sidebarRow`'s `.contextMenu`, add (only for editable items) Rebase + Push, above the existing Divider/Disable/Remove. Compute editability inline:
```swift
            if review.category(myLogin: model.currentLogin) != .reviewRequest, review.headBranch != nil {
                Button {
                    Task { await model.rebase(id: review.id) }
                } label: { Label("Rebase on \(review.baseBranch)", systemImage: "arrow.triangle.merge") }
                Button {
                    Task { await model.push(id: review.id) }
                } label: { Label("Push", systemImage: "arrow.up.circle") }
                .disabled(!(model.pushability[review.id]?.canPush ?? false))
                Divider()
            }
```

- [ ] **Step 2: Conflict banner in `DetailView`** — at the top of the `VStack`, before the `Picker`:
```swift
            if case .conflicted(let files) = model.rebaseStates[review.id] {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Rebase paused — \(files.count) conflict\(files.count == 1 ? "" : "s")")
                        .font(.callout)
                    Spacer()
                    Button("Resolve in Claude") { pane = .claude }
                    Button("Continue") { Task { await model.continueRebase(id: review.id) } }
                    Button("Abort") { Task { await model.abortRebase(id: review.id) } }
                }
                .padding(8)
                .background(Color.orange.opacity(0.12))
            }
            if case .failed(let message) = model.rebaseStates[review.id] {
                HStack(spacing: 8) {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    Text("Rebase failed: \(message)").font(.callout).lineLimit(2)
                    Spacer()
                    Button("Dismiss") { Task { await model.abortRebase(id: review.id) } }
                }
                .padding(8)
                .background(Color.red.opacity(0.12))
            }
```
(`model` is already available in `DetailView`; `pane` is the local `@State`. `rebaseStates`/`Pushability` are `public` on `AppModel`.)

- [ ] **Step 3: Build the app**: `xcodegen generate && xcodebuild … build` → BUILD SUCCEEDED.
- [ ] **Step 4: Commit**
```bash
git add App/ContentView.swift App/DetailView.swift
git commit -m "feat(ui): rebase/push context actions and conflict banner" --no-verify
```

---

## Task 6: Verify

- [ ] **Step 1:** `swift test --package-path Core` → all pass.
- [ ] **Step 2:** `xcodegen generate && xcodebuild … build` → BUILD SUCCEEDED.
- [ ] **Step 3 (controller, manual — careful, live data):** Create a task, make a commit in its worktree, then Push (confirm it lands on origin and a force-with-lease is used only when diverged). For an existing My PR, open it (worktree converts to branch when clean), and confirm Rebase on the base works (or shows the conflict banner). Confirm `refreshWorktree` no longer resets a branch worktree (the guard). Controller decides whether to run against real teranode clones or a throwaway repo.

---

## Self-Review

**Spec coverage:** Rebase local-only with conflict flow (Resolve/Continue/Abort) ✓; separate Push with `--force-with-lease` when diverged, disabled when nothing to push ✓; My-PR worktree-on-branch incl. clean detached→branch conversion ✓; refresh guard ✓. Editability = `category != .reviewRequest`.

**Placeholder scan:** Task 4's test approach is conditional (seam vs temp-repo integration) with an explicit fallback instruction (report DONE_WITH_CONCERNS proposing a `WorktreeManaging` seam) — a real decision rule, not a TBD. The orchestration code is fully specified.

**Type consistency:** `RebaseOutcome {clean, conflicts([String])}`; `WorktreeManager` `currentBranch`/`isClean`/`checkoutBranchWorktree`/`removeWorktreeForcing`/`rebaseOnto`/`rebaseContinue`/`rebaseAbort`/`push`/`aheadBehind`; `WorktreeProviding.ensureWorktree(for:editable:registeredClonePath:progress:)`; `AppModel.rebaseStates`/`pushability`/`rebase`/`continueRebase`/`abortRebase`/`push`/`refreshPushability`. UI gates on `category != .reviewRequest && headBranch != nil`.

**Risks:** (1) `AppModel` needs concrete `WorktreeManager` access — Task 4 resolves the wiring by reading the composition root; a `WorktreeManaging` protocol seam is the fallback for testability. (2) The detached→branch conversion only runs when clean — dirty worktrees are never clobbered (Rebase/Push simply stay unavailable until clean). (3) `aheadBehind` upstream `origin/<branch>` must exist — for a never-pushed task branch it won't; `refreshPushability` `try?`-guards and treats a missing upstream as "can push" only when ahead resolves — verify a never-pushed branch reports canPush (its first push creates the upstream; for a brand-new branch with no `origin/<branch>`, `aheadBehind` throws and pushability becomes nil → Push disabled until first push via... ) — **Task 4 must handle the never-pushed-branch case**: if `origin/<branch>` doesn't exist, `canPush = (local has commits)` and `needsForce = false`. Implement that fallback in `refreshPushability`.

---

## Milestone complete after B5

This is the final phase of the work-item reframe (`docs/superpowers/specs/2026-06-02-work-item-reframe-design.md`). After merge, consider `/gsd:complete-milestone` or a milestone summary.
