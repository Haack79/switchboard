import AppKit
import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// A move of one session to another account from the app: the dry run, the
/// confirmation when the move stops claude or moves a Manager session, the
/// move, and the refusals that reach the error banner. sbd gets `stop: true`
/// with `dryRun` false only after the user confirms a Stop and Move.
@MainActor
@Suite struct BoardModelAccountMoveTests {
  nonisolated static let work = "/Users/me/.claude-work"
  nonisolated static let personal = "/Users/me/.claude-personal"

  nonisolated static let accounts = [
    AccountInfo(name: "work", folder: work, active: true, sessions: 1),
    AccountInfo(name: "personal", folder: personal, active: false, sessions: 1),
  ]

  static let running = "its claude is running. Stop it first"

  /// A work session on `personal`.
  func session(_ id: String = "a", live: Bool = false) -> SessionSummary {
    var s = SessionSummary(
      id: id, name: id, cwd: "/tmp/\(id)", repo: nil, branch: nil, claudeSessionId: id, state: .waiting, reason: "",
      since: 0, lastActivity: 0, live: live, claudePid: live ? 4242 : nil, attached: false, lastReply: nil, waits: [],
      notes: [])
    s.account = Self.personal
    return s
  }

  func conversation(_ id: String = "m", mcp: [String]? = []) -> SessionSummary {
    var s = session(id)
    s.cwd = "/Users/me/.switchboard/manager"
    s.kind = .manager
    s.manager = true
    s.mcp = mcp
    return s
  }

  func chat(_ id: String = "chat") -> SessionSummary {
    var s = session(id)
    s.kind = .chat
    s.chat = "g1"
    return s
  }

  func model(_ sessions: [SessionSummary]) -> BoardModel {
    let model = appliedModel(sessions)
    model.accounts = Self.accounts
    model.groups = [GroupSummary(SessionGroup(id: "g1", name: "Flags", created: 0), sessions: sessions.map(\.id))]
    return model
  }

  /// Replaces `send` with a recorder. sbd answers the dry run with `plan`,
  /// or refuses it with `refusal`, and answers the move with `result`, or
  /// with every planned session moved when `result` is nil.
  func record(
    _ model: BoardModel, plan: AccountMove, result: AccountMove? = nil, refusal: String? = nil
  ) -> SentRequests {
    let sent = SentRequests()
    model.send = { op, args in
      sent.append(op, args)
      guard args["dryRun"] == .bool(true) else {
        return try JSON(encoding: result ?? AccountMove(account: plan.account, moved: plan.moved))
      }
      if let refusal { throw Refusal(description: refusal) }
      return try JSON(encoding: plan)
    }
    return sent
  }

  func moved(_ id: String, mcpDropped: [String: [String]]? = nil) -> AccountMove {
    AccountMove(account: Self.work, moved: [id], blocked: [], mcpDropped: mcpDropped)
  }

  func blocked(_ id: String, _ reason: String) -> AccountMove {
    AccountMove(account: Self.work, blocked: [.init(session: id, name: id, reason: reason)])
  }

  /// The arguments of the app's dry run for one session.
  func dryRun(_ id: String) -> [String: JSON] {
    ["account": .string(Self.work), "sessions": [.string(id)], "stop": true, "dryRun": true]
  }

  /// Waits a moment for a request that should not come.
  func pause() async { try? await Task.sleep(nanoseconds: 200_000_000) }

  // MARK: An idle work session

  @Test func anIdleWorkSessionDryRunsThenMovesWithoutStop() async {
    let model = model([session()])
    let sent = record(model, plan: moved("a"))

    model.requestAccountMove("a", to: Self.work)
    await settle { sent.value.count >= 2 }

    #expect(sent.ops == ["account-move", "account-move"])
    #expect(sent.value.first?.args == dryRun("a"))
    #expect(sent.value.last?.args == ["account": .string(Self.work), "sessions": ["a"]])
  }

