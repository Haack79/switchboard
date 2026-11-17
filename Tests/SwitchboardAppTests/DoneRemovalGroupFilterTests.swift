import AppKit
import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// Delete All queues only the sessions that both filters show, by a group that sbd has listed, at the moment of the
/// send.
@MainActor
@Suite struct DoneRemovalGroupFilterTests {
  static let ungrouped = GroupFilter.ungroupedKey

  /// Done sessions: PostHog in g1, PostHog in g2, PostHog in no group, haacked in g1, the chat of g2, PostHog in a
  /// group that sbd no longer lists, and a started follow-up in g2.
  nonisolated static let done: [SessionSummary] = {
    var followup = groupedSession("df", group: "g2", state: .done)
    followup.followup = Followup(prompt: "p")
    followup.followup?.started = 1
    return [
      groupedSession("d1", group: "g1", state: .done), groupedSession("d2", group: "g2", state: .done),
      groupedSession("du", group: nil, state: .done), groupedSession("dh", group: "g1", org: "haacked", state: .done),
      chatItem("dc", group: "g2", state: .done), groupedSession("ds", group: "gone", state: .done), followup,
    ]
  }()
  nonisolated static let ids = done.map(\.id)
  nonisolated static let groups = [
    GroupSummary(SessionGroup(id: "g1", name: "Infra", created: 0), sessions: ["d1", "dh"]),
    GroupSummary(SessionGroup(id: "g2", name: "Web", created: 0), sessions: ["d2", "df"]),
  ]

  /// A model that has applied `list` and, when `loaded`, sbd's answer to `group-ls`.
  func model(
    _ group: GroupFilter, org: OrgFilter = OrgFilter(), _ list: [SessionSummary] = done, loaded: Bool = true
  ) -> BoardModel {
    let model = orgFilterModel(org, groupFilter: group)
    model.apply(.success(list), followups: nil)
    if loaded { model.applyGroups(Self.groups) }
    return model
  }

  func plan(_ ids: [String]) -> RemovalPlan { RemovalPlan(remove: ids.map(removalItem), skip: []) }

  /// Confirms `plan` and returns the targets of every `rm-queue` that Delete N sent. When the guard should drop
  /// every id, it waits for the error that names the dropped ids instead of for a send.
  func confirm(_ model: BoardModel, _ plan: RemovalPlan, _ sent: SentRequests, expectSend: Bool) async -> [String] {
    model.doneRemoval = .confirming(plan, scope: .done)
    model.removeDone(plan)
    if expectSend {
      await settle { !sent.queues.isEmpty }
    } else {
      await settle { model.actionError != nil }
    }
    return sent.queues.flatMap { $0["targets"]?.array?.compactMap(\.string) ?? [] }
  }

  // MARK: What is removable

  struct GuardCase: Sendable, CustomTestStringConvertible {
    var org: [String]
    var group: [String]
    var removable: [String]
    var testDescription: String {
      "org \(org.isEmpty ? "All" : org.joined(separator: ",")) × group \(group.isEmpty ? "All" : group.joined(separator: ","))"
    }
  }

  nonisolated static let guardCases = [
    GuardCase(org: [], group: [], removable: ids),
    GuardCase(org: [], group: ["g1"], removable: ["d1", "dh"]),
    GuardCase(org: [], group: ["g2"], removable: ["d2", "dc", "df"]),
    GuardCase(org: [], group: [GroupFilter.ungroupedKey], removable: ["du", "ds"]),
    GuardCase(org: [], group: ["g1", GroupFilter.ungroupedKey], removable: ["d1", "du", "dh", "ds"]),
    GuardCase(org: ["posthog"], group: [], removable: ["d1", "d2", "du", "ds", "df"]),
    GuardCase(org: ["posthog"], group: ["g1"], removable: ["d1"]),
    // The chat has no org, so the org filter can't show that it is in the selection.
    GuardCase(org: ["posthog"], group: ["g2"], removable: ["d2", "df"]),
    GuardCase(org: ["haacked"], group: ["g2"], removable: []),
    GuardCase(org: ["haacked"], group: [GroupFilter.ungroupedKey], removable: []),
  ]

  @Test(arguments: guardCases)
  func removableIdsAreTheSessionsBothFiltersSurelyShow(_ c: GuardCase) {
    let model = model(GroupFilter(keys: c.group), org: OrgFilter(keys: c.org))

    #expect(model.removableIDs == Set(c.removable))
  }

  @Test(arguments: guardCases, [true, false])
  func removableIdsAreAlwaysShown(_ c: GuardCase, _ loaded: Bool) {
    let model = model(GroupFilter(keys: c.group), org: OrgFilter(keys: c.org), loaded: loaded)

    #expect(model.removableIDs.isSubset(of: model.shownIDs))
  }

