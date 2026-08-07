# GitHub Pane Progress Bar & Clearing the Updated Badge

**Date:** 2026-08-07
**Status:** Approved

Two small, independent additions, specified together because they ship together.

---

## Part 1 — Progress bar for the GitHub pane

### Problem

Selecting the GitHub tab shows nothing while the page loads. Loads are deferred until the
web view is on screen (so WebKit doesn't throttle a windowless view to a crawl), which means
the wait starts exactly when the user looks at the pane — and a heavy PR page can sit blank
for seconds with no sign that anything is happening.

### Design

**`WebLoadState` (`PRPilotModels`)** — the state machine, kept out of the view so it can be
tested:

```swift
public struct WebLoadState: Sendable, Equatable {
    public private(set) var isLoading: Bool
    public private(set) var progress: Double
    public mutating func started()              // isLoading = true, progress = 0
    public mutating func progressed(to: Double) // clamped to 0…1; ignored when not loading
    public mutating func finished()             // isLoading = false, progress = 1
    public mutating func failed()               // isLoading = false, progress = 0
}
```

`progressed(to:)` ignores updates while not loading because `WKWebView.estimatedProgress`
keeps reporting after `didFinish`; without the guard a late callback would re-show the bar.

**`LoadTracker` (`App/WebViewCache.swift`)** already implements the four navigation
callbacks and the process-termination hook. It gains an `onStateChange` closure and owns an
`NSKeyValueObservation` on `webView.estimatedProgress`, hopping to the main actor via
`MainActor.assumeIsolated` — the idiom already used in `TranscriptWatcher`.

**`WebViewCache`** is already `@Observable` and publishes
`private(set) var loadStates: [String: WebLoadState]`, the same per-item dictionary pattern
`AppModel` uses for `prStatuses`.

**`WebPane`** renders a 2pt strip between the toolbar and the existing divider: an accent
`Rectangle` whose width is `geometry.width * progress`, animated linearly over 0.15s, with
the strip at `opacity(isLoading ? 1 : 0)` on a 0.25s ease-out so it fades rather than
vanishes. The strip is always laid out, so nothing reflows when a load starts or ends; idle
is simply an empty 2pt band. `⌘R` drives it too, since `reload()` fires
`didStartProvisionalNavigation`.

### Error handling

`didFail`, `didFailProvisionalNavigation` and a terminated web content process all reset to
hidden. The cache's existing recovery paths re-drive the load, which shows the bar again. No
error UI: the pane already self-heals, and a persistent error surface is a separate feature.

---

## Part 2 — Clearing the Updated badge

### Problem

The `Updated` chip is derived fresh from GitHub each poll and deliberately persists nothing:
it shows while the newest author activity post-dates the user's newest review, and clears
when they review again. There is no way to dismiss one they have looked at but do not intend
to re-review yet.

### Design

**`WorkItem.authorUpdateSeenAt: Date?`** — persisted, `decodeIfPresent` so existing stores
migrate silently.

The action stores the item's **current `authorUpdatedAt`**, not `Date()`. The watermark means
"I have seen up to here", so any later author activity re-badges. Stamping the wall clock
instead would swallow an update landing in the same instant.

**`AuthorUpdate.isUnseen(updatedAt:seenAt:)`** — the whole comparison, pure and tested:

```swift
public static func isUnseen(updatedAt: Date?, seenAt: Date?) -> Bool {
    guard let updatedAt else { return false }
    guard let seenAt else { return true }
    return updatedAt > seenAt
}
```

**`AppModel`** gains `hasUnseenAuthorUpdate(_ item: WorkItem) -> Bool`, combining the runtime
`prStatuses[item.id]?.authorUpdatedAt` with the persisted watermark, and
`markAuthorUpdateSeen(id:)`, which upserts and reloads — the shape of the existing
`setIssueStatus` and `markClaudeReviewed` actions.

**UI** — the chip's condition becomes `model.hasUnseenAuthorUpdate(review)`. A context-menu
item `Clear Updated Badge` sits beside `Clear Claude Session`, matching that naming. It is
disabled when no badge is showing, and omitted for issue items, which use the separate issue
status badge.

### Interaction with the automatic rule

Unchanged. Reviewing again still clears the chip by making `authorUpdatedAt` nil. The
watermark then goes stale and is harmlessly superseded by the next update, which will be
newer than it.

---

## Testing

**`WebLoadState`**: start sets loading with zero progress; progress clamps below 0 and above
1; progress is ignored when not loading; finish clears loading; failure clears loading and
progress; a late progress callback after finish does not re-show the bar.

**`AuthorUpdate.isUnseen`**: no update → false; update with no watermark → true; update newer
than watermark → true; update equal to or older than watermark → false.

**`AppModel`**: `markAuthorUpdateSeen` persists the watermark and flips
`hasUnseenAuthorUpdate` to false; a subsequent newer `authorUpdatedAt` flips it back to true;
the action is a no-op for an unknown id.

The views themselves cannot be unit tested — the Xcode project builds `App` with no test
bundle — so the bar and the menu item are verified by building, running and screenshotting.
