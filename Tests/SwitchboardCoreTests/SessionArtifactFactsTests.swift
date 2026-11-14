import Foundation
import Testing

@testable import SwitchboardCore

private func publish(
  _ t: Int64, url: String = artifactShortURL, artifactId: String? = artifactUUID, title: String? = "Delta Rates",
  input: [String: JSON] = artifactFirstInput, agent: String? = nil
) -> Event {
  artifactHook(
    t, input: input, response: artifactPublishResponse(url: url, artifactId: artifactId, title: title), agent: agent)
}

private func republish(_ t: Int64, title: String? = "Delta Rates v2", artifactId: String? = artifactUUID) -> Event {
  artifactHook(
    t, input: artifactFirstInput.merging(["url": .string(artifactShortURL)]) { $1 },
    response: artifactPublishResponse(artifactId: artifactId, title: title, republish: true))
}

private func delete(_ t: Int64, _ url: String = artifactShortURL) -> Event {
  artifactHook(t, input: ["action": "delete", "url": .string(url)], response: nil)
}

/// How `SessionFacts.apply` folds Artifact hooks into `artifacts`: one entry per URL in first-publish order, with
/// the first and last publish times, the latest title, and the delete time.
@Suite struct SessionArtifactFactsTests {
  @Test func aNewSessionHasNoArtifacts() {
    #expect(SessionFacts().artifacts.isEmpty)
  }

