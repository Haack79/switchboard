import AppKit
import Combine
import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// A group filter and the ids of `BoardModelGroupFilterTests.list` and `.followups` that it shows.
struct GroupShape: Sendable, CustomTestStringConvertible {
  var filter: GroupFilter
  var sessions: Set<String>
  var followups: [String]
  var testDescription: String { filter.isAll ? "All Groups" : filter.keys.sorted().joined(separator: ",") }
}

/// All Groups, one group, Ungrouped, a group with Ungrouped, another group, and a group with no sessions.
let everyGroupShape = [
  GroupShape(
    filter: GroupFilter(), sessions: ["i1", "i2", "w1", "w2", "u1", "m", "c1", "c2"], followups: ["f1", "f2"]),
  GroupShape(filter: GroupFilter(keys: ["g1"]), sessions: ["i1", "i2", "m", "c1"], followups: ["f1"]),
  GroupShape(filter: GroupFilter(keys: [GroupFilter.ungroupedKey]), sessions: ["u1", "m"], followups: ["f2"]),
  GroupShape(
    filter: GroupFilter(keys: ["g1", GroupFilter.ungroupedKey]), sessions: ["i1", "i2", "u1", "m", "c1"],
    followups: ["f1", "f2"]),
  GroupShape(filter: GroupFilter(keys: ["g2"]), sessions: ["w1", "w2", "m", "c2"], followups: []),
  GroupShape(filter: GroupFilter(keys: ["g3"]), sessions: ["m"], followups: []),
]

@MainActor
@Suite struct BoardModelGroupFilterTests {
  typealias Shown = BoardModelOrgFilterTests.Shown

  static let ungrouped = GroupFilter.ungroupedKey

  /// Infra (g1) holds a PostHog and a haacked session, Web (g2) the same, and Empty (g3) nothing. One PostHog
  /// session is in no group. Each group has a chat, and the Manager is in no group.
  nonisolated static let list = [
    groupedSession("i1", group: "g1", state: .needsYou),
    groupedSession("i2", group: "g1", org: "haacked", state: .needsYou),
    groupedSession("w1", group: "g2", state: .needsYou),
    groupedSession("w2", group: "g2", org: "haacked", state: .needsYou),
    groupedSession("u1", group: nil, state: .needsYou),
    needsItem("m", manager: true),
    chatItem("c1", group: "g1", state: .working),
    chatItem("c2", group: "g2", state: .working),
  ]
  nonisolated static let followups = [
    inGroup(unstartedFollowup("f1", "PostHog/f1"), "g1"), unstartedFollowup("f2", "PostHog/f2"),
  ]
  nonisolated static let groups = [
    group("g1", "Infra", ["i1", "i2", "f1"]), group("g2", "Web", ["w1", "w2"]), group("g3", "Empty", []),
  ]

  nonisolated static func inGroup(_ s: SessionSummary, _ group: String) -> SessionSummary {
    var s = s
    s.group = group
    return s
  }

  nonisolated static func group(_ id: String, _ name: String, _ sessions: [String]) -> GroupSummary {
    GroupSummary(SessionGroup(id: id, name: name, created: 0), sessions: sessions)
  }

  /// A model that has applied `list` and, unless `groups` is nil, sbd's answer to `group-ls`.
  func model(
    _ filter: GroupFilter, org: OrgFilter = OrgFilter(), _ list: [SessionSummary] = list,
    followups: [SessionSummary]? = followups, groups: [GroupSummary]? = groups, store: UserDefaults? = nil
  ) -> BoardModel {
    let model = orgFilterModel(org, groupFilter: filter, store: store)
    model.apply(.success(list), followups: followups)
    if let groups { model.applyGroups(groups) }
    return model
  }

  /// A model whose `send` answers every request with `answer`.
  func answering(_ model: BoardModel, _ answer: JSON = .null) -> BoardModel {
    model.send = { _, _ in answer }
    return model
  }

  func shownIds(_ model: BoardModel) -> Set<String> { Set(model.sessions.map(\.id) + model.followups.map(\.id)) }

  // MARK: What each group filter shape shows

  @Test(arguments: Shown.allCases, everyGroupShape)
  func eachDerivedListLeavesOutTheUnselectedGroupsSessions(_ shown: Shown, _ shape: GroupShape) {
    let ids = shown.ids(model(shape.filter))
    let all = shown.ids(model(GroupFilter()))

    #expect(ids == all.intersection(shape.sessions.union(shape.followups)), "\(shown.rawValue)")
  }

