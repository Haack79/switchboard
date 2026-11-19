import Foundation
import Testing

@testable import SwitchboardCore
@testable import SwitchboardService

/// A host can't send `runHere`, so only a terminal or the app on this Mac can let a work skill run in a Manager
/// conversation. The rule for `send` already leaves the key out, and this pins that.
@Suite struct ManagerSkillHostScopeTests {
  private static let sessions: [Session] = {
    var s = Session(id: "m1", name: "box", cwd: "/srv/repo", claudeSessionId: "u-m1", created: 5)
    s.host = "mini"
    s.started = true
    return [s]
  }()

  private func authorize(_ args: [String: JSON]) throws -> Request {
    try HostScope.authorize(Request(op: "send", args: .object(args)), host: "mini", sessions: Self.sessions)
  }

  @Test(arguments: [JSON.bool(true), .bool(false), .string("true")])
  func aSendFromAHostThatCarriesRunHereIsRefused(_ value: JSON) {
    #expect(throws: (any Error).self) {
      try authorize(["session": "m1", "text": "/go x", "runHere": value])
    }
  }

  @Test func theRefusalNamesRunHere() {
    do {
      _ = try authorize(["session": "m1", "text": "/go x", "runHere": true])
      Issue.record("a send with runHere from mini was authorized")
    } catch {
      #expect("\(error)".contains("doesn't take runHere"), "\(error)")
    }
  }

  @Test func theSameSendWithoutRunHereIsAuthorized() throws {
    let request = try authorize(["session": "m1", "text": "/go x"])

    #expect(request.args["runHere"] == nil)
  }

  @Test func theManagerSkillsOpIsRefusedFromAHost() {
    #expect(throws: (any Error).self) {
      try HostScope.authorize(
        Request(op: "manager-skills", args: ["relabel": ["go"]]), host: "mini", sessions: Self.sessions)
    }
  }
}