  @Test func anIdleWorkSessionAsksNothing() async {
    let model = model([session()])
    let sent = record(model, plan: moved("a"))

    model.requestAccountMove("a", to: Self.work)
    await settle { sent.value.count >= 2 }

    #expect(model.confirmingAccountMove == nil)
  }

  // MARK: A running session

  @Test func aRunningSessionAsksBeforeItStopsClaude() async {
    let model = model([session(live: true)])
    let sent = record(model, plan: moved("a"))

    model.requestAccountMove("a", to: Self.work)
    await settle { model.confirmingAccountMove != nil }
    await pause()

    #expect(model.confirmingAccountMove?.title == "Stop a and move it to work?")
    #expect(model.confirmingAccountMove?.stop == true)
    #expect(sent.value.map(\.args) == [dryRun("a")])
  }

  @Test func confirmingARunningSessionSendsStop() async throws {
    let model = model([session(live: true)])
    let sent = record(model, plan: moved("a"))
    model.requestAccountMove("a", to: Self.work)
    await settle { model.confirmingAccountMove != nil }
    let move = try #require(model.confirmingAccountMove)

    model.confirmAccountMove(move)
    await settle { sent.value.count >= 2 }

    #expect(sent.value.last?.args == ["account": .string(Self.work), "sessions": ["a"], "stop": true])
  }

  /// The dialog's Cancel clears the confirmation.
  @Test func cancellingARunningSessionsMoveSendsNothing() async {
    let model = model([session(live: true)])
    let sent = record(model, plan: moved("a"))
    model.requestAccountMove("a", to: Self.work)
    await settle { model.confirmingAccountMove != nil }

    model.confirmingAccountMove = nil
    await pause()

    #expect(sent.value.map(\.args) == [dryRun("a")])
  }

  // MARK: Refusals

  @Test func aGroupRefusalInTheDryRunReachesTheBannerAndMovesNothing() async {
    let reason =
      "its group Flags runs its sessions under the account personal. Move it out of the group, or change the group's account with sb group account"
    let model = model([session()])
    let sent = record(model, plan: blocked("a", reason))

    model.requestAccountMove("a", to: Self.work)
    await settle { model.actionError != nil }
    await pause()

    #expect(model.actionError?.contains(reason) == true, "\(model.actionError ?? "nil")")
    #expect(sent.value.map(\.args) == [dryRun("a")])
    #expect(model.confirmingAccountMove == nil)
  }

  /// `account-move` with `sessions` answers success with `blocked` filled.
  @Test func aMoveAnsweredWithBlockedReachesTheBanner() async {
    let model = model([session()])
    _ = record(model, plan: moved("a"), result: blocked("a", Self.running))

    model.requestAccountMove("a", to: Self.work)
    await settle { model.actionError != nil }

    #expect(model.actionError?.contains(Self.running) == true, "\(model.actionError ?? "nil")")
  }

  /// A signed-out target or an unknown account makes sbd throw. The error
  /// must reach the banner, not vanish the way `planMove`'s `try?` drops it.
  @Test func aDryRunThatSbdRefusesReachesTheBannerAndMovesNothing() async {
    let refusal = "max is not signed in. Run CLAUDE_CONFIG_DIR=/Users/me/.claude-max claude /login"
    let model = model([session()])
    let sent = record(model, plan: moved("a"), refusal: refusal)

    model.requestAccountMove("a", to: Self.work)
    await settle { model.actionError != nil }
    await pause()

    #expect(model.actionError?.contains(refusal) == true, "\(model.actionError ?? "nil")")
    #expect(sent.value.count == 1)
  }

  // MARK: A Manager conversation