  @Test(arguments: Shown.allCases)
  func allGroupsLeavesOutNothingThatTodayShows(_ shown: Shown) {
    let filtered = shown.ids(model(GroupFilter()))
    let unfiltered = shown.ids(appliedModel(Self.list, followups: Self.followups))

    #expect(filtered == unfiltered, "\(shown.rawValue)")
  }

  @Test(arguments: everyGroupShape)
  func eachFilterShowsItsSessionsAfterARefresh(_ shape: GroupShape) {
    let model = model(shape.filter)

    #expect(Set(model.sessions.map(\.id)) == shape.sessions)
    #expect(model.followups.map(\.id) == shape.followups)
  }

  @Test(arguments: everyGroupShape)
  func eachFilterShowsItsSessionsAfterAFilterChange(_ shape: GroupShape) {
    let model = model(GroupFilter(keys: ["g2"]))

    model.groupFilter = shape.filter

    #expect(Set(model.sessions.map(\.id)) == shape.sessions)
    #expect(model.followups.map(\.id) == shape.followups)
  }

  @Test(arguments: everyGroupShape)
  func theManagerStaysUnderEveryGroupShape(_ shape: GroupShape) {
    let model = model(shape.filter)

    #expect(model.managers.map(\.id) == ["m"])
  }

  @Test func theFilterLeavesTheFullListsAlone() {
    let model = model(GroupFilter())

    model.groupFilter = GroupFilter(keys: ["g1"])

    #expect(model.allSessions == Self.list)
    #expect(model.allFollowups == Self.followups)
  }

  /// A session whose group sbd no longer lists sits in the Board's Ungrouped lane, so the Ungrouped filter shows it.
  @Test func aSessionWithAStaleGroupIdShowsUnderUngroupedAndNotUnderItsOldId() {
    let list = Self.list + [groupedSession("st", group: "gone")]

    let underUngrouped = model(GroupFilter(keys: [Self.ungrouped]), list)
    let underG1 = model(GroupFilter(keys: ["g1"]), list)

    #expect(underUngrouped.sessions.contains { $0.id == "st" })
    #expect(!underG1.sessions.contains { $0.id == "st" })
  }

  // MARK: Combined with the org filter

  @Test func aSessionHiddenByEitherFilterIsHidden() {
    let model = model(GroupFilter(keys: ["g1"]), org: posthogOnly)

    #expect(shownIds(model) == ["i1", "m", "c1", "f1"])
  }

  @Test(arguments: Shown.allCases)
  func eachDerivedListLeavesOutWhatEitherFilterHides(_ shown: Shown) {
    let ids = shown.ids(model(GroupFilter(keys: ["g1"]), org: posthogOnly))
    let all = shown.ids(model(GroupFilter()))

    #expect(ids == all.intersection(["i1", "m", "c1", "f1"]), "\(shown.rawValue)")
  }

  @Test func theHiddenCountCountsASessionHiddenByBothFiltersOnce() {
    let model = model(GroupFilter(keys: ["g1"]), org: posthogOnly)

    // i2 is hidden by the org filter, w1, u1, c2, and f2 by the group filter, and w2 by both.
    #expect(model.hiddenCount == 6)
    #expect(model.hiddenNeedingYou == 4)
  }

  @Test func theHiddenCountsUnderTheGroupFilterAlone() {
    let model = model(GroupFilter(keys: ["g1"]))

    #expect(model.hiddenCount == 5)
    #expect(model.hiddenNeedingYou == 3)
  }

  @Test func allGroupsAndAllOrgsHideNothing() {
    let model = model(GroupFilter())

    #expect(model.hiddenCount == 0)
    #expect(model.hiddenNeedingYou == 0)
  }

  // MARK: Group chats

  @Test func aChatHidesUnderAnotherGroupsFilterAndShowsUnderItsOwn() {
    #expect(!model(GroupFilter(keys: ["g2"])).sessions.contains { $0.id == "c1" })
    #expect(model(GroupFilter(keys: ["g1"])).sessions.contains { $0.id == "c1" })
  }

  @Test func aChatCardLeavesTheInboxUnderAnotherGroupsFilterAndJoinsItUnderItsOwn() throws {
    let list = Self.list + [try chatCard("cc", group: "g1")]

    let other = model(GroupFilter(keys: ["g2"]), list)
    let own = model(GroupFilter(keys: ["g1"]), list)

    #expect(!other.needsUser.contains { $0.id == "cc" })
    #expect(!other.triage.contains { $0.id == "cc" })
    #expect(own.needsUser.contains { $0.id == "cc" })
    #expect(own.triage.contains { $0.id == "cc" })
  }

