import Foundation
import Testing

@testable import SwitchboardCore

/// `id(from:)` accepts a URL only when its text is exactly what `url(for:)` builds for a session id. Any app or
/// web page can open the scheme, so each refused case changes one thing about `switchboard://session/seb4ec`.
@Suite struct SessionLinkTests {
  @Test func urlForAnIdIsTheSchemeTheHostAndTheId() {
    #expect(SessionLink.url(for: "seb4ec").absoluteString == "switchboard://session/seb4ec")
  }

  /// Launch Services hands the app a URL parsed from text, so the round trip goes through the text.
  @Test(arguments: ["seb4ec", "sgcctv", "s23456", "szzzzz", "sebc4e"])
  func idFromTheTextOfTheURLForAnIdGivesTheId(_ id: String) throws {
    let url = try #require(URL(string: SessionLink.url(for: id).absoluteString))

    #expect(SessionLink.id(from: url) == id)
  }

  @Test(arguments: ["seb4ec", "sgcctv", "s23456", "szzzzz", "sebc4e"])
  func idFromTheURLForAnIdGivesTheId(_ id: String) {
    #expect(SessionLink.id(from: SessionLink.url(for: id)) == id)
  }

  @Test func idFromAParsedSessionURLGivesTheId() throws {
    let url = try #require(URL(string: "switchboard://session/seb4ec"))

    #expect(SessionLink.id(from: url) == "seb4ec")
  }

  @Test func idFromAURLBuiltFromComponentsGivesTheId() throws {
    var components = URLComponents()
    components.scheme = "switchboard"
    components.host = "session"
    components.path = "/seb4ec"
    let url = try #require(components.url)

    #expect(SessionLink.id(from: url) == "seb4ec")
  }

  /// The window's URL handler passes each of these to the system, so a PR
  /// link or a Markdown link that names a session id keeps opening the browser.
  @Test(arguments: [
    "https://github.com/haacked/switchboard/pull/309",
    "https://example.com/seb4ec",
    "https://switchboard-session/seb4ec",
    "https://session/seb4ec",
    "http://session/seb4ec",
    "http://example.com/?session=seb4ec",
    "file:///tmp/seb4ec",
    "file:///Users/me/.sb/sessions/seb4ec/claude.sh",
    "mailto:seb4ec@example.com",
    "other:seb4ec",
    "other://session/seb4ec",
    "session:seb4ec",
  ])
  func aURLWithAnotherSchemeIsNotASessionLink(_ string: String) throws {
    let url = try #require(URL(string: string))

    #expect(SessionLink.id(from: url) == nil)
  }

  @Test func aFileURLMadeFromAPathIsNotASessionLink() {
    #expect(SessionLink.id(from: URL(fileURLWithPath: "/tmp/seb4ec")) == nil)
  }

  /// Each case is the canonical `switchboard://session/seb4ec` with one change.
  @Test(arguments: [
    // Case
    "SWITCHBOARD://session/seb4ec",
    "Switchboard://session/seb4ec",
    "switchboard://SESSION/seb4ec",
    "switchboard://Session/seb4ec",
    // Query and fragment
    "switchboard://session/seb4ec?x=1",
    "switchboard://session/seb4ec?",
    "switchboard://session/seb4ec#top",
    "switchboard://session/seb4ec#",
    // Path
    "switchboard://session/seb4ec/",
    "switchboard://session/seb4ec/claude.sh",
    "switchboard://session//seb4ec",
    "switchboard://session/./seb4ec",
    "switchboard://session/x/../seb4ec",
    "switchboard://session/seb4ec;x",
    "switchboard://session/",
    "switchboard://session",
    // User info and port
    "switchboard://u@session/seb4ec",
    "switchboard://u:p@session/seb4ec",
    "switchboard://@session/seb4ec",
    "switchboard://session:80/seb4ec",
    "switchboard://session:/seb4ec",
    // Host
    "switchboard://other/seb4ec",
    "switchboard://seb4ec",
    "switchboard://session./seb4ec",
    "switchboard:///session/seb4ec",
    "switchboard://",
    "switchboard:",
    // Percent-escapes
    "switchboard://session/%73eb4ec",
    "switchboard://session/seb4e%63",
    "switchboard://session/seb4ec%20",
    "switchboard://session/%20seb4ec",
    "switchboard://%73ession/seb4ec",
    // Other forms of the scheme
    "switchboard:seb4ec",
    "switchboard:/session/seb4ec",
    "switchboard:session/seb4ec",
    "switchboard-session:seb4ec",
    "switchboard-session://session/seb4ec",
  ])
  func aSwitchboardURLThatURLForDoesNotBuildIsNotASessionLink(_ string: String) throws {
    let url = try #require(URL(string: string))

    #expect(SessionLink.id(from: url) == nil)
  }

  /// Assumes that `id(from:)` accepts only the session id format
  /// `s[a-km-np-z2-9]{5}` that `shortId` generates.
  @Test(arguments: [
    "switchboard://session/seb4ecx",
    "switchboard://session/seb4e",
    "switchboard://session/SEB4EC",
    "switchboard://session/Seb4ec",
    "switchboard://session/g4rvrf",
    "switchboard://session/w3k9ap",
    "switchboard://session/sl0o1x",
    "switchboard://session/s",
  ])
  func aSessionURLWhoseIdIsNotASessionIdIsNotASessionLink(_ string: String) throws {
    let url = try #require(URL(string: string))

    #expect(SessionLink.id(from: url) == nil)
  }
}
