import AppKit
import SwitchboardCore
import Testing
import os

@testable import SwitchboardApp

@Suite struct DoneRemovalTextTests {
  func item(worktree: String? = nil, branch: String? = nil, remoteBranch: Bool = false) -> RemovalPlan.Item {
    RemovalPlan.Item(
      id: "s1", name: "one", pr: 7, worktree: worktree, branch: branch, remoteBranch: remoteBranch)
  }

  // MARK: deletes

  @Test func deletesOnlyTheSessionWithoutAWorktree() {
    #expect(DoneRemovalText.deletes(item()) == "session")
  }

  @Test func deletesTheSessionAndWorktreeWithoutABranch() {
    #expect(DoneRemovalText.deletes(item(worktree: "/wt/one")) == "session and worktree")
  }

  @Test func deletesTheBranchOfAMergedPR() {
    #expect(DoneRemovalText.deletes(item(worktree: "/wt/one", branch: "feat")) == "session, worktree, and branch")
  }

  @Test func deletesTheRemoteBranchWhenAsked() {
    let text = DoneRemovalText.deletes(item(worktree: "/wt/one", branch: "feat", remoteBranch: true))

    #expect(text == "session, worktree, branch, and remote branch")
  }

  // MARK: scope

  @Test(arguments: [
    (0, RemovalScope.done, "No Done session can be deleted"), (1, .done, "Delete 1 Done session?"),
    (2, .done, "Delete 2 Done sessions?"), (0, .work, "No session can be deleted"), (1, .work, "Delete 1 session?"),
    (2, .work, "Delete 2 sessions?"),
  ])
  func theTitleNamesDoneSessionsOnlyInTheDoneScope(_ count: Int, _ scope: RemovalScope, _ expected: String) {
    let plan = RemovalPlan(remove: Array(repeating: item(), count: count), skip: [])

    #expect(DoneRemovalText.title(plan, scope: scope) == expected)
  }

  @Test func theWorkScopeChecksAndKeepsSessionsWithoutNamingDone() {
    #expect(DoneRemovalText.checking(.done) == "Checking the Done sessions…")
    #expect(DoneRemovalText.checking(.work) == "Checking the sessions…")
    #expect(DoneRemovalText.stays(.done) == "Stays in Done")
    #expect(DoneRemovalText.stays(.work) == "Stays")
  }
}