  @Test func aHiddenChatCardCountsInHiddenNeedingYou() throws {
    let list = Self.list + [try chatCard("cc", group: "g1")]

    let withCard = model(GroupFilter(keys: ["g2"]), list)
    let withoutCard = model(GroupFilter(keys: ["g2"]))

    #expect(withCard.hiddenNeedingYou == withoutCard.hiddenNeedingYou + 1)
  }

  @Test(arguments: everyGroupShape)
  func hasOpenChatGivesTheSameAnswerUnderEveryFilter(_ shape: GroupShape) {
    let model = model(shape.filter)

    #expect(model.hasOpenChat("g1"))
    #expect(model.hasOpenChat("g2"))
    #expect(model.chat(of: "g1")?.id == "c1")
  }

  @Test func hasOpenChatIsTrueUnderAFilterThatHidesTheChat() {
    let model = model(GroupFilter(keys: ["g2"]))

    #expect(!model.sessions.contains { $0.id == "c1" })
    #expect(model.hasOpenChat("g1"))
  }

  // MARK: Persistence

  func withStore(_ body: (UserDefaults) throws -> Void) throws {
    let name = "group-filter-tests-" + UUID().uuidString
    let store = try #require(UserDefaults(suiteName: name))
    defer { store.removePersistentDomain(forName: name) }
    try body(store)
  }

  @Test func aModelWithAStoreSavesItsGroupKeysAndANewModelStartsWithThem() throws {
    try withStore { store in
      let first = orgFilterModel(store: store)

      first.groupFilter = GroupFilter(keys: ["g1", Self.ungrouped])

      #expect(Set(store.stringArray(forKey: "groupFilter") ?? []) == ["g1", Self.ungrouped])
      #expect(orgFilterModel(store: store).groupFilter == GroupFilter(keys: ["g1", Self.ungrouped]))
    }
  }

  @Test func theGroupFilterSavesBesideTheOrgFilter() throws {
    try withStore { store in
      let first = orgFilterModel(store: store)

      first.orgFilter = posthogOnly
      first.groupFilter = GroupFilter(keys: ["g1"])

      let second = orgFilterModel(store: store)
      #expect(second.orgFilter == posthogOnly)
      #expect(second.groupFilter == GroupFilter(keys: ["g1"]))
    }
  }

  @Test func clearingTheGroupFilterSavesAllGroups() throws {
    try withStore { store in
      let first = orgFilterModel(store: store)
      first.groupFilter = GroupFilter(keys: ["g1"])

      first.groupFilter = GroupFilter()

      #expect(orgFilterModel(store: store).groupFilter.isAll)
    }
  }

  @Test func aModelWithoutAStoreNeverWritesTheStandardDefaults() {
    let before = UserDefaults.standard.object(forKey: "groupFilter") as? [String]
    let model = orgFilterModel(store: nil)

    model.groupFilter = GroupFilter(keys: ["g-tests-\(UUID().uuidString.lowercased())"])

    #expect(UserDefaults.standard.object(forKey: "groupFilter") as? [String] == before)
  }

  @Test func aModelWithoutAStoreStartsWithTheGroupFilterItIsGiven() {
    #expect(orgFilterModel(groupFilter: GroupFilter(keys: ["g1"]), store: nil).groupFilter == GroupFilter(keys: ["g1"]))
  }

  // MARK: Pruning

  @Test func anAnswerWithoutOneOfTwoSelectedGroupsKeepsTheOtherAndSavesIt() throws {
    try withStore { store in
      let model = model(GroupFilter(keys: ["g1", "g2"]), groups: nil, store: store)

      model.applyGroups([Self.groups[0], Self.groups[2]])

      #expect(model.groupFilter == GroupFilter(keys: ["g1"]))
      #expect(store.stringArray(forKey: "groupFilter") == ["g1"])
    }
  }

  @Test func anAnswerWithoutTheOnlySelectedGroupFallsBackToAllGroups() throws {
    try withStore { store in
      let model = model(GroupFilter(keys: ["g2"]), groups: nil, store: store)

      model.applyGroups([Self.groups[0]])

      #expect(model.groupFilter.isAll)
      #expect(orgFilterModel(store: store).groupFilter.isAll)
    }
  }

  @Test func ungroupedSurvivesAnEmptyAnswer() {
    let model = model(GroupFilter(keys: [Self.ungrouped]), groups: nil)

    model.applyGroups([])

    #expect(model.groupFilter == GroupFilter(keys: [Self.ungrouped]))
  }

  @Test func anEmptyAnswerDropsEveryGroupIdAndKeepsUngrouped() {
    let model = model(GroupFilter(keys: ["g1", Self.ungrouped]), groups: nil)

    model.applyGroups([])

    #expect(model.groupFilter == GroupFilter(keys: [Self.ungrouped]))
  }

