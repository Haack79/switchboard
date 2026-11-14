import Foundation
import Testing

@testable import SwitchboardCore

private let second = "https://claude.ai/artifact/SecondPage"
private let secondUUID = "55555555-1111-2222-3333-444444444444"

private func artifact(
  _ url: String = artifactShortURL, id: String? = artifactUUID, title: String = "Delta Rates", published: Int64,
  updated: Int64, removed: Int64? = nil
) -> SessionArtifact {
  SessionArtifact(
    url: url, artifactId: id, title: title, published: published, updated: updated, removed: removed)
}

/// The rows that `forgetSession` keeps for a removed session: its entries with its id and name.
private func kept(_ artifacts: [SessionArtifact], session: String, name: String) -> [GroupArtifact] {
  artifacts.map {
    GroupArtifact(
      url: $0.url, artifactId: $0.artifactId, title: $0.title, published: $0.published, updated: $0.updated,
      removed: $0.removed, session: session, sessionName: name)
  }
}

private func row(
  _ url: String = artifactShortURL, id: String? = artifactUUID, title: String = "Delta Rates", published: Int64,
  updated: Int64, removed: Int64? = nil, session: String, name: String
) -> GroupArtifact {
  GroupArtifact(
    url: url, artifactId: id, title: title, published: published, updated: updated, removed: removed,
    session: session, sessionName: name)
}

/// A live member or the group's chat, with its artifacts.
struct ArtifactMember: Sendable {
  var id: String
  var name: String
  var artifacts: [SessionArtifact]
}

private func list(_ live: [ArtifactMember], kept: [GroupArtifact] = []) -> [GroupArtifact] {
  GroupArtifacts.list(live: live.map { (session: $0.id, name: $0.name, artifacts: $0.artifacts) }, kept: kept)
}

/// The group list (`GroupArtifacts.list`): live members' and the chat's entries plus the kept rows, one row per
/// artifact, newest `updated` first.
@Suite struct GroupArtifactsTests {
  @Test func noInputsListNothing() {
    #expect(list([]).isEmpty)
  }

  @Test func aLiveMembersEntryBecomesARowWithItsIdAndName() {
    let s = ArtifactMember(id: "s1", name: "flags-cache", artifacts: [artifact(published: 1000, updated: 2000)])

    #expect(list([s]) == [row(published: 1000, updated: 2000, session: "s1", name: "flags-cache")])
  }

  @Test func aKeptRowIsListedAsItWasKept() {
    let k = row(published: 1000, updated: 2000, removed: 3000, session: "gone", name: "old-name")

    #expect(list([], kept: [k]) == [k])
  }

  // MARK: Same artifact

  @Test func twoRowsWithTheSameURLMergeIntoOneFromTheLatestUpdate() {
    let a = ArtifactMember(id: "a", name: "alpha", artifacts: [artifact(title: "Old", published: 1000, updated: 2000)])
    let b = ArtifactMember(id: "b", name: "bravo", artifacts: [artifact(title: "New", published: 1500, updated: 4000)])

    let rows = list([a, b])

    #expect(rows == [row(title: "New", published: 1000, updated: 4000, session: "b", name: "bravo")])
  }

  @Test func aLiveRowAndAKeptRowWithTheSameURLMerge() {
    let b = ArtifactMember(id: "b", name: "bravo", artifacts: [artifact(title: "Live", published: 3000, updated: 3000)])
    let k = row(title: "Kept", published: 1000, updated: 2000, session: "gone", name: "removed-one")

    let rows = list([b], kept: [k])

    #expect(rows == [row(title: "Live", published: 1000, updated: 3000, session: "b", name: "bravo")])
  }

  /// A `/code/artifact/<uuid>` link and the short link name the same artifact when the ids match.
  @Test func rowsWithTheSameArtifactIdMergeAcrossLinkForms() {
    let a = ArtifactMember(
      id: "a", name: "alpha", artifacts: [artifact(artifactShortURL, published: 1000, updated: 1000)])
    let b = ArtifactMember(
      id: "b", name: "bravo", artifacts: [artifact(artifactCodeURL, published: 2000, updated: 2000)])

    let rows = list([a, b])

    #expect(rows.count == 1)
    #expect(rows.first?.session == "b")
    #expect(rows.first?.published == 1000)
    #expect(rows.first?.updated == 2000)
  }