  @Test func aFirstPublishAddsAnEntry() {
    let f = facts([publish(1000)])

    #expect(
      f.artifacts == [
        SessionArtifact(
          url: artifactShortURL, artifactId: artifactUUID, title: "Delta Rates", published: 1000, updated: 1000,
          removed: nil)
      ])
  }

  @Test func aRepublishUpdatesTheOneEntry() {
    let f = facts([publish(1000), republish(5000)])

    #expect(
      f.artifacts == [
        SessionArtifact(
          url: artifactShortURL, artifactId: artifactUUID, title: "Delta Rates v2", published: 1000, updated: 5000,
          removed: nil)
      ])
  }

  /// A redeploy by `file_path` alone has no input `url`. The response's `url` still names the entry.
  @Test func aRedeployByFilePathAloneUpdatesTheSameEntry() {
    let f = facts([publish(1000), publish(5000, title: "Delta Rates v2")])

    #expect(f.artifacts.map(\.url) == [artifactShortURL])
    #expect(f.artifacts.map(\.updated) == [5000])
    #expect(f.artifacts.map(\.published) == [1000])
  }

  @Test func entriesKeepTheirFirstPublishOrder() {
    let second = "https://claude.ai/artifact/SecondPage"
    let f = facts([
      publish(1000), publish(2000, url: second, artifactId: "55555555-1111-2222-3333-444444444444", title: "Second"),
      republish(3000),
    ])

    #expect(f.artifacts.map(\.url) == [artifactShortURL, second])
  }

  /// The guard compares normalized links, so a response URL with a query names the same entry.
  @Test func aRepublishWithAQueryInTheResponseURLUpdatesTheSameEntry() {
    let f = facts([publish(1000), publish(5000, url: "\(artifactShortURL)?v=2")])

    #expect(f.artifacts.count == 1)
    #expect(f.artifacts.first?.updated == 5000)
  }

  // MARK: Title

  @Test func theTitleFallsBackToTheInputTitle() {
    let f = facts([publish(1000, title: nil, input: artifactFirstInput.merging(["title": "From Input"]) { $1 })])

    #expect(f.artifacts.map(\.title) == ["From Input"])
  }

  @Test func theResponseTitleWinsOverTheInputTitle() {
    let f = facts([
      publish(1000, title: "From Response", input: artifactFirstInput.merging(["title": "From Input"]) { $1 })
    ])

    #expect(f.artifacts.map(\.title) == ["From Response"])
  }

  @Test func aRepublishWithoutATitleKeepsTheEntrysTitle() {
    let f = facts([publish(1000), republish(5000, title: nil)])

    #expect(f.artifacts.map(\.title) == ["Delta Rates"])
  }

  @Test func aPublishWithoutAnyTitleUsesTheLinksLastPathComponent() {
    let f = facts([publish(1000, title: nil)])

    #expect(f.artifacts.map(\.title) == [artifactShortId])
  }

  /// A title with no text after `oneLine` counts as no title.
  @Test func aBlankTitleFallsBackToTheInputTitleAndThenTheLinkId() {
    let blankResponse = facts([
      publish(1000, title: "\n  \n", input: artifactFirstInput.merging(["title": "From Input"]) { $1 })
    ])
    let blankBoth = facts([publish(1000, title: " ", input: artifactFirstInput.merging(["title": "\n"]) { $1 })])

    #expect(blankResponse.artifacts.map(\.title) == ["From Input"])
    #expect(blankBoth.artifacts.map(\.title) == [artifactShortId])
  }

  /// The title is untrusted text from the tool result. It is stored on one line of at most 200 characters.
  @Test(arguments: [
    ("Delta\nRates", "Delta Rates"),
    ("  Delta  \n\n  Rates  ", "Delta Rates"),
    (String(repeating: "x", count: 300), String(repeating: "x", count: 199) + "…"),
  ])
  func theTitleIsStoredThroughOneLine(_ raw: String, _ stored: String) {
    let f = facts([publish(1000, title: raw)])

    #expect(f.artifacts.map(\.title) == [stored])
  }

  // MARK: Artifact id

  @Test func aTypeCreateHasNoArtifactId() {
    let f = facts([
      artifactHook(
        1000, input: ["action": "publish", "type_url": "https://claude.ai/artifact/DocsType1", "title": "Q4 Plan"],
        response: artifactTypeCreateResponse())
    ])

    #expect(f.artifacts.map(\.artifactId) == [nil])
    #expect(f.artifacts.map(\.title) == ["Q4 Plan"])
  }

  @Test func aRepublishFillsAMissingArtifactId() {
    let f = facts([
      artifactHook(
        1000, input: ["action": "publish", "type_url": "https://claude.ai/artifact/DocsType1", "title": "Q4 Plan"],
        response: artifactTypeCreateResponse()),
      republish(5000),
    ])

    #expect(f.artifacts.map(\.artifactId) == [artifactUUID])
  }

  @Test func aRepublishWithoutAnArtifactIdKeepsTheEntrysId() {
    let f = facts([publish(1000), republish(5000, artifactId: nil)])

    #expect(f.artifacts.map(\.artifactId) == [artifactUUID])
  }

  // MARK: Delete

  @Test func aDeleteSetsRemovedAndKeepsTheEntry() {
    let f = facts([publish(1000), delete(5000)])

    #expect(
      f.artifacts == [
        SessionArtifact(
          url: artifactShortURL, artifactId: artifactUUID, title: "Delta Rates", published: 1000, updated: 1000,
          removed: 5000)
      ])
  }

  @Test func aDeleteByTheCodeLinkMatchesTheEntryByItsArtifactId() {
    let f = facts([publish(1000), delete(5000, artifactCodeURL)])

    #expect(f.artifacts.map(\.removed) == [5000])
  }

  @Test func aDeleteOfALinkThatMatchesNoEntryChangesNothing() {
    let before = facts([publish(1000)])

    let after = facts([publish(1000), delete(5000, "https://claude.ai/artifact/SomeOtherPage")])

    #expect(after.artifacts == before.artifacts)
  }

  @Test func aDeleteThenARepublishClearsRemovedAndMovesUpdated() {
    let f = facts([publish(1000), delete(5000), republish(9000)])

    #expect(
      f.artifacts == [
        SessionArtifact(
          url: artifactShortURL, artifactId: artifactUUID, title: "Delta Rates v2", published: 1000, updated: 9000,
          removed: nil)
      ])
  }

  @Test func aDeleteBeforeAnyPublishAddsNothing() {
    let f = facts([delete(1000)])

    #expect(f.artifacts.isEmpty)
  }

  // MARK: Subagents

  /// Unlike the attention rules, the artifact list does not skip a subagent's hooks.
  @Test func aSubagentsPublishCountsForTheSession() {
    let f = facts([publish(1000, agent: "a1b2c3d4e5")])

    #expect(f.artifacts.map(\.url) == [artifactShortURL])
  }

  @Test func aSubagentsDeleteMarksTheSessionsEntry() {
    let f = facts([
      publish(1000),
      artifactHook(
        5000, input: ["action": "delete", "url": .string(artifactShortURL)], response: nil, agent: "a1b2c3"),
    ])

    #expect(f.artifacts.map(\.removed) == [5000])
  }

  // MARK: Encoding

  @Test func theArtifactsSurviveEncoding() throws {
    let f = facts([publish(1000), republish(5000), delete(9000)])

    let decoded = try JSONCoding.decode(SessionFacts.self, from: try JSONCoding.encode(f))

    #expect(decoded.artifacts == f.artifacts)
  }
}

