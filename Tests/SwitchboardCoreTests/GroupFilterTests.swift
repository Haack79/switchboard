import Testing

@testable import SwitchboardCore

private func session(
  _ id: String, group: String? = nil, kind: SessionKind = .work, chat: String? = nil, followup: Bool = false,
  docket: Bool = false, state: AttentionState = .working
) -> SessionSummary {
  var s = SessionSummary(
    id: id, name: id, cwd: "/tmp/\(id)", repo: nil, branch: nil, claudeSessionId: id, state: state, reason: "",
    since: 0, lastActivity: 0, live: true, claudePid: nil, attached: false, lastReply: nil, waits: [], notes: [])
  s.group = group
  s.kind = kind
  switch kind {
  case .manager, .operator: s.manager = true
  case .chat: s.chat = chat
  case .work: break
  }
  if followup {
    s.cwd = ""
    s.followup = Followup(prompt: "p")
  }
  if docket {
    s.cwd = ""
    s.docket = DocketSummary(DocketSession(pullRequest: "o/r#1", url: "https://github.com/o/r/pull/1"), DocketStatus())
  }
  return s
}

private func group(_ id: String, _ name: String, _ sessions: [String] = []) -> GroupSummary {
  GroupSummary(SessionGroup(id: id, name: name, created: 0), sessions: sessions)
}

private let ungrouped = GroupFilter.ungroupedKey
private let known: Set<String> = ["g1", "g2"]

private let inG1 = session("a", group: "g1")
private let inG2 = session("b", group: "g2")
private let noGroup = session("u")
private let stale = session("s", group: "gone")
private let chatG1 = session("c1", kind: .chat, chat: "g1")
private let chatG2 = session("c2", kind: .chat, chat: "g2")
private let chatOfDeleted = session("cd", kind: .chat, chat: "gone")
private let manager = session("m", kind: .manager)
private let operatorSession = session("o", kind: .operator)

@Suite struct GroupFilterTests {

  @Test func theUngroupedKeyIsNotAGroupId() {
    #expect(GroupFilter.ungroupedKey == "(ungrouped)")
  }

  @Test func allTitleSaysAllGroups() {
    #expect(GroupFilter.allTitle == "All Groups")
  }

  // MARK: key(of:known:)

  struct KeyCase: Sendable, CustomTestStringConvertible {
    var name: String
    var session: SessionSummary
    var known: Set<String>?
    var key: String?
    var testDescription: String { name }
  }

  @Test(arguments: [
    KeyCase(name: "work session in a known group", session: inG1, known: known, key: "g1"),
    KeyCase(name: "work session in a group before groups load", session: inG1, known: nil, key: "g1"),
    KeyCase(name: "work session in no group", session: noGroup, known: known, key: ungrouped),
    KeyCase(name: "work session in no group before groups load", session: noGroup, known: nil, key: ungrouped),
    KeyCase(name: "stale group id, known set lacks it", session: stale, known: known, key: ungrouped),
    KeyCase(name: "stale group id, known is empty", session: stale, known: [], key: ungrouped),
    KeyCase(name: "stale group id before groups load", session: stale, known: nil, key: "gone"),
    KeyCase(name: "a group chat", session: chatG1, known: known, key: "g1"),
    KeyCase(name: "a group chat before groups load", session: chatG1, known: nil, key: "g1"),
    KeyCase(name: "the chat of a deleted group", session: chatOfDeleted, known: known, key: ungrouped),
    KeyCase(name: "the chat of a deleted group before groups load", session: chatOfDeleted, known: nil, key: "gone"),
    KeyCase(name: "the Manager", session: manager, known: known, key: nil),
    KeyCase(name: "the Manager before groups load", session: manager, known: nil, key: nil),
    KeyCase(
      name: "the Manager with a group field", session: session("m2", group: "g1", kind: .manager), known: known,
      key: nil),
    KeyCase(name: "the operator", session: operatorSession, known: known, key: nil),
    KeyCase(name: "the operator before groups load", session: operatorSession, known: nil, key: nil),
    KeyCase(name: "follow-up in a group", session: session("f", group: "g1", followup: true), known: known, key: "g1"),
    KeyCase(name: "follow-up in no group", session: session("f", followup: true), known: known, key: ungrouped),
    KeyCase(name: "docket row in a group", session: session("d", group: "g2", docket: true), known: known, key: "g2"),
    KeyCase(name: "docket row in no group", session: session("d", docket: true), known: known, key: ungrouped),
  ])
  func keyOfASessionFollowsItsKindAndTheKnownGroups(_ c: KeyCase) {
    #expect(GroupFilter.key(of: c.session, known: c.known) == c.key)
  }

  // MARK: Ungrouped parity with the Board's lanes

  struct ParityCase: Sendable, CustomTestStringConvertible {
    var name: String
    var session: SessionSummary
    var testDescription: String { name }
  }