  @Test func rowsWithDifferentURLsAndNoIdsStaySeparate() {
    let a = ArtifactMember(
      id: "a", name: "alpha",
      artifacts: [
        artifact(artifactShortURL, id: nil, published: 1000, updated: 1000),
        artifact(second, id: nil, title: "Second", published: 1000, updated: 2000),
      ])

    #expect(list([a]).map(\.url) == [second, artifactShortURL])
  }

  @Test func rowsWithDifferentURLsAndDifferentIdsStaySeparate() {
    let a = ArtifactMember(id: "a", name: "alpha", artifacts: [artifact(published: 1000, updated: 1000)])
    let b = ArtifactMember(
      id: "b", name: "bravo", artifacts: [artifact(second, id: secondUUID, published: 1000, updated: 2000)])

    #expect(list([a, b]).count == 2)
  }

  /// The rule is not transitive: the short link matches the code link by id, and the code link matches an
  /// id-less row by URL. All three are one artifact, whatever the order of the members.
  @Test func aChainOfMatchesMergesIntoOneRowInEveryOrder() {
    let members = [
      ArtifactMember(id: "a", name: "alpha", artifacts: [artifact(published: 1000, updated: 1000)]),
      ArtifactMember(id: "b", name: "bravo", artifacts: [artifact(artifactCodeURL, published: 2000, updated: 2000)]),
      ArtifactMember(
        id: "c", name: "charlie", artifacts: [artifact(artifactCodeURL, id: nil, published: 3000, updated: 3000)]),
    ]
    let orders = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]

    let lists = orders.map { order in list(order.map { members[$0] }) }