  @Test func anIdleManagerConversationAsksAndNamesTheDroppedServer() async {
    let model = model([conversation(mcp: ["grafana", "notes"])])
    let sent = record(model, plan: moved("m", mcpDropped: ["m": ["notes"]]))

    model.requestAccountMove("m", to: Self.work)
    await settle { model.confirmingAccountMove != nil }
    await pause()

    let message = model.confirmingAccountMove?.message ?? ""
    #expect(message.contains("work has no MCP server named notes, so m starts without them."), "\(message)")
    #expect(model.confirmingAccountMove?.stop == false)
    #expect(sent.value.count == 1)
  }

  @Test func confirmingAnIdleManagerConversationSendsNoStop() async throws {
    let model = model([conversation()])
    let sent = record(model, plan: moved("m"))
    model.requestAccountMove("m", to: Self.work)
    await settle { model.confirmingAccountMove != nil }
    let move = try #require(model.confirmingAccountMove)

    model.confirmAccountMove(move)
    await settle { sent.value.count >= 2 }

    #expect(sent.value.last?.args == ["account": .string(Self.work), "sessions": ["m"]])
  }

  // MARK: Show the group on the Board

  /// Only group lanes show a lane's group account menu.
  @Test func showGroupOnBoardShowsTheBoardInGroupLanesAndFocusesTheSession() {
    let s = session()
    let model = model([s])
    UserDefaults.standard.set(BoardLanes.repo.rawValue, forKey: BoardLanes.storageKey)

    model.showGroupOnBoard(s)

    #expect(model.mainView == .board)
    #expect(model.boardFocus == "a")
    #expect(UserDefaults.standard.string(forKey: BoardLanes.storageKey) == BoardLanes.group.rawValue)
  }

  /// A chat has no card on the Board.
  @Test func showGroupOnBoardForAChatOnlyShowsTheBoard() {
    let groupChat = chat()
    let model = model([session(), groupChat])

    model.showGroupOnBoard(groupChat)

    #expect(model.mainView == .board)
    #expect(model.boardFocus == nil)
  }

  // MARK: Guard: no stop without the user's Stop and Move

  /// Each path on which the user never pressed Stop and Move.
  enum IdlePath: CaseIterable {
    case idleWork
    case idleManagerConfirmed
    /// The session was idle at the click, and its claude started before the
    /// move. sbd's dry run with `stop` lists it, and the move without `stop` is refused.
    case staleIdle
    case runningCancelled
  }

  func requests(_ path: IdlePath) async throws -> SentRequests {
    switch path {
    case .idleWork:
      let model = model([session()])
      let sent = record(model, plan: moved("a"))
      model.requestAccountMove("a", to: Self.work)
      await settle { sent.value.count >= 2 }
      return sent
    case .idleManagerConfirmed:
      let model = model([conversation()])
      let sent = record(model, plan: moved("m"))
      model.requestAccountMove("m", to: Self.work)
      await settle { model.confirmingAccountMove != nil }
      model.confirmAccountMove(try #require(model.confirmingAccountMove))
      await settle { sent.value.count >= 2 }
      return sent
    case .staleIdle:
      let model = model([session(live: false)])
      let sent = record(model, plan: moved("a"), result: blocked("a", Self.running))
      model.requestAccountMove("a", to: Self.work)
      await settle { model.actionError != nil }
      #expect(model.actionError?.contains(Self.running) == true)
      return sent
    case .runningCancelled:
      let model = model([session(live: true)])
      let sent = record(model, plan: moved("a"))
      model.requestAccountMove("a", to: Self.work)
      await settle { model.confirmingAccountMove != nil }
      model.confirmingAccountMove = nil
      await pause()
      return sent
    }
  }

  @Test(arguments: IdlePath.allCases) func noRequestStopsClaudeWithoutConfirmation(_ path: IdlePath) async throws {
    let sent = try await requests(path)

    #expect(!sent.value.isEmpty)
    for request in sent.value {
      #expect(request.args["stop"] != .bool(true) || request.args["dryRun"] == .bool(true), "\(request.args)")
    }
  }
}