  /// A refresh can read `group-ls` before a group is created and apply the answer after the app selects it.
  @Test func anAnswerReadBeforeAGroupWasCreatedKeepsItSelectedUntilALaterAnswerDropsIt() {
    let model = model(GroupFilter(keys: ["g1"]), groups: nil)
    model.applyGroups([Self.groups[0]])
    model.showAnsweredGroup(["id": "g2"])

    model.applyGroups([Self.groups[0]])
    #expect(model.groupFilter == GroupFilter(keys: ["g1", "g2"]))

    model.applyGroups([Self.groups[0], Self.groups[1]])
    model.applyGroups([Self.groups[0]])
    #expect(model.groupFilter == GroupFilter(keys: ["g1"]))
  }

  /// Accepting a suggestion can answer with a group that sbd already listed. Deleting that group drops it.
  @Test func anAnsweredGroupThatSbdAlreadyListedLeavesTheFilterWhenItIsDeleted() {
    let model = model(GroupFilter(keys: [Self.ungrouped]))
    model.showAnsweredGroup(["id": "g1"])
    #expect(model.groupFilter == GroupFilter(keys: ["g1", Self.ungrouped]))

    model.applyGroups([Self.groups[1], Self.groups[2]])

    #expect(model.groupFilter == GroupFilter(keys: [Self.ungrouped]))
  }

  /// A group that the user made and that sbd deleted before any answer listed it leaves the filter after the
  /// answers that could predate it.
  @Test func aNewGroupThatNoAnswerListsLeavesTheFilterAfterTwoAnswers() {
    let model = model(GroupFilter(keys: [Self.ungrouped]))
    model.showAnsweredGroup(["id": "g9"])

    model.applyGroups(Self.groups)
    model.applyGroups(Self.groups)
    #expect(model.groupFilter.keys.contains("g9"))

    model.applyGroups(Self.groups)
    #expect(model.groupFilter == GroupFilter(keys: [Self.ungrouped]))
  }

  /// The first answer equals the model's initial empty `groups`, and it still prunes.
  @Test func anEmptyFirstAnswerPrunesTheSelection() {
    let model = model(GroupFilter(keys: ["g1"]), groups: nil)

    model.applyGroups([])

    #expect(model.groupFilter.isAll)
  }

  @Test func withoutAnAnswerTheSavedKeysStayEvenForADeletedGroup() throws {
    try withStore { store in
      store.set(["gone", "g1"], forKey: "groupFilter")

      let model = model(GroupFilter(), groups: nil, store: store)
      model.apply(.success(Self.list), followups: Self.followups)

      #expect(model.groupFilter == GroupFilter(keys: ["gone", "g1"]))
      #expect(Set(store.stringArray(forKey: "groupFilter") ?? []) == ["gone", "g1"])
    }
  }

  /// A selected id can name a group that no answer lists, such as one from a saved filter or a menu toggle.
  @Test func anAnswerAfterTheFirstDropsASelectedIdThatNoAnswerListed() {
    let model = model(GroupFilter())
    model.groupFilter = GroupFilter(keys: ["g1", "gx"])

    model.applyGroups(Self.groups)

    #expect(model.groupFilter == GroupFilter(keys: ["g1"]))
  }

  @Test func anOptimisticDeleteDoesNotPruneUntilTheNextAnswer() {
    let model = answering(model(GroupFilter(keys: ["g2"])))

    model.deleteGroup("g2")

    #expect(model.groupFilter == GroupFilter(keys: ["g2"]))

    model.applyGroups([Self.groups[0], Self.groups[2]])

    #expect(model.groupFilter.isAll)
  }

  @Test func anAnswerThatDropsNothingLeavesTheGroupKeys() {
    let model = model(GroupFilter(keys: ["g1", Self.ungrouped]), groups: nil)
    let before = model.groupFilter
    var assigned = 0
    let subscription = model.$filter.dropFirst().sink { if $0.group != before { assigned += 1 } }
    defer { subscription.cancel() }

    model.applyGroups(Self.groups)

    #expect(assigned == 0)
    #expect(model.groupFilter == GroupFilter(keys: ["g1", Self.ungrouped]))
  }

  @Test func aRepeatedAnswerDoesNotPublish() {
    let model = model(GroupFilter(keys: ["g1"]))
    var published = 0
    let subscription = model.objectWillChange.sink { published += 1 }
    defer { subscription.cancel() }

    model.applyGroups(Self.groups)

    #expect(published == 0)
  }

