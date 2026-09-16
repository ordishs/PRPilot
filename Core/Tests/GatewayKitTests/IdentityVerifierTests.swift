import Testing
@testable import GatewayKit

@Test func theBearerVerifierAcceptsTheExactToken() {
    let verifier = BearerTokenVerifier(token: "s3cret")

    #expect(verifier.verify(headers: ["authorization": "Bearer s3cret"]) != nil)
}

@Test func theBearerVerifierIsCaseInsensitiveOnTheSchemeButNotTheToken() {
    let verifier = BearerTokenVerifier(token: "s3cret")

    #expect(verifier.verify(headers: ["authorization": "bearer s3cret"]) != nil)
    #expect(verifier.verify(headers: ["authorization": "Bearer S3CRET"]) == nil)
}

@Test func theBearerVerifierRejectsAWrongOrMissingToken() {
    let verifier = BearerTokenVerifier(token: "s3cret")

    #expect(verifier.verify(headers: ["authorization": "Bearer wrong"]) == nil)
    #expect(verifier.verify(headers: ["authorization": "s3cret"]) == nil)
    #expect(verifier.verify(headers: [:]) == nil)
}

@Test func theBearerVerifierRejectsATokenThatIsAPrefixOfTheRealOne() {
    let verifier = BearerTokenVerifier(token: "s3cret")

    #expect(verifier.verify(headers: ["authorization": "Bearer s3cre"]) == nil)
    #expect(verifier.verify(headers: ["authorization": "Bearer s3cretX"]) == nil)
}

@Test func theBearerVerifierReportsTheTailnetUserWhenTheProxySuppliedOne() {
    let verifier = BearerTokenVerifier(token: "s3cret")
    let identity = verifier.verify(
        headers: ["authorization": "Bearer s3cret", "tailscale-user-login": "me@example.com"]
    )

    #expect(identity?.login == "me@example.com")
}

@Test func theBearerVerifierStillAcceptsWhenNoTailnetUserIsSupplied() {
    let verifier = BearerTokenVerifier(token: "s3cret")
    let identity = verifier.verify(headers: ["authorization": "Bearer s3cret"])

    #expect(identity != nil)
    #expect(identity?.login == nil)
}

@Test func aForgedTailnetHeaderAloneDoesNotAuthenticate() {
    let verifier = BearerTokenVerifier(token: "s3cret")

    #expect(verifier.verify(headers: ["tailscale-user-login": "me@example.com"]) == nil)
}

@Test func theHeaderVerifierAcceptsAnAllowlistedLogin() {
    let verifier = TailnetHeaderVerifier(
        headerName: "tailscale-user-login",
        allowlist: ["me@example.com"]
    )

    #expect(verifier.verify(headers: ["tailscale-user-login": "me@example.com"])?.login == "me@example.com")
}

@Test func theHeaderVerifierRejectsALoginThatIsNotAllowlisted() {
    let verifier = TailnetHeaderVerifier(
        headerName: "tailscale-user-login",
        allowlist: ["me@example.com"]
    )

    #expect(verifier.verify(headers: ["tailscale-user-login": "someone@else.com"]) == nil)
    #expect(verifier.verify(headers: [:]) == nil)
}

@Test func anEmptyAllowlistRejectsEveryLogin() {
    let verifier = TailnetHeaderVerifier(headerName: "tailscale-user-login", allowlist: [])

    #expect(verifier.verify(headers: ["tailscale-user-login": "me@example.com"]) == nil)
}