  static let parityCases = [
    ParityCase(name: "nil group", session: noGroup),
    ParityCase(name: "known group", session: inG1),
    ParityCase(name: "other known group", session: inG2),
    ParityCase(name: "stale group id", session: stale),
    ParityCase(name: "empty group id", session: session("e", group: "")),
    ParityCase(name: "follow-up with a group", session: session("f", group: "g1", followup: true)),
    ParityCase(name: "follow-up with a stale group", session: session("f", group: "gone", followup: true)),
    ParityCase(name: "follow-up without a group", session: session("f", followup: true)),
    ParityCase(name: "docket row with a group", session: session("d", group: "g2", docket: true)),
    ParityCase(name: "docket row without a group", session: session("d", docket: true)),
  ]

  static let knownSets: [Set<String>] = [[], ["g1"], ["g1", "g2"]]

  /// Once groups load, the filter's Ungrouped entry and the Board's Ungrouped lane hold the same work sessions.
  @Test(arguments: parityCases, knownSets)
  func ungroupedKeyMatchesTheBoardsUngroupedLane(_ c: ParityCase, _ known: Set<String>) {
    let key = GroupFilter.key(of: c.session, known: known)
    let lane = BoardRows.group(of: c.session, known: known)

    #expect((key == GroupFilter.ungroupedKey) == (lane == nil))
  }

  @Test(arguments: parityCases, knownSets)
  func aGroupKeyNamesTheBoardsLane(_ c: ParityCase, _ known: Set<String>) {
    let key = GroupFilter.key(of: c.session, known: known)
    let lane = BoardRows.group(of: c.session, known: known)

    #expect(key == (lane ?? GroupFilter.ungroupedKey))
  }

  // MARK: shows

  static let everySession = [inG1, inG2, noGroup, stale, chatG1, chatG2, chatOfDeleted, manager, operatorSession]

  @Test(arguments: everySession, [known, nil] as [Set<String>?])
  func allGroupsShowsEverySession(_ s: SessionSummary, _ known: Set<String>?) {
    #expect(GroupFilter().isAll)
    #expect(GroupFilter().shows(s, known: known))
  }

  struct ShowsCase: Sendable, CustomTestStringConvertible {
    var name: String
    var filter: GroupFilter
    var known: Set<String>?
    var shown: Set<String>
    var testDescription: String { name }
  }

  @Test(arguments: [
    ShowsCase(name: "one group", filter: GroupFilter(keys: ["g1"]), known: known, shown: ["a", "c1", "m", "o"]),
    ShowsCase(
      name: "Ungrouped", filter: GroupFilter(keys: [ungrouped]), known: known, shown: ["u", "s", "cd", "m", "o"]),
    ShowsCase(
      name: "a group and Ungrouped", filter: GroupFilter(keys: ["g1", ungrouped]), known: known,
      shown: ["a", "c1", "u", "s", "cd", "m", "o"]),
    ShowsCase(name: "an unknown group id", filter: GroupFilter(keys: ["gx"]), known: known, shown: ["m", "o"]),
    ShowsCase(
      name: "a stale id once groups load", filter: GroupFilter(keys: ["gone"]), known: known, shown: ["m", "o"]),
    ShowsCase(
      name: "one group before groups load", filter: GroupFilter(keys: ["g1"]), known: nil, shown: ["a", "c1", "m", "o"]),
    ShowsCase(
      name: "a stale id before groups load", filter: GroupFilter(keys: ["gone"]), known: nil,
      shown: ["s", "cd", "m", "o"]),
    ShowsCase(
      name: "Ungrouped before groups load", filter: GroupFilter(keys: [ungrouped]), known: nil, shown: ["u", "m", "o"]),
  ])
  func aFilterShowsItsGroupsAndSessionsWithNoKey(_ c: ShowsCase) {
    let shown = Set(Self.everySession.filter { c.filter.shows($0, known: c.known) }.map(\.id))

    #expect(shown == c.shown)
  }

  @Test(arguments: [
    GroupFilter(), GroupFilter(keys: ["g1"]), GroupFilter(keys: [ungrouped]), GroupFilter(keys: ["g1", ungrouped]),
    GroupFilter(keys: ["gx"]),
  ])
  func theManagerAndOperatorShowUnderEveryFilter(_ filter: GroupFilter) {
    for k in [known, nil] as [Set<String>?] {
      #expect(filter.shows(manager, known: k))
      #expect(filter.shows(operatorSession, known: k))
    }
  }

  // MARK: KeyFilter

  @Test func aListDropsSpacesAndEmptyItems() {
    #expect(GroupFilter(list: " g1, g2,, ").keys == ["g1", "g2"])
  }

  @Test func toggleFromAllGroupsSelectsOnlyThatKeyAndTogglingItAgainGivesAll() {
    var filter = GroupFilter()

    filter.toggle("g1")
    #expect(filter.keys == ["g1"])

    filter.toggle("g1")
    #expect(filter.isAll)
  }

  @Test func insertAddsAKeyBesideTheSelectedOnes() {
    var filter = GroupFilter(keys: ["g1"])

    filter.insert(ungrouped)

    #expect(filter.keys == ["g1", ungrouped])
  }

