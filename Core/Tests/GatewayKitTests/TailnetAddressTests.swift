import Testing
import PRPilotModels
@testable import GatewayKit

@Test func theWholeCarrierGradeNatRangeCountsAsTailscale() {
    #expect(TailnetAddress.isTailscale("100.64.0.0"))
    #expect(TailnetAddress.isTailscale("100.96.202.45"))
    #expect(TailnetAddress.isTailscale("100.127.255.255"))
}

@Test func addressesJustOutsideTheRangeDoNotCount() {
    // 100.63.x and 100.128.x are ordinary public space, not Tailscale.
    #expect(!TailnetAddress.isTailscale("100.63.255.255"))
    #expect(!TailnetAddress.isTailscale("100.128.0.0"))
    #expect(!TailnetAddress.isTailscale("99.64.0.1"))
    #expect(!TailnetAddress.isTailscale("101.64.0.1"))
}

@Test func ordinaryPrivateAndLoopbackAddressesDoNotCount() {
    #expect(!TailnetAddress.isTailscale("127.0.0.1"))
    #expect(!TailnetAddress.isTailscale("192.168.4.150"))
    #expect(!TailnetAddress.isTailscale("10.0.0.1"))
    #expect(!TailnetAddress.isTailscale("0.0.0.0"))
}

@Test func malformedInputIsRejectedRatherThanGuessedAt() {
    #expect(!TailnetAddress.isTailscale(""))
    #expect(!TailnetAddress.isTailscale("100.96.202"))
    #expect(!TailnetAddress.isTailscale("100.96.202.45.6"))
    #expect(!TailnetAddress.isTailscale("100.96.202.256"))
    #expect(!TailnetAddress.isTailscale("100.96.202.-1"))
    #expect(!TailnetAddress.isTailscale("100.96.202.4a"))
    #expect(!TailnetAddress.isTailscale("100..202.45"))
    #expect(!TailnetAddress.isTailscale("fd7a:115c:a1e0::aa37:ca2e"))
}

@Test func theLoopbackScopeNeverWidensBeyondLoopback() {
    #expect(TailnetAddress.bindAddress(for: .loopback) == "127.0.0.1")
}

@Test func theTailnetScopeFallsBackToLoopbackRatherThanBindingSomethingWider() {
    let bound = TailnetAddress.bindAddress(for: .tailnet)

    // On a machine with Tailscale up this is the tailnet address; with it down it is
    // loopback. It must never be a LAN address or a wildcard.
    #expect(bound == "127.0.0.1" || TailnetAddress.isTailscale(bound))
    #expect(bound != "0.0.0.0")
}

@Test func bothScopesHaveALabelForTheSettingsPicker() {
    #expect(GatewayBindScope.loopback.displayName == "This Mac only")
    #expect(GatewayBindScope.tailnet.displayName == "Tailnet")
    #expect(GatewayBindScope.allCases.count == 2)
}