  /// sbd merges g1 into g2 by moving g1's sessions to g2 and then deleting g1. One refresh reads both changes.
  @Test func aMergeOfTheSelectedSessionsGroupKeepsItSelected() {
    let model = model(GroupFilter(keys: ["g1", "g2"]))
    model.selection = "i1"
    let merged = Self.list.map { $0.group == "g1" ? Self.inGroup($0, "g2") : $0 }

    model.apply(
      .success(merged), followups: Self.followups,
      groups: [Self.group("g2", "Web", ["i1", "i2", "w1", "w2"]), Self.groups[2]])

    #expect(model.selection == "i1")
    #expect(model.groupFilter == GroupFilter(keys: ["g2"]))
  }

  @Test func aDeleteOfTheSelectedSessionsGroupAddsUngrouped() {
    let model = model(GroupFilter(keys: ["g1", "g2"]))
    model.selection = "i1"
    let ungrouped = Self.list.map { s -> SessionSummary in
      var s = s
      if s.group == "g1" { s.group = nil }
      return s
    }

    model.apply(.success(ungrouped), followups: Self.followups, groups: [Self.groups[1], Self.groups[2]])

    #expect(model.selection == "i1")
    #expect(model.groupFilter == GroupFilter(keys: ["g2", Self.ungrouped]))
  }

  // MARK: Show All

  @Test func showAllClearsBothFiltersAndKeepsTheKnownGroups() {
    let model = model(GroupFilter(keys: ["g1"]), org: posthogOnly)

    model.showAll()

    #expect(model.filter.isAll)
    #expect(model.filter.knownGroups == Set(["g1", "g2", "g3"]))
    #expect(model.hiddenCount == 0)
  }

  // MARK: Reveal

  @Test func revealOfASessionInAHiddenGroupAddsItsGroup() {
    let model = model(GroupFilter(keys: ["g2"]))

    model.reveal("i1")

    #expect(model.groupFilter == GroupFilter(keys: ["g2", "g1"]))
    #expect(model.selection == "i1")
    #expect(model.sessions.contains { $0.id == "i1" })
  }

  @Test func revealOfAShownSessionLeavesTheGroupFilterAlone() {
    let model = model(GroupFilter(keys: ["g1"]))

    model.reveal("i1")

    #expect(model.groupFilter == GroupFilter(keys: ["g1"]))
    #expect(model.selection == "i1")
  }

  @Test func revealOfAnUngroupedSessionAddsUngrouped() {
    let model = model(GroupFilter(keys: ["g1"]))

    model.reveal("u1")

    #expect(model.groupFilter == GroupFilter(keys: ["g1", Self.ungrouped]))
    #expect(model.sessions.contains { $0.id == "u1" })
  }

  @Test func revealOfASessionWithAStaleGroupIdAddsUngrouped() {
    let model = model(GroupFilter(keys: ["g1"]), Self.list + [groupedSession("st", group: "gone")])

    model.reveal("st")

    #expect(model.groupFilter == GroupFilter(keys: ["g1", Self.ungrouped]))
    #expect(model.sessions.contains { $0.id == "st" })
  }

  @Test func revealOfAHiddenChatAddsItsGroup() {
    let model = model(GroupFilter(keys: ["g2"]))

    model.reveal("c1")

    #expect(model.groupFilter == GroupFilter(keys: ["g2", "g1"]))
    #expect(model.sessions.contains { $0.id == "c1" })
  }

  @Test func revealOfASessionHiddenByBothFiltersAddsBothKeys() {
    let model = model(GroupFilter(keys: ["g2"]), org: posthogOnly)

    model.reveal("i2")

    #expect(model.orgFilter == OrgFilter(keys: ["posthog", "haacked"]))
    #expect(model.groupFilter == GroupFilter(keys: ["g2", "g1"]))
    #expect(model.sessions.contains { $0.id == "i2" })
  }

  @Test func revealOfASessionHiddenOnlyByTheOrgFilterLeavesTheGroupFilterAlone() {
    let model = model(GroupFilter(keys: ["g1"]), org: posthogOnly)

    model.reveal("i2")

    #expect(model.orgFilter == OrgFilter(keys: ["posthog", "haacked"]))
    #expect(model.groupFilter == GroupFilter(keys: ["g1"]))
  }

  @Test func revealOfASessionHiddenOnlyByTheGroupFilterLeavesTheOrgFilterAlone() {
    let model = model(GroupFilter(keys: ["g2"]), org: posthogOnly)

    model.reveal("i1")

    #expect(model.orgFilter == posthogOnly)
    #expect(model.groupFilter == GroupFilter(keys: ["g2", "g1"]))
  }

