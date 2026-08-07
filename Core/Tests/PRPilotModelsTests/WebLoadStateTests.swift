import Testing
import Foundation
@testable import PRPilotModels

@Test func idleStateShowsNothing() {
    let state = WebLoadState()
    #expect(state.isLoading == false)
    #expect(state.progress == 0)
}

@Test func startingALoadResetsProgress() {
    var state = WebLoadState()
    state.progressed(to: 0.8)
    state.started()
    #expect(state.isLoading)
    #expect(state.progress == 0)
}

@Test func progressAdvancesWhileLoading() {
    var state = WebLoadState()
    state.started()
    state.progressed(to: 0.42)
    #expect(state.progress == 0.42)
}

@Test func progressIsClampedToUnitRange() {
    var state = WebLoadState()
    state.started()
    state.progressed(to: -3)
    #expect(state.progress == 0)
    state.progressed(to: 7)
    #expect(state.progress == 1)
}

@Test func finishingHidesTheBarAtFullWidth() {
    var state = WebLoadState()
    state.started()
    state.progressed(to: 0.5)
    state.finished()
    #expect(state.isLoading == false)
    #expect(state.progress == 1)
}

@Test func lateProgressAfterFinishDoesNotReshowTheBar() {
    // WKWebView keeps reporting estimatedProgress after didFinish; a late callback must
    // not resurrect the bar.
    var state = WebLoadState()
    state.started()
    state.finished()
    state.progressed(to: 0.9)
    #expect(state.isLoading == false)
    #expect(state.progress == 1)
}

@Test func failureHidesTheBarAndResetsProgress() {
    var state = WebLoadState()
    state.started()
    state.progressed(to: 0.6)
    state.failed()
    #expect(state.isLoading == false)
    #expect(state.progress == 0)
}

@Test func aSecondLoadAfterFailureStartsCleanly() {
    var state = WebLoadState()
    state.started()
    state.failed()
    state.started()
    #expect(state.isLoading)
    #expect(state.progress == 0)
}
