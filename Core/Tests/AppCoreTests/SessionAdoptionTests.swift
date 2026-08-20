import Testing
import Foundation
@testable import AppCore

private let started = Date(timeIntervalSince1970: 1_000_000)
private let afterStart = started.addingTimeInterval(30)
private let beforeStart = started.addingTimeInterval(-3600)

private func adopted(
    watched: String? = "new-id",
    stored: String? = "launched-id",
    eventDate: Date = afterStart,
    sessionStartedAt: Date? = started,
    idsOwnedByOtherItems: Set<String> = [],
    transcriptDirectoryIsShared: Bool = false
) -> String? {
    SessionAdoption.adoptedSessionID(
        watched: watched,
        stored: stored,
        eventDate: eventDate,
        sessionStartedAt: sessionStartedAt,
        idsOwnedByOtherItems: idsOwnedByOtherItems,
        transcriptDirectoryIsShared: transcriptDirectoryIsShared
    )
}

/// `/clear` inside the terminal starts a new transcript under a new id. The item still stores
/// the id it launched with, so the next resume reopens the conversation the user threw away.
@Test func adoptsTheIdTheAgentIsActuallyWritingTo() {
    #expect(adopted() == "new-id")
}

@Test func adoptsNothingWhenTheWatchedFileIsAlreadyTheStoredOne() {
    #expect(adopted(watched: "launched-id") == nil)
}

@Test func adoptsNothingWithoutAWatchedFile() {
    #expect(adopted(watched: nil) == nil)
    #expect(adopted(watched: "") == nil)
}

/// An item with no stored id at all still adopts: `ensureAgentSession` falls back to the
/// newest transcript in that case, and recording it saves the next launch the guesswork.
@Test func adoptsWhenTheItemHasNoStoredIdYet() {
    #expect(adopted(stored: nil) == "new-id")
}

/// The watcher replays a transcript from the start every time it attaches, so the first
/// events it delivers describe an earlier run. Those must not rewrite the stored id.
@Test func aReplayedEventNeverChangesTheStoredId() {
    #expect(adopted(eventDate: beforeStart) == nil)
}

@Test func anEventExactlyAtTheProcessStartCounts() {
    #expect(adopted(eventDate: started) == "new-id")
}

@Test func adoptsNothingWhenTheSessionStartIsUnknown() {
    #expect(adopted(sessionStartedAt: nil) == nil)
}

/// Two items can point at the same clone, so their transcript directories are the same
/// directory and each watcher sees the other's files. Taking an id another item owns would
/// hand one item's conversation to another.
@Test func neverStealsAnIdAnotherItemOwns() {
    #expect(adopted(idsOwnedByOtherItems: ["new-id"]) == nil)
    #expect(adopted(idsOwnedByOtherItems: ["someone-else"]) == "new-id")
}

/// The same ambiguity, before anyone has stored the id: if another live session shares this
/// transcript directory, the newest file there may not be ours at all.
@Test func neverAdoptsFromASharedTranscriptDirectory() {
    #expect(adopted(transcriptDirectoryIsShared: true) == nil)
}