  @Test func aPendingSelectionInAHiddenGroupAddsItsGroup() {
    let model = model(GroupFilter(keys: ["g1"]))
    model.selectUnlisted("new")

    model.apply(.success(Self.list + [groupedSession("new", group: "g2")]), followups: nil)

    #expect(model.groupFilter == GroupFilter(keys: ["g1", "g2"]))
    #expect(model.selection == "new")
    #expect(model.sessions.contains { $0.id == "new" })
  }

  @Test func aPendingUngroupedSelectionAddsUngrouped() {
    let model = model(GroupFilter(keys: ["g1"]))
    model.selectUnlisted("new")

    model.apply(.success(Self.list + [groupedSession("new", group: nil)]), followups: nil)

    #expect(model.groupFilter == GroupFilter(keys: ["g1", Self.ungrouped]))
    #expect(model.selection == "new")
  }

  @Test func aPendingSelectionThatTheGroupFilterShowsLeavesItAlone() {
    let model = model(GroupFilter(keys: ["g1"]))
    model.selectUnlisted("new")

    model.apply(.success(Self.list + [groupedSession("new", group: "g1")]), followups: nil)

    #expect(model.groupFilter == GroupFilter(keys: ["g1"]))
    #expect(model.selection == "new")
  }

  /// A publish redraws every view.
  @Test func aRefreshWithTheSameListUnderAGroupFilterWithASelectionDoesNotPublish() {
    let model = model(GroupFilter(keys: ["g1"]), org: posthogOnly)
    model.selection = "i1"
    var published = 0
    let subscription = model.objectWillChange.sink { published += 1 }
    defer { subscription.cancel() }

    model.apply(.success(Self.list), followups: Self.followups)

    #expect(published == 0)
  }

  // MARK: Actions that place a session in a group

  @Test func moveToGroupIntoAnUnselectedGroupAddsIt() {
    let model = answering(model(GroupFilter(keys: ["g1"])))

    let moved = model.moveToGroup("i1", "g2")

    #expect(moved)
    #expect(model.groupFilter == GroupFilter(keys: ["g1", "g2"]))
    #expect(model.sessions.contains { $0.id == "i1" })
  }

  @Test func moveToNoGroupUnderAGroupFilterAddsUngrouped() {
    let model = answering(model(GroupFilter(keys: ["g1"])))

    model.moveToGroup("i1", nil)

    #expect(model.groupFilter == GroupFilter(keys: ["g1", Self.ungrouped]))
    #expect(model.sessions.contains { $0.id == "i1" })
  }

  @Test func moveToGroupUnderAllGroupsLeavesTheFilterAll() {
    let model = answering(model(GroupFilter()))

    model.moveToGroup("i1", "g2")

    #expect(model.groupFilter.isAll)
  }

  static let created = group("g9", "New", [])

  @Test func createGroupAddsTheAnsweredGroupToANonAllFilter() async throws {
    let model = answering(model(GroupFilter(keys: ["g1"])), try JSON(encoding: Self.created))
    model.namingGroup = true

    model.createGroup("New")
    await settle { !model.namingGroup }

    #expect(model.groupFilter == GroupFilter(keys: ["g1", "g9"]))
  }

  @Test func createGroupUnderAllGroupsLeavesTheFilterAll() async throws {
    let model = answering(model(GroupFilter()), try JSON(encoding: Self.created))
    model.namingGroup = true

    model.createGroup("New")
    await settle { !model.namingGroup }

    #expect(model.groupFilter.isAll)
  }

  @Test func acceptingASuggestionAddsTheAnsweredGroup() async throws {
    let model = answering(model(GroupFilter(keys: ["g1"])), try JSON(encoding: Self.created))
    model.suggestions = [GroupSuggestion(id: "s1", name: "New", group: nil, sessions: ["i1"], reason: "")]

    model.acceptSuggestion("s1")
    await settle { model.groupFilter.keys.contains("g9") }

    #expect(model.groupFilter == GroupFilter(keys: ["g1", "g9"]))
  }

  @Test func shownSuggestionsDropASuggestionThatMovesASessionTheGroupFilterHides() {
    let model = model(GroupFilter(keys: ["g1"]))
    model.suggestions = [
      GroupSuggestion(id: "shown", name: "a", group: nil, sessions: ["i1", "i2"], reason: ""),
      GroupSuggestion(id: "mixed", name: "b", group: nil, sessions: ["i1", "w1"], reason: ""),
    ]

    #expect(model.shownSuggestions.map(\.id) == ["shown"])
  }

  // MARK: Board lanes

  func laneTitles(_ model: BoardModel) -> [String] { model.boardLayout(lanes: .group).lanes.map(\.title) }