    #expect(
      lists.first
        == [
          row(artifactCodeURL, id: artifactUUID, published: 1000, updated: 3000, session: "c", name: "charlie")
        ])
    #expect(Set(lists.map { "\($0)" }).count == 1)
  }

  // MARK: Removed

  /// `removed` is set when the latest removal among the merged rows is at or after their latest update.
  @Test(arguments: [(5000, 3000, 5000), (3000, 3000, 3000), (2000, 3000, nil)] as [(Int64, Int64, Int64?)])
  func theMergedRowIsRemovedOnlyWhenTheLatestRemovalIsAtOrAfterTheLatestUpdate(
    removedAt: Int64, otherUpdated: Int64, removed: Int64?
  ) {
    let a = ArtifactMember(
      id: "a", name: "alpha", artifacts: [artifact(published: 1000, updated: 1000, removed: removedAt)])
    let b = ArtifactMember(id: "b", name: "bravo", artifacts: [artifact(published: 1500, updated: otherUpdated)])

    let rows = list([a, b])

    #expect(rows.map(\.removed) == [removed])
  }

  @Test func aRemovedRowStaysInTheList() {
    let a = ArtifactMember(id: "a", name: "alpha", artifacts: [artifact(published: 1000, updated: 1000, removed: 2000)])

    #expect(list([a]).map(\.removed) == [2000])
  }

  // MARK: Order

  @Test func rowsSortByUpdatedNewestFirst() {
    let a = ArtifactMember(
      id: "a", name: "alpha",
      artifacts: [
        artifact(published: 1000, updated: 1000),
        artifact(second, id: secondUUID, title: "Second", published: 1000, updated: 3000),
      ])
    let third = "https://claude.ai/artifact/ThirdPage"
    let k = row(third, id: nil, title: "Third", published: 500, updated: 2000, session: "gone", name: "gone")

    #expect(list([a], kept: [k]).map(\.url) == [second, third, artifactShortURL])
  }

  @Test func rowsWithEqualUpdatedSortByURL() {
    let z = "https://claude.ai/artifact/ZZZ"
    let a = "https://claude.ai/artifact/AAA"
    let m = ArtifactMember(
      id: "m", name: "member",
      artifacts: [
        artifact(z, id: nil, published: 1000, updated: 1000), artifact(a, id: nil, published: 1000, updated: 1000),
      ])

    #expect(list([m]).map(\.url) == [a, z])
  }

  // MARK: The same list before and after sb rm

  /// A group whose member `s` has artifacts, with the other members and the kept rows around it.
  struct RemovalCase: Sendable, CustomTestStringConvertible {
    var name: String
    var s: [SessionArtifact]
    var others: [ArtifactMember] = []
    var kept: [GroupArtifact] = []
    var testDescription: String { name }
  }

  static let removals: [RemovalCase] = [
    RemovalCase(name: "one artifact", s: [artifact(published: 1000, updated: 2000)]),
    RemovalCase(name: "a removed entry", s: [artifact(published: 1000, updated: 2000, removed: 3000)]),
    RemovalCase(
      name: "the same URL live in another member, updated later", s: [artifact(published: 1000, updated: 2000)],
      others: [
        ArtifactMember(id: "b", name: "bravo", artifacts: [artifact(title: "B", published: 1500, updated: 4000)])
      ]),
    RemovalCase(
      name: "the same URL live in another member, updated earlier", s: [artifact(published: 1000, updated: 5000)],
      others: [
        ArtifactMember(id: "b", name: "bravo", artifacts: [artifact(title: "B", published: 1500, updated: 4000)])
      ]),
    RemovalCase(
      name: "the same URL kept from a removed session", s: [artifact(published: 3000, updated: 3000)],
      kept: [row(title: "Old", published: 1000, updated: 2000, removed: 2500, session: "gone", name: "gone")]),
    RemovalCase(
      name: "the same artifact by id under the code link",
      s: [artifact(artifactCodeURL, published: 1000, updated: 2000)],
      others: [ArtifactMember(id: "b", name: "bravo", artifacts: [artifact(published: 1500, updated: 1500)])]),
    RemovalCase(
      name: "two artifacts with equal updated",
      s: [artifact(published: 1000, updated: 2000), artifact(second, id: secondUUID, published: 1000, updated: 2000)]),
    RemovalCase(
      name: "the same URL with equal updated in another member",
      s: [artifact(title: "S", published: 1000, updated: 2000)],
      others: [
        ArtifactMember(id: "b", name: "bravo", artifacts: [artifact(title: "B", published: 1000, updated: 2000)])
      ]),
    RemovalCase(
      name: "a removal at the other member's update time",
      s: [artifact(published: 1000, updated: 1000, removed: 2000)],
      others: [ArtifactMember(id: "b", name: "bravo", artifacts: [artifact(published: 1500, updated: 2000)])]),
  ]

  /// `forgetSession` turns the member's entries into kept rows with its id and name. The list must not change.
  @Test(arguments: removals)
  func theListIsTheSameWhetherTheMemberIsLiveOrKept(_ c: RemovalCase) {
    let others = c.others
    let s = ArtifactMember(id: "s", name: "flags-cache", artifacts: c.s)

    let live: [ArtifactMember] = others + [s]
    let keptRows: [GroupArtifact] = c.kept + kept(c.s, session: s.id, name: s.name)

    let before = list(live, kept: c.kept)
    let after = list(others, kept: keptRows)

    #expect(after == before)
  }

  /// A live list does not depend on the order of the members.
  @Test(arguments: removals)
  func theListDoesNotDependOnTheOrderOfTheMembers(_ c: RemovalCase) {
    let others = c.others
    let s = ArtifactMember(id: "s", name: "flags-cache", artifacts: c.s)

    let last: [ArtifactMember] = others + [s]
    let first: [ArtifactMember] = [s] + others

    #expect(list(last, kept: c.kept) == list(first, kept: c.kept))
  }

  /// The group's chat publishes plan artifacts. Its entries list like a member's.
  @Test func theChatsEntriesListLikeAMembers() {
    let chat = ArtifactMember(id: "c1", name: "Flags chat", artifacts: [artifact(published: 1000, updated: 1000)])
    let member = ArtifactMember(
      id: "s1", name: "alpha", artifacts: [artifact(second, id: secondUUID, published: 2000, updated: 2000)])

    #expect(list([member, chat]).map(\.session) == ["s1", "c1"])
  }

  // MARK: names(_:)

  @Test(arguments: [
    (artifactShortURL, true),
    ("\(artifactShortURL)?v=2#top", true),
    ("HTTPS://CLAUDE.AI/artifact/\(artifactShortId)", true),
    (artifactCodeURL, true),
    ("https://claude.ai/artifact/\(artifactUUID)", true),
    (second, false),
    ("https://claude.ai/code/artifact/\(secondUUID)", false),
    ("https://evil.com/artifact/\(artifactShortId)", false),
    ("", false),
  ])
  func namesMatchesTheSameURLOrTheSameId(_ url: String, _ names: Bool) {
    let r = row(published: 1000, updated: 1000, session: "s1", name: "alpha")

    #expect(r.names(url) == names)
  }

  @Test func namesDoesNotMatchByIdWhenTheRowHasNoId() {
    let r = row(id: nil, published: 1000, updated: 1000, session: "s1", name: "alpha")

    #expect(!r.names(artifactCodeURL))
    #expect(r.names(artifactShortURL))
  }
}