/// The app decodes what sbd's `rm-done` sends.
@Suite struct DoneRemovalPlanDecoding {
  @Test func decodesARemovalWithCamelCaseRemoteBranch() throws {
    let text = #"""
      {"remove":[{"id":"s1","name":"one","pr":122953,"worktree":"/wt/one","branch":"feat","remoteBranch":true}],
       "skip":[]}
      """#

    let plan = try JSONCoding.decode(RemovalPlan.self, from: text)

    #expect(
      plan.remove == [
        RemovalPlan.Item(
          id: "s1", name: "one", pr: 122953, worktree: "/wt/one", branch: "feat", remoteBranch: true)
      ])
  }

  @Test func decodesNullPRWorktreeAndBranch() throws {
    let text = #"""
      {"remove":[{"id":"s1","name":"one","pr":null,"worktree":null,"branch":null,"remoteBranch":false}],"skip":[]}
      """#

    let plan = try JSONCoding.decode(RemovalPlan.self, from: text)

    #expect(
      plan.remove == [
        RemovalPlan.Item(id: "s1", name: "one", pr: nil, worktree: nil, branch: nil, remoteBranch: false)
      ])
  }

  @Test func decodesASkipWithItsReason() throws {
    let text = #"{"remove":[],"skip":[{"id":"s2","name":"two","reason":"has uncommitted files"}]}"#

    let plan = try JSONCoding.decode(RemovalPlan.self, from: text)

    #expect(plan.skip == [RemovalPlan.Skip(id: "s2", name: "two", reason: "has uncommitted files")])
  }

  @Test func encodesRemoteBranchInCamelCase() throws {
    let plan = RemovalPlan(
      remove: [RemovalPlan.Item(id: "s1", name: "one", pr: nil, worktree: nil, branch: nil, remoteBranch: true)],
      skip: [])

    let json = try JSON(encoding: plan)

    #expect(json["remove"]?.array?.first?["remoteBranch"] == .bool(true))
  }
}

final class SentRequests: Sendable {
  private let sent = OSAllocatedUnfairLock<[(op: String, args: [String: JSON])]>(initialState: [])
  var value: [(op: String, args: [String: JSON])] { sent.withLock { $0 } }
  var ops: [String] { value.map(\.op) }
  func append(_ op: String, _ args: [String: JSON]) { sent.withLock { $0.append((op, args)) } }
  /// The `rm-queue` requests, in the order they were sent.
  var queues: [[String: JSON]] { value.filter { $0.op == "rm-queue" }.map(\.args) }
}

/// A reply to `rm-queue` that queues every target.
func queuedEveryTarget(_ args: [String: JSON]) throws -> JSON {
  try JSON(encoding: RemovalQueued(queued: args["targets"]?.array?.compactMap(\.string) ?? [], skipped: []))
}

func removalItem(_ id: String) -> RemovalPlan.Item {
  .init(id: id, name: id, pr: nil, worktree: nil, branch: nil, remoteBranch: false)
}

/// Delete N in the Delete All sheet hands every planned session to sbd's removal job in one request and
/// closes the sheet at once.
@MainActor
@Suite struct BoardModelDoneRemoval {
  static let plan = RemovalPlan(
    remove: ["a", "b", "c"].map(removalItem), skip: [.init(id: "d", name: "d", reason: "has uncommitted files")])

  func confirmingModel(_ sent: SentRequests) -> BoardModel {
    let model = appliedModel(["a", "b", "c", "d"].map { needsItem($0, state: .done) })
    model.send = { op, args in
      sent.append(op, args)
      return op == "rm-queue" ? try queuedEveryTarget(args) : .null
    }
    model.doneRemoval = .confirming(Self.plan, scope: .done)
    return model
  }

  @Test func deleteNSendsOneRmQueueWithEveryPlannedID() async {
    let sent = SentRequests()
    let model = confirmingModel(sent)

    model.removeDone(Self.plan)
    await settle { !sent.queues.isEmpty }

    #expect(sent.queues.count == 1)
    #expect(sent.queues.first?["targets"]?.array?.compactMap(\.string) == ["a", "b", "c"])
  }

  @Test func deleteNSendsNothingButTheRmQueue() async {
    let sent = SentRequests()
    let model = confirmingModel(sent)

    model.removeDone(Self.plan)
    await settle { !sent.queues.isEmpty }

    #expect(!sent.ops.contains("rm-done"))
    #expect(!sent.ops.contains("rm"))
  }

  @Test func deleteNQueuesWithDeleteAllsScopeAndArguments() async throws {
    let sent = SentRequests()
    let model = confirmingModel(sent)

    model.removeDone(Self.plan)
    await settle { !sent.queues.isEmpty }

    let args = try #require(sent.queues.first)
    #expect(args["scope"] == .string("done"))
    #expect(args["worktree"] == .bool(true))
    #expect(args["remote_branch"] == .bool(true))
    #expect(args["confirmed"] == nil)
  }

  @Test func deleteNClosesTheSheetAtOnce() {
    let model = confirmingModel(SentRequests())

    model.removeDone(Self.plan)

    #expect(model.doneRemoval == nil)
    #expect(!model.showingDoneRemoval)
    #expect(!model.presentingSheet)
  }

  @Test func aRefusedRmQueueShowsTheBanner() async {
    let model = appliedModel(["a", "b", "c", "d"].map { needsItem($0, state: .done) })
    model.send = { op, _ in
      if op == "rm-queue" { throw Refusal(description: "the socket closed") }
      return .null
    }
    model.doneRemoval = .confirming(Self.plan, scope: .done)

    model.removeDone(Self.plan)
    await settle { model.actionError != nil }

    #expect(model.actionError?.contains("the socket closed") == true)
    #expect(!model.showingDoneRemoval)
  }
}

/// Delete All's `rm-queue` runs off `worker`. The Done delete icon's `rm-queue` runs on `worker`, in order with
/// the other actions.
@MainActor
@Suite struct DoneRemovalQueues {
  @Test func deleteNIsSentWhileWorkerIsBusy() async {
    let sent = SentRequests()
    let model = appliedModel([needsItem("d", state: .done)])
    let gate = DispatchSemaphore(value: 0)
    model.send = { op, args in
      if op == "hold" { gate.wait() }
      sent.append(op, args)
      return op == "rm-queue" ? try queuedEveryTarget(args) : .null
    }
    model.perform("hold", [:])
    let plan = RemovalPlan(remove: [removalItem("d")], skip: [])
    model.doneRemoval = .confirming(plan, scope: .done)

    model.removeDone(plan)
    await settle { !sent.queues.isEmpty }
    let sentWhileHeld = sent.queues.count

    gate.signal()
    #expect(sentWhileHeld == 1)
  }

  @Test func theIconsDeleteSendsRmQueueForTheOneSession() async throws {
    let sent = SentRequests()
    let done = needsItem("d", state: .done)
    let model = appliedModel([needsItem("e", state: .done), done])
    model.send = { op, args in
      sent.append(op, args)
      return op == "rm-queue" ? try queuedEveryTarget(args) : .null
    }

    model.deleteDone(done)
    await settle { !sent.queues.isEmpty }

    let args = try #require(sent.queues.first)
    #expect(sent.queues.count == 1)
    #expect(args["targets"]?.array?.compactMap(\.string) == ["d"])
    #expect(args["scope"] == .string("done"))
  }

  @Test func theIconsDeleteSendsNoRm() async {
    let sent = SentRequests()
    let done = needsItem("d", state: .done)
    let model = appliedModel([done])
    model.send = { op, args in
      sent.append(op, args)
      return op == "rm-queue" ? try queuedEveryTarget(args) : .null
    }

    model.deleteDone(done)
    await settle { !sent.queues.isEmpty }

    #expect(!sent.ops.contains("rm"))
  }

  /// The confirmation lists the open to-dos that the delete resolves, and `rm-queue` checks them as `rm` does.
  @Test func theIconsDeletePassesTheToDosItResolves() async throws {
    let sent = SentRequests()
    let done = needsItem("d", state: .done)
    let model = appliedModel([done])
    model.send = { op, args in
      sent.append(op, args)
      return op == "rm-queue" ? try queuedEveryTarget(args) : .null
    }

    model.deleteDone(done, resolve: ["t1", "t2"])
    await settle { !sent.queues.isEmpty }

    let args = try #require(sent.queues.first)
    #expect(args["resolve"]?.array?.compactMap(\.string) == ["t1", "t2"])
  }

  @Test func theIconsDeleteRunsInOrderWithTheOtherActions() async {
    let sent = SentRequests()
    let done = needsItem("d", state: .done)
    let model = appliedModel([done])
    model.send = { op, args in
      sent.append(op, args)
      return op == "rm-queue" ? try queuedEveryTarget(args) : .null
    }

    model.perform("before", [:])
    model.deleteDone(done)
    model.perform("after", [:])
    await settle { sent.value.count >= 3 }

    #expect(Array(sent.ops.prefix(3)) == ["before", "rm-queue", "after"])
  }

  @Test func anIconDeleteThatSbdSkipsShowsTheReasonAndKeepsTheSelection() async throws {
    let sent = SentRequests()
    let done = needsItem("d", state: .done)
    let model = appliedModel([done])
    model.send = { op, args in
      sent.append(op, args)
      guard op == "rm-queue" else { return .null }
      return try JSON(
        encoding: RemovalQueued(queued: [], skipped: [.init(id: "d", name: "d", reason: "has uncommitted files")]))
    }
    model.selection = "d"

    model.deleteDone(done)
    await settle { model.actionError != nil }

    #expect(!sent.queues.isEmpty)
    #expect(model.actionError?.contains("has uncommitted files") == true)
    #expect(model.selection == "d")
  }

  @Test func aRefusedIconDeleteShowsTheBannerAndKeepsTheSelection() async {
    let sent = SentRequests()
    let done = needsItem("d", state: .done)
    let model = appliedModel([done])
    model.send = { op, args in
      sent.append(op, args)
      if op == "rm-queue" { throw Refusal(description: "sbd is busy") }
      return .null
    }
    model.selection = "d"

    model.deleteDone(done)
    await settle { model.actionError != nil }

    #expect(!sent.queues.isEmpty)
    #expect(model.actionError?.contains("sbd is busy") == true)
    #expect(model.selection == "d")
  }
}

/// Delete All queues only the sessions that the org filter shows at the moment of the send.
@MainActor
@Suite struct DoneRemovalOrgFilterTests {
  nonisolated static let done = [
    orgSession("ph", "PostHog/posthog", state: .done), orgSession("hk", "haacked/switchboard", state: .done),
    orgSession("lo", nil, state: .done), orgSession("un", nil, read: nil, state: .done),
  ]

  func item(_ id: String) -> RemovalPlan.Item { removalItem(id) }

  func skip(_ id: String) -> RemovalPlan.Skip { .init(id: id, name: id, reason: "has uncommitted files") }

  func model(_ filter: OrgFilter, _ list: [SessionSummary] = done) -> BoardModel {
    let model = orgFilterModel(filter)
    model.apply(.success(list), followups: nil)
    return model
  }

  /// A `send` that records every request, queues every target of `rm-queue`, and answers anything else with `plan`.
  func recordingSend(_ sent: SentRequests, plan: RemovalPlan) -> @Sendable (String, [String: JSON]) throws -> JSON {
    { op, args in
      sent.append(op, args)
      return op == "rm-queue" ? try queuedEveryTarget(args) : try JSON(encoding: plan)
    }
  }

  /// Confirms `plan` and returns the targets of every `rm-queue` that Delete N sent.
  func confirm(_ model: BoardModel, _ plan: RemovalPlan, _ sent: SentRequests) async -> [String] {
    model.doneRemoval = .confirming(plan, scope: .done)
    model.removeDone(plan)
    await settle { !sent.queues.isEmpty }
    return sent.queues.flatMap { $0["targets"]?.array?.compactMap(\.string) ?? [] }
  }

  // MARK: The plan

  @Test func aPlanShowsOnlyTheSessionsThatTheFilterShows() async throws {
    let sent = SentRequests()
    let model = model(OrgFilter(keys: ["posthog"]))
    let plan = RemovalPlan(remove: [item("ph"), item("hk"), item("un")], skip: [skip("lo"), skip("ph2")])
    model.send = recordingSend(sent, plan: plan)

    model.checkDoneRemoval()
    await settle { if case .confirming = model.doneRemoval { true } else { false } }

    guard case .confirming(let shown, _) = model.doneRemoval else {
      Issue.record("the check did not finish")
      return
    }
    // The unread session shows under the filter, but its org may be hidden, so Delete All skips it.
    #expect(shown.remove.map(\.id) == ["ph"])
    #expect(shown.skip.map(\.id) == ["un"])
    #expect(shown.skip.first?.reason == BoardModel.unreadOrgReason)
  }

  @Test func aFilteredPlanKeepsSbdsSkipsForShownSessions() async throws {
    let sent = SentRequests()
    let model = model(OrgFilter(keys: ["posthog"]))
    let plan = RemovalPlan(remove: [], skip: [skip("ph"), skip("un"), skip("hk")])
    model.send = recordingSend(sent, plan: plan)

    model.checkDoneRemoval()
    await settle { if case .confirming = model.doneRemoval { true } else { false } }

    guard case .confirming(let shown, _) = model.doneRemoval else {
      Issue.record("the check did not finish")
      return
    }
    #expect(shown.remove.isEmpty)
    #expect(shown.skip.map(\.id) == ["ph", "un"])
    #expect(shown.skip.allSatisfy { $0.reason == "has uncommitted files" })
  }

  @Test func aPlanDropsAnIdThatTheBoardDoesNotList() async throws {
    let sent = SentRequests()
    let model = model(OrgFilter())
    let plan = RemovalPlan(remove: [item("ph"), item("ghost")], skip: [skip("phantom"), skip("lo")])
    model.send = recordingSend(sent, plan: plan)

    model.checkDoneRemoval()
    await settle { if case .confirming = model.doneRemoval { true } else { false } }

    guard case .confirming(let shown, _) = model.doneRemoval else {
      Issue.record("the check did not finish")
      return
    }
    #expect(shown.remove.map(\.id) == ["ph"])
    #expect(shown.skip.map(\.id) == ["lo"])
  }

  // MARK: The sends

  @Test func confirmingAfterAFilterChangeThatHidesAPlannedIdNeverQueuesIt() async throws {
    let sent = SentRequests()
    let model = model(OrgFilter())
    let plan = RemovalPlan(remove: [item("ph"), item("hk"), item("lo")], skip: [])
    model.send = recordingSend(sent, plan: plan)

    model.orgFilter = OrgFilter(keys: ["posthog"])
    let targets = await confirm(model, plan, sent)

    #expect(targets == ["ph"])
  }

  @Test func aSessionWhoseOrgBecomesKnownAndHiddenWhileTheSheetIsOpenIsNeverQueued() async throws {
    let sent = SentRequests()
    let model = model(OrgFilter(keys: ["posthog"]))
    let plan = RemovalPlan(remove: [item("ph"), item("un")], skip: [])
    model.send = recordingSend(sent, plan: plan)

    model.apply(
      .success([
        orgSession("ph", "PostHog/posthog", state: .done), orgSession("un", "haacked/late", state: .done),
      ]), followups: nil)
    let targets = await confirm(model, plan, sent)

    #expect(targets == ["ph"])
  }

  @Test func aSessionWhoseOrgIsUnknownIsNeverQueuedUnderAFilter() async throws {
    let sent = SentRequests()
    let model = model(OrgFilter(keys: ["posthog"]))
    let plan = RemovalPlan(remove: [item("ph"), item("un")], skip: [])
    model.send = recordingSend(sent, plan: plan)

    let targets = await confirm(model, plan, sent)

    #expect(model.shownIDs.contains("un"))
    #expect(targets == ["ph"])
  }

  @Test func anIdThatTheBoardDoesNotListIsNeverQueued() async throws {
    let sent = SentRequests()
    let model = model(OrgFilter())
    let plan = RemovalPlan(remove: [item("ghost"), item("ph")], skip: [])
    model.send = recordingSend(sent, plan: plan)

    let targets = await confirm(model, plan, sent)

    #expect(targets == ["ph"])
  }

  @Test func underAllOrgsOneRmQueueTakesEveryPlannedSession() async throws {
    let sent = SentRequests()
    let model = model(OrgFilter())
    let plan = RemovalPlan(remove: Self.done.map { item($0.id) }, skip: [])
    model.send = recordingSend(sent, plan: plan)

    model.checkDoneRemoval()
    await settle { if case .confirming = model.doneRemoval { true } else { false } }
    guard case .confirming(let shown, _) = model.doneRemoval else {
      Issue.record("the check did not finish")
      return
    }
    #expect(shown == plan)
    let targets = await confirm(model, shown, sent)

    #expect(sent.value.first?.args == BoardModel.doneRemovalArgs)
    #expect(sent.queues.count == 1)
    #expect(targets == ["ph", "hk", "lo", "un"])
  }
}