  @Test(arguments: [
    (GroupFilter(), ["Infra", "Web", "Empty", "Ungrouped"]),
    (GroupFilter(keys: ["g1"]), ["Infra"]),
    (GroupFilter(keys: [GroupFilter.ungroupedKey]), ["Ungrouped"]),
    (GroupFilter(keys: ["g1", GroupFilter.ungroupedKey]), ["Infra", "Ungrouped"]),
    (GroupFilter(keys: ["g1", "g2"]), ["Infra", "Web"]),
  ])
  func theGroupFilterHidesWholeLanes(_ filter: GroupFilter, _ titles: [String]) {
    #expect(laneTitles(model(filter)) == titles)
  }

  @Test func aSelectedEmptyGroupKeepsItsLane() {
    let model = model(GroupFilter(keys: ["g3"]))

    #expect(model.shownGroups.map(\.id) == ["g3"])
    #expect(laneTitles(model) == ["Empty"])
  }

  @Test func aSelectedEmptyGroupKeepsItsLaneUnderAnOrgFilter() {
    let model = model(GroupFilter(keys: ["g3", "g1"]), org: OrgFilter(keys: ["haacked"]))

    #expect(model.shownGroups.map(\.id) == ["g1", "g3"])
  }

  @Test func shownGroupsKeepOnlySelectedGroups() {
    #expect(model(GroupFilter(keys: ["g1"])).shownGroups.map(\.id) == ["g1"])
    #expect(model(GroupFilter(keys: [Self.ungrouped])).shownGroups.isEmpty)
    #expect(model(GroupFilter()).shownGroups.map(\.id) == ["g1", "g2", "g3"])
  }

  /// The Board's Ungrouped lane under All Groups holds the work sessions that an Ungrouped-only filter shows.
  @Test func theUngroupedLaneHoldsWhatTheUngroupedFilterShows() {
    let list = Self.list + [groupedSession("st", group: "gone")]
    let all = model(GroupFilter(), list)
    let ungroupedOnly = model(GroupFilter(keys: [Self.ungrouped]), list)

    let lane = all.boardLayout(lanes: .group).lanes.first { $0.title == BoardRows.ungroupedTitle }
    let laneIds = Set(lane?.cells.flatMap { $0.map(\.id) } ?? [])

    #expect(laneIds == Set(ungroupedOnly.workBoard.map(\.id)))
    #expect(laneIds == ["u1", "f2", "st"])
  }

  @Test(arguments: everyGroupShape)
  func repoLanesHoldOnlyShownWorkSessions(_ shape: GroupShape) {
    let model = model(shape.filter)

    let ids = Set(model.boardLayout(lanes: .repo).lanes.flatMap { $0.cells.flatMap { $0.map(\.id) } })

    #expect(ids == Set(model.workBoard.map(\.id)))
  }

  // MARK: The popover counts

  func counts(_ entries: [FilterEntry]) -> [String: Int] {
    Dictionary(uniqueKeysWithValues: entries.map { ($0.key, $0.count) })
  }

  @Test func orgEntriesCountOnlyTheSessionsThatTheGroupFilterShows() {
    let model = model(GroupFilter(keys: ["g1"]))

    #expect(counts(model.orgEntries) == ["posthog": 2, "haacked": 1])
  }

  @Test func orgEntriesUnderAllGroupsAreTodaysCounts() {
    for org in [OrgFilter(), posthogOnly, OrgFilter(keys: ["acme"])] {
      let model = model(GroupFilter(), org: org)

      #expect(model.orgEntries == org.entries(model.listedBoard))
    }
    #expect(counts(model(GroupFilter()).orgEntries) == ["posthog": 5, "haacked": 2])
  }

  @Test func groupEntriesCountOnlyTheSessionsThatTheOrgFilterShows() {
    let model = model(GroupFilter(), org: posthogOnly)

    #expect(model.groupEntries.map(\.key) == ["g1", "g2", "g3", Self.ungrouped])
    #expect(model.groupEntries.map(\.count) == [3, 2, 0, 2])
  }

  @Test func groupEntriesUnderAllOrgsCountEveryGroupAndItsChat() {
    let model = model(GroupFilter())

    #expect(model.groupEntries.map(\.title) == ["Infra", "Web", "Empty", "Ungrouped"])
    #expect(model.groupEntries.map(\.count) == [4, 3, 0, 2])
    #expect(model.groupEntries.map(\.needsYou) == [2, 2, 0, 1])
  }

  @Test(arguments: everyGroupShape)
  func groupEntriesIgnoreTheGroupFilter(_ shape: GroupShape) {
    #expect(model(shape.filter).groupEntries == model(GroupFilter()).groupEntries)
  }

