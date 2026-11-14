import Foundation
import Testing

@testable import SwitchboardCore

/// The suite's name holds `RemovalJobTests`, so the removal job's `--filter RemovalJobTests` runs it.
@Suite struct StoredRemovalJobTests {
  @Test func aSessionThatAnOlderSbdStoredHasNoRemoval() throws {
    let json = #"{"id":"s1","name":"one","cwd":"/a","claudeSessionId":"u1","created":5,"started":true,"done":false}"#

    #expect(try JSONCoding.decode(Session.self, from: json).removal == nil)
  }

  /// The app decodes `ls` from an sbd that predates the removal job.
  @Test func aSummaryFromAnOlderSbdHasNoRemoval() throws {
    let summary = SessionSummary(
      id: "s1", name: "one", cwd: "/a", repo: nil, branch: nil, claudeSessionId: "u1", state: .done,
      reason: "marked done", since: 0, lastActivity: 0, live: false, claudePid: nil, attached: false,
      lastReply: nil, waits: [], notes: [])
    var fields = try #require(try JSON(encoding: summary).object)
    fields["removal"] = nil

    #expect(try JSONCoding.decode(SessionSummary.self, from: JSON.object(fields).text).removal == nil)
  }

  /// A row that an earlier build of the removal job stored without `released`, `notBefore`, or `resolve` still
  /// loads, because one row that fails to decode stops sbd from loading every session.
  @Test func aRemovalStoredWithoutTheLaterFieldsLoads() throws {
    let json: JSON = [
      "id": "s1", "name": "one", "cwd": "/a", "claudeSessionId": "u1", "created": 5, "started": true, "done": true,
      "removal": ["state": "failed", "requested": 1000, "worktree": true, "branch": false, "remoteBranch": false],
    ]

    let removal = try #require(try JSONCoding.decode(Session.self, from: json.text).removal)

    #expect(!removal.released)
    #expect(removal.notBefore == 1000)
    #expect(removal.resolve.isEmpty)
  }

  /// Every field of a removal survives the store's JSON, so a restart resumes the removal with the
  /// arguments, the trash path, and the to-dos that the user confirmed.
  @Test func aRemovalRoundTripsThroughTheStoredJSON() throws {
    let json: JSON = [
      "id": "s1", "name": "one", "cwd": "/a", "claudeSessionId": "u1", "created": 5, "started": true, "done": true,
      "removal": [
        "state": "running", "requested": 1000, "notBefore": 6000, "worktree": true, "branch": true,
        "remoteBranch": true, "trash": "/sb/trash/s1", "released": true, "resolve": ["n1", "n2"],
      ],
    ]
    let session = try JSONCoding.decode(Session.self, from: json.text)

    let again = try JSONCoding.decode(Session.self, from: JSONCoding.encode(session))

    #expect(again == session)
    let stored = try #require(try JSON(encoding: again)["removal"])
    #expect(stored["state"] == "running")
    #expect(stored["requested"] == 1000)
    #expect(stored["trash"] == "/sb/trash/s1")
    #expect(stored["released"] == true)
    #expect(stored["resolve"] == ["n1", "n2"])
  }
}
