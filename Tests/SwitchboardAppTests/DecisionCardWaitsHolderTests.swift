import Foundation
import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// An Operator-held wait that is overdue shows as an item on the session that it is about (#410, Decision 38). The
/// waits stay on the Operator, so the item's `details.waitsHolder` names the Operator, and the card's `WaitPanel`
/// reads and clears the waits there.
@MainActor
@Suite struct DecisionCardWaitsHolder {
  static let hour: Int64 = 3_600_000
  static let now: Int64 = 100 * hour

  /// The Operator, holding a merge wait on `k1` that is past its recheck time.
  static func theOperator() -> SessionSummary {
    var s = needsItem("op", manager: true, state: .waiting)
    s.kind = .operator
    s.name = Manager.operatorName
    var wait = Wait(
      id: "w1", kind: .session, session: Wait.SessionTarget(id: "k1", name: "k1"), state: .readyToMerge, by: .claude,
      created: now - 3 * hour, recheck: now - hour)
    wait.action = WaitAction(kind: .merge)
    s.waits = [wait]
    return s
  }

  /// The held-wait item that sbd routes to `k1`, with the holder that sbd names, or none.
  static func heldItem(holder: String?) -> TriageItem {
    var details = TriageDetails(overdueWaits: ["w1"])
    details.waitsHolder = holder
    return TriageItem(
      title: "sbd still waits to merge", kind: .question, summary: "", source: .report, ref: "held:w1",
      details: details)
  }

  /// A model under an org filter and a group filter, which list `k1` and the Operator.
  static func filteredModel() -> BoardModel {
    var owner = groupedSession("k1", group: "g1")
    owner.triage = heldItem(holder: "op")
    let model = orgFilterModel(posthogOnly, groupFilter: GroupFilter(keys: ["g1"]))
    model.apply(.success([owner, theOperator()]), followups: nil)
    return model
  }

  @Test func withAHolderThePanelReadsTheHoldersSession() throws {
    let model = Self.filteredModel()
    let owner = try #require(model.allSessions.first { $0.id == "k1" })

    let resolved = DecisionCard.waitPanelSession(Self.heldItem(holder: "op"), on: owner, sessions: model.allSessions)

    #expect(resolved?.id == "op")
  }

  /// The owner holds none of the waits, so a panel on the owner would show no row.
  @Test func theHoldersSessionGivesThePanelItsOverdueWait() throws {
    let model = Self.filteredModel()
    let owner = try #require(model.allSessions.first { $0.id == "k1" })
    let item = Self.heldItem(holder: "op")
    let resolved = try #require(DecisionCard.waitPanelSession(item, on: owner, sessions: model.allSessions))

    let rows = WaitPanel.rows(
      session: resolved, ids: item.details.overdueWaits, sessions: model.allSessions, reference: { _ in nil },
      now: Self.now)

    #expect(rows.map(\.id) == ["w1"])
  }

  @Test func withoutAHolderThePanelReadsTheItemsOwnSession() throws {
    var owner = needsItem("a")
    owner.waits = [
      Wait(id: "w1", kind: .ci, created: Self.now - 3 * Self.hour, recheck: Self.now - Self.hour)
    ]
    let model = appliedModel([owner, Self.theOperator()])

    let resolved = DecisionCard.waitPanelSession(Self.heldItem(holder: nil), on: owner, sessions: model.allSessions)

    #expect(resolved?.id == "a")
  }
}