  // MARK: entries

  static let groups = [group("g1", "Infra", ["a"]), group("g2", "Web", ["b"]), group("g3", "Empty")]

  @Test func entriesFollowTheGroupsOrderWithEmptyGroupsAtZero() {
    let groups = [group("g2", "Web"), group("g3", "Empty"), group("g1", "Infra")]

    let entries = GroupFilter().entries([inG1, inG2], groups: groups, known: Set(groups.map(\.id)))

    #expect(entries.map(\.key) == ["g2", "g3", "g1"])
    #expect(entries.map(\.title) == ["Web", "Empty", "Infra"])
    #expect(entries.map(\.count) == [1, 0, 1])
  }

  @Test func ungroupedComesLastWhenItHasSessions() {
    let entries = GroupFilter().entries([noGroup, inG1, stale], groups: Self.groups, known: ["g1", "g2", "g3"])

    let last = entries.last
    #expect(last?.key == ungrouped)
    #expect(last?.title == BoardRows.ungroupedTitle)
    #expect(last?.title == "Ungrouped")
    #expect(last?.count == 2)
  }

  @Test func ungroupedIsLeftOutWhenNoSessionIsUngroupedAndItIsNotSelected() {
    let entries = GroupFilter(keys: ["g1"]).entries([inG1, inG2, chatG1, manager], groups: Self.groups, known: known)

    #expect(!entries.contains { $0.key == ungrouped })
  }

  @Test func ungroupedIsListedAtZeroWhenItIsSelectedAndEmpty() {
    let entries = GroupFilter(keys: [ungrouped]).entries([inG1], groups: Self.groups, known: ["g1", "g2", "g3"])

    #expect(entries.last?.key == ungrouped)
    #expect(entries.last?.count == 0)
  }

  @Test func aChatCountsInItsGroup() {
    let entries = GroupFilter().entries([inG1, chatG1], groups: Self.groups, known: ["g1", "g2", "g3"])

    #expect(entries.first { $0.key == "g1" }?.count == 2)
  }

  @Test func theManagerAndOperatorCountNowhere() {
    let entries = GroupFilter().entries([manager, operatorSession], groups: Self.groups, known: ["g1", "g2", "g3"])

    #expect(entries.map(\.count) == [0, 0, 0])
    #expect(!entries.contains { $0.key == ungrouped })
  }

  @Test func entriesCountTheSessionsThatNeedYou() {
    let sessions = [
      session("a1", group: "g1", state: .needsYou), session("a2", group: "g1", state: .readyToMerge),
      session("a3", group: "g1", state: .working), session("b1", group: "g2", state: .done),
      session("u1", state: .needsYou),
    ]

    let entries = GroupFilter().entries(sessions, groups: Self.groups, known: ["g1", "g2", "g3"])

    #expect(entries.first { $0.key == "g1" }.map { [$0.count, $0.needsYou] } == [3, 2])
    #expect(entries.first { $0.key == "g2" }.map { [$0.count, $0.needsYou] } == [1, 0])
    #expect(entries.first { $0.key == ungrouped }.map { [$0.count, $0.needsYou] } == [1, 1])
  }

  @Test func aSelectedKeyThatNoListedGroupHasIsTitledByItsKey() {
    let entries = GroupFilter(keys: ["gone"]).entries([inG1], groups: Self.groups, known: ["g1", "g2", "g3"])

    let gone = entries.first { $0.key == "gone" }
    #expect(gone?.title == "gone")
    #expect(gone?.count == 0)
  }

  @Test func beforeGroupsLoadASelectedKeyIsTitledByItsKeyAndCountsByRawId() {
    let entries = GroupFilter(keys: ["g1"]).entries([inG1, chatG1], groups: [], known: nil)

    let g1 = entries.first { $0.key == "g1" }
    #expect(g1?.title == "g1")
    #expect(g1?.count == 2)
  }

  // MARK: label

  @Test(arguments: [
    ([] as [String], "All Groups"),
    (["g1"], "Infra"),
    (["g1", "g2"], "Infra, Web"),
    (["g1", ungrouped], "Infra, Ungrouped"),
    (["g1", "g2", "g3"], "Infra +2"),
    (["g1", "g2", "g3", ungrouped], "Infra +3"),
  ])
  func labelNamesTheSelectedGroups(_ keys: [String], _ label: String) {
    let filter = GroupFilter(keys: keys)

    let entries = filter.entries([inG1, inG2, noGroup], groups: Self.groups, known: ["g1", "g2", "g3"])

    #expect(filter.label(entries) == label)
  }

  @Test func aRenamedGroupStaysSelectedAndShowsItsNewTitle() {
    let filter = GroupFilter(keys: ["g1"])
    let renamed = [group("g1", "Platform", ["a"]), group("g2", "Web", ["b"])]

    let entries = filter.entries([inG1, inG2], groups: renamed, known: ["g1", "g2"])

    #expect(filter.label(entries) == "Platform")
    #expect(filter.shows(inG1, known: ["g1", "g2"]))
  }
}