/// Startup builds facts from a snapshot and the events after it. For Artifact events, that gives the
/// same replay as applying the whole log, wherever the snapshot cuts it.
@Suite struct SessionArtifactSnapshotTests {
  let session = Session(id: "s1", name: "one", cwd: "/tmp/a", branch: "main", claudeSessionId: "u1", created: 5)

  func history() -> [Event] {
    let other = "https://claude.ai/artifact/SecondPage"
    return [
      event("started", 500), event("SessionStart", 600, ["transcript_path": "/tmp/t.jsonl"]),
      event("UserPromptSubmit", 700, ["prompt": "publish the report"]),
      publish(1000),
      artifactHook(
        1500, input: ["action": "open", "url": .string(artifactShortURL)],
        response: ["url": .string(artifactShortURL), "title": "Delta Rates", "opened": true]),
      publish(2000, url: other, artifactId: "55555555-1111-2222-3333-444444444444", title: "Second", agent: "a1b2"),
      republish(3000),
      delete(4000, "https://claude.ai/code/artifact/55555555-1111-2222-3333-444444444444"),
      event("Stop", 4500, ["last_assistant_message": "Published."]),
      delete(5000),
      republish(6000, title: "Delta Rates v3"),
    ]
  }

  /// What the history leaves, so a parity check over two empty lists can't pass.
  var expected: [SessionArtifact] {
    [
      SessionArtifact(
        url: artifactShortURL, artifactId: artifactUUID, title: "Delta Rates v3", published: 1000, updated: 6000,
        removed: nil),
      SessionArtifact(
        url: "https://claude.ai/artifact/SecondPage", artifactId: "55555555-1111-2222-3333-444444444444",
        title: "Second", published: 2000, updated: 2000, removed: 4000),
    ]
  }

  @Test func aFullReplayBuildsTheExpectedArtifacts() {
    #expect(SessionReplay.replaying(history(), session: session).facts.artifacts == expected)
  }

  @Test func theSnapshotAndTheTailBuildWhatAFullReplayBuildsAtEveryCut() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let store = try Store(path: "\(dir)/sb.db")
    let events = history()
    for cut in 1..<events.count {
      try store.delete(session: SessionRemoval(id: session.id, name: session.name))
      try store.save(session)
      for e in events[..<cut] { try store.append(e) }
      try Snapshots.refresh(store, session, build: "b1")
      for e in events[cut...] { try store.append(e) }

      let second = try Snapshots.refresh(store, session, build: "b1")

      let full = SessionReplay.replaying(try store.events(session: session.id), session: session)
      #expect(second.outcome == .snapshot(tail: events.count - cut), "cut \(cut)")
      #expect(second.snapshot.replay == full, "cut \(cut)")
      #expect(second.snapshot.replay.facts.artifacts == expected, "cut \(cut)")
    }
  }

  /// A snapshot that another build saved is replayed in full, so facts from a build without `artifacts` are not
  /// reused with an empty list.
  @Test func aSnapshotFromAnotherBuildIsReplayedWithItsArtifacts() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let store = try Store(path: "\(dir)/sb.db")
    try store.save(session)
    for e in history() { try store.append(e) }
    try Snapshots.refresh(store, session, build: "old")

    let refreshed = try Snapshots.refresh(store, session, build: "new")

    #expect(refreshed.outcome == .replay("snapshot is from another build", events: history().count))
    #expect(refreshed.snapshot.replay.facts.artifacts == expected)
  }
}