/// A group keeps its removed sessions' rows in `SessionGroup.artifacts`, and a merge carries them.
@Suite struct GroupKeptArtifactsTests {
  private func group(_ id: String, _ name: String, artifacts: [GroupArtifact]? = nil) -> SessionGroup {
    var g = SessionGroup(id: id, name: name, created: 1)
    g.artifacts = artifacts
    return g
  }

  @Test func aGroupThatAnOlderSbdStoredHasNoKeptArtifacts() throws {
    let g = try JSONCoding.decode(
      SessionGroup.self, from: #"{"id": "g1", "name": "Flags", "notes": [], "created": 1}"#)

    #expect(g.artifacts == nil)
  }

  @Test func keptArtifactsSurviveEncoding() throws {
    let g = group(
      "g1", "Flags", artifacts: [row(published: 1000, updated: 2000, removed: 3000, session: "s1", name: "alpha")])

    #expect(try JSONCoding.decode(SessionGroup.self, from: try JSONCoding.encode(g)) == g)
  }

  /// The JSON is flat, so `jq '.groups[].artifacts[].url'` reads each URL.
  @Test func aKeptRowEncodesItsFieldsFlat() throws {
    let r = row(published: 1000, updated: 2000, removed: 3000, session: "s1", name: "alpha")

    let json = try #require(JSON.parse(try JSONCoding.encode(r)))

    #expect(json["url"]?.string == artifactShortURL)
    #expect(json["artifactId"]?.string == artifactUUID)
    #expect(json["title"]?.string == "Delta Rates")
    #expect(json["published"]?.int == 1000)
    #expect(json["updated"]?.int == 2000)
    #expect(json["removed"]?.int == 3000)
    #expect(json["session"]?.string == "s1")
    #expect(json["sessionName"]?.string == "alpha")
  }

  @Test func absorbingAppendsTheOtherGroupsKeptRows() {
    let mine = row(published: 1000, updated: 1000, session: "a", name: "alpha")
    let theirs = row(second, id: secondUUID, published: 2000, updated: 2000, session: "b", name: "bravo")

    let merged = group("g1", "Flags", artifacts: [mine]).absorbing(group("g2", "Docs", artifacts: [theirs]), now: 30)

    #expect(merged.artifacts == [mine, theirs])
  }

  @Test func absorbingIntoAGroupWithoutKeptRowsTakesTheOthers() {
    let theirs = row(published: 2000, updated: 2000, session: "b", name: "bravo")

    let merged = group("g1", "Flags").absorbing(group("g2", "Docs", artifacts: [theirs]), now: 30)

    #expect(merged.artifacts == [theirs])
  }

  @Test func absorbingAGroupWithoutKeptRowsKeepsThisGroupsRows() {
    let mine = row(published: 1000, updated: 1000, session: "a", name: "alpha")

    let merged = group("g1", "Flags", artifacts: [mine]).absorbing(group("g2", "Docs"), now: 30)

    #expect(merged.artifacts == [mine])
  }

  @Test func absorbingTwoGroupsWithoutKeptRowsKeepsNone() {
    let merged = group("g1", "Flags").absorbing(group("g2", "Docs"), now: 30)

    #expect((merged.artifacts ?? []).isEmpty)
  }

  /// The merged rows list like the two groups' rows together.
  @Test func absorbingKeepsTheGroupListOfBothGroups() {
    let mine = row(published: 1000, updated: 1000, session: "a", name: "alpha")
    let theirs = row(published: 500, updated: 3000, session: "b", name: "bravo")

    let merged = group("g1", "Flags", artifacts: [mine]).absorbing(group("g2", "Docs", artifacts: [theirs]), now: 30)

    #expect(list([], kept: merged.artifacts ?? []) == list([], kept: [mine, theirs]))
  }
}
