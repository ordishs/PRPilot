import Testing
import Foundation
@testable import PRPilotModels

@Test func sidebarSortDisplayNames() {
    #expect(SidebarSort.recent.displayName == "Recent")
    #expect(SidebarSort.byStatus.displayName == "By status")
    #expect(SidebarSort.byAuthor.displayName == "By author")
}

@Test func sidebarSortMapsLegacyGrouping() {
    #expect(SidebarSort(legacyGrouping: "byStatus") == .byStatus)
    #expect(SidebarSort(legacyGrouping: "byAuthor") == .byAuthor)
    #expect(SidebarSort(legacyGrouping: "byCategory") == .recent)
    #expect(SidebarSort(legacyGrouping: "none") == .recent)
    #expect(SidebarSort(legacyGrouping: "byDate") == .recent)
    #expect(SidebarSort(legacyGrouping: "garbage") == .recent)
}