  @Test(arguments: guardCases)
  func rmQueueNeverNamesASessionThatEitherFilterHides(_ c: GuardCase) async {
    let sent = SentRequests()
    let model = model(GroupFilter(keys: c.group), org: OrgFilter(keys: c.org))
    model.send = recordingSend(sent, plan: plan(Self.ids))

    let targets = await confirm(model, plan(Self.ids), sent, expectSend: !c.removable.isEmpty)

    #expect(targets == c.removable)
  }

  // MARK: Before sbd lists the groups

  @Test func aGroupFilterBeforeTheFirstGroupListMakesNothingRemovable() {
    let model = model(GroupFilter(keys: ["g1"]), loaded: false)

    #expect(model.shownIDs.contains("d1"))
    #expect(model.removableIDs.isEmpty)
  }

  @Test func aGroupFilterBeforeTheFirstGroupListQueuesNothing() async {
    let sent = SentRequests()
    let model = model(GroupFilter(keys: ["g1"]), loaded: false)
    model.send = recordingSend(sent, plan: plan(["d1", "dh"]))

    let targets = await confirm(model, plan(["d1", "dh"]), sent, expectSend: false)

    #expect(targets.isEmpty)
  }

  @Test func allGroupsBeforeTheFirstGroupListKeepsTodaysRule() {
    let model = model(GroupFilter(), loaded: false)

    #expect(model.removableIDs == Set(Self.ids))
  }

  // MARK: The plan

  @Test func aPlanShowsOnlyTheSessionsThatBothFiltersShow() async throws {
    let sent = SentRequests()
    let model = model(GroupFilter(keys: ["g1"]), org: posthogOnly)
    model.send = recordingSend(sent, plan: plan(["d1", "d2", "du", "dh"]))

    model.checkDoneRemoval()
    await settle { if case .confirming = model.doneRemoval { true } else { false } }

    guard case .confirming(let shown, _) = model.doneRemoval else {
      Issue.record("the check did not finish")
      return
    }
    #expect(shown.remove.map(\.id) == ["d1"])
  }

  // MARK: Changes between the plan and the confirm

  @Test func confirmingAfterAGroupFilterChangeThatHidesAPlannedIdNeverQueuesIt() async {
    let sent = SentRequests()
    let model = model(GroupFilter())
    model.send = recordingSend(sent, plan: plan(["d1", "d2", "du"]))

    model.groupFilter = GroupFilter(keys: ["g1"])
    let targets = await confirm(model, plan(["d1", "d2", "du"]), sent, expectSend: true)

    #expect(targets == ["d1"])
  }

  @Test func aSessionShownByTheOrgFilterAndHiddenByTheGroupFilterIsNeverSent() async {
    let sent = SentRequests()
    let model = model(GroupFilter(), org: posthogOnly)
    model.send = recordingSend(sent, plan: plan(["d1", "d2"]))

    model.groupFilter = GroupFilter(keys: ["g1"])
    let targets = await confirm(model, plan(["d1", "d2"]), sent, expectSend: true)

    #expect(model.orgFilter.shows(Self.done[1]))
    #expect(targets == ["d1"])
  }

  @Test func aSessionShownByTheGroupFilterAndHiddenByTheOrgFilterIsNeverSent() async {
    let sent = SentRequests()
    let model = model(GroupFilter(keys: ["g1"]))
    model.send = recordingSend(sent, plan: plan(["d1", "dh"]))

    model.orgFilter = posthogOnly
    let targets = await confirm(model, plan(["d1", "dh"]), sent, expectSend: true)

    #expect(targets == ["d1"])
  }

  @Test func aGroupDeletedWhileTheSheetIsOpenDropsItsSessions() async {
    let sent = SentRequests()
    let model = model(GroupFilter(keys: ["g1", "g2"]))
    model.send = recordingSend(sent, plan: plan(["d1", "d2"]))

    model.applyGroups([Self.groups[0]])
    let targets = await confirm(model, plan(["d1", "d2"]), sent, expectSend: true)

    #expect(targets == ["d1"])
  }

  @Test func aSessionMovedIntoAHiddenGroupWhileTheSheetIsOpenIsNeverSent() async {
    let sent = SentRequests()
    let model = model(GroupFilter(keys: ["g1"]))
    model.send = recordingSend(sent, plan: plan(["d1", "dh"]))

    let moved = Self.done.map { $0.id == "d1" ? groupedSession("d1", group: "g2", state: .done) : $0 }
    model.apply(.success(moved), followups: nil)
    let targets = await confirm(model, plan(["d1", "dh"]), sent, expectSend: true)

    #expect(targets == ["dh"])
  }

  @Test func ungroupedSelectedNeverSendsAGroupedSession() async {
    let sent = SentRequests()
    let model = model(GroupFilter(keys: [Self.ungrouped]))
    model.send = recordingSend(sent, plan: plan(["d1", "du", "dh", "ds"]))

    let targets = await confirm(model, plan(["d1", "du", "dh", "ds"]), sent, expectSend: true)

    #expect(targets == ["du", "ds"])
  }
}