  @Test(arguments: [posthogOnly, OrgFilter(keys: ["haacked"]), OrgFilter(keys: [OrgFilter.localKey])])
  func orgEntriesIgnoreTheOrgFilter(_ org: OrgFilter) {
    let filtered = model(GroupFilter(keys: ["g1"]), org: org)
    let all = model(GroupFilter(keys: ["g1"]))

    #expect(counts(filtered.orgEntries).filter { $0.value > 0 } == counts(all.orgEntries).filter { $0.value > 0 })
  }

  // MARK: Notifications

  @Test func aSessionInAHiddenGroupThatStartsNeedingYouDoesNotNotify() {
    let before = [groupedSession("i1", group: "g1"), groupedSession("w1", group: "g2")]
    let model = model(GroupFilter(keys: ["g1"]), before, followups: nil)
    let next = [groupedSession("i1", group: "g1"), groupedSession("w1", group: "g2", state: .needsYou)]

    #expect(model.sessionsToNotify(next).isEmpty)
  }

  /// The refresh that lists a session in a new group also lists the group. The notification reads that list.
  @Test func aSessionThatMovesIntoAGroupThatThePollListsDoesNotNotifyUnderUngrouped() {
    let model = model(GroupFilter(keys: [Self.ungrouped]), [groupedSession("u1", group: nil)], followups: nil)
    let next = [groupedSession("u1", group: "g9", state: .needsYou)]
    let listed = Self.groups + [Self.group("g9", "New", ["u1"])]
    var notified: [String] = []
    model.notifier = { notified.append($0.id) }

    model.apply(.success(next), followups: nil, groups: listed)

    #expect(notified.isEmpty)
  }

  /// A merge moves the open session into an unselected group in the same refresh that it starts needing the
  /// user. The filter widens to keep it in sight, so it notifies.
  @Test func theOpenSessionNotifiesWhenAMergeMovesItIntoAnUnselectedGroup() {
    let model = model(GroupFilter(keys: ["g1", "g3"]), [groupedSession("i1", group: "g1")], followups: nil)
    model.selection = "i1"
    let next = [groupedSession("i1", group: "g2", state: .needsYou)]
    let listed = [Self.group("g2", "Web", ["i1"]), Self.groups[2]]
    var notified: [String] = []
    model.notifier = { notified.append($0.id) }

    model.apply(.success(next), followups: nil, groups: listed)

    #expect(notified == ["i1"])
    #expect(model.selection == "i1")
  }

  @Test func aSessionInAShownGroupThatStartsNeedingYouNotifies() {
    let before = [groupedSession("i1", group: "g1"), groupedSession("w1", group: "g2")]
    let model = model(GroupFilter(keys: ["g1"]), before, followups: nil)
    let next = [groupedSession("i1", group: "g1", state: .needsYou), groupedSession("w1", group: "g2")]

    #expect(model.sessionsToNotify(next).map(\.id) == ["i1"])
  }

  // MARK: The filters hide every work session

  @Test func filterHidesAllWorkWhenAnEmptyGroupIsSelected() {
    let model = model(GroupFilter(keys: ["g3"]))

    #expect(model.filterHidesAllWork)
    #expect(model.managers.map(\.id) == ["m"])
  }

  @Test func filterHidesAllWorkWhenTheTwoFiltersTogetherHideEverything() {
    let model = model(GroupFilter(keys: [Self.ungrouped]), org: OrgFilter(keys: ["haacked"]))

    #expect(model.workBoard.isEmpty)
    #expect(model.filterHidesAllWork)
  }

  @Test func filterHidesAllWorkUnderAnOrgFilterAlone() {
    #expect(model(GroupFilter(), org: OrgFilter(keys: ["acme"])).filterHidesAllWork)
  }

  @Test func filterHidesAllWorkIsFalseUnderAll() {
    #expect(!model(GroupFilter()).filterHidesAllWork)
  }

  @Test func filterHidesAllWorkIsFalseWhenSomeWorkShows() {
    #expect(!model(GroupFilter(keys: ["g1"])).filterHidesAllWork)
  }

  @Test func filterHidesAllWorkIsFalseWithNoWorkSessions() {
    let list = Self.list.filter { $0.kind != .work }

    #expect(!model(GroupFilter(keys: ["g3"]), list, followups: nil).filterHidesAllWork)
  }

  @Test func aFilterThatHidesEveryWorkSessionWithoutAManagerIsNotAnEmptySidebar() {
    let list = Self.list.filter { $0.kind == .work }
    let model = model(GroupFilter(keys: ["g3"]), list, followups: nil)

    #expect(model.filterHidesAllWork)
    #expect(!model.sidebarIsEmpty)
  }
}
