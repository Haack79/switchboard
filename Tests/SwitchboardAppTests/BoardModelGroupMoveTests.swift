import AppKit
import SwitchboardCore
import Testing

@testable import SwitchboardApp

@MainActor
@Suite struct BoardModelGroupMove {
  func work(_ id: String, group: String?, name: String? = nil, state: AttentionState = .working) -> SessionSummary {
    var s = needsItem(id, state: state)
    s.name = name ?? id
    s.group = group
    return s
  }

  /// Three groups, one of them empty. `charlie` names a group that sbd removed.
  /// `zulu` is the session that a refusal test moves after the refused drop.
  /// `echo` is a follow-up that waits to start, so only `followup-ls` lists it.
  func model() -> BoardModel {
    let model = appliedModel(
      [
        work("alpha", group: "grp-flags"),
        work("bravo", group: nil),
        work("charlie", group: "gone"),
        work("delta", group: "grp-billing", name: "Checkout"),
        work("zulu", group: nil),
        needsItem("manager", manager: true, state: .working),
        chatItem("chat-flags", group: "grp-flags", state: .working),
      ],
      followups: [work("echo", group: nil, state: .notStarted)])
    model.groups = [
      GroupSummary(SessionGroup(id: "grp-flags", name: "Flags", created: 0), sessions: ["alpha"]),
      GroupSummary(SessionGroup(id: "grp-billing", name: "Billing", created: 0), sessions: ["delta"]),
      GroupSummary(SessionGroup(id: "grp-empty", name: "Empty", created: 0), sessions: []),
    ]
    return model
  }

  /// The group of the session's card, which can come from `sessions` or `followups`.
  func group(_ model: BoardModel, _ id: String) -> String?? {
    model.board.first { $0.id == id }.map(\.group)
  }

  /// Runs `action` with a `send` that records requests, and returns the first
  /// request. It returns nil without waiting when `action` returns false,
  /// because then `action` claims that it sent nothing.
  func firstSent(_ model: BoardModel, _ action: () -> Bool) async -> (op: String, args: [String: JSON])? {
    let resumed = Counter()
    return await withCheckedContinuation { (first: CheckedContinuation<(op: String, args: [String: JSON])?, Never>) in
      model.send = { op, args in
        if resumed.increment() == 1 { first.resume(returning: (op, args)) }
        return .null
      }
      if !action(), resumed.increment() == 1 { first.resume(returning: nil) }
    }
  }

  /// Drops `session` on `target`. It returns the request, the card's group
  /// right after the call, and whether every other card kept its group. A
  /// refresh after sbd answers can replace the sessions, so the groups are
  /// read before the test awaits.
  func drop(_ model: BoardModel, _ session: String, on target: String?) async
    -> (request: (op: String, args: [String: JSON])?, shown: String??, othersKept: Bool)
  {
    let others = { model.board.filter { $0.id != session }.map(\.group) }
    let before = others()
    var shown: String??
    var othersKept = false
    let request = await firstSent(model) {
      let moved = model.moveToGroup([session], target)
      shown = group(model, session)
      othersKept = others() == before
      return moved
    }
    return (request, shown, othersKept)
  }

  @Test(
    arguments: [
      ("bravo", "grp-flags"),
      // From one group to another.
      ("delta", "grp-flags"),
      // A group with no sessions.
      ("alpha", "grp-empty"),
      // A session whose group sbd removed sits in the Ungrouped lane.
      ("charlie", "grp-flags"),
      // sbd keeps a follow-up that waits to start as a session, so `group-move` finds it.
      ("echo", "grp-flags"),
    ])
  func dropOnAnotherGroupSendsTheMoveAndMovesTheCard(session: String, target: String) async {
    let (request, shown, othersKept) = await drop(model(), session, on: target)

    #expect(request?.op == "group-move")
    #expect(request?.args == ["sessions": [.string(session)], "group": .string(target)])
    #expect(shown == .some(target))
    #expect(othersKept)
  }

  @Test func dropOnUngroupedSendsUngroupedAndMovesTheCard() async {
    let (request, shown, othersKept) = await drop(model(), "alpha", on: nil)

    #expect(request?.op == "group-move")
    #expect(request?.args == ["sessions": ["alpha"], "ungrouped": true])
    #expect(shown == .some(nil))
    #expect(othersKept)
  }

  /// The drop is refused: it returns false, the card stays, and the first
  /// request sbd gets is the `zulu` move that follows it. Requests go out one
  /// at a time in order, so a request from the refused drop would come first.
  @Test(
    arguments: [
      // The session's own lane.
      ("alpha", "grp-flags"),
      ("bravo", nil),
      // A group that is not in `groups` counts as Ungrouped.
      ("charlie", nil),
      // Not a work session on the Board. The drop text can come from another
      // app, and sbd finds a session by id, unique id prefix, or name.
      ("manager", "grp-flags"),
      ("manager", nil),
      ("chat-flags", "grp-billing"),
      ("chat-flags", nil),
      ("https://example.com", "grp-flags"),
      ("", "grp-flags"),
      ("Checkout", "grp-flags"),
      ("delt", "grp-flags"),
      ("delt", nil),
      // A group that sbd didn't list. sbd finds a group by id, unique id prefix, or name.
      ("bravo", "gone"),
      ("bravo", "Flags"),
      ("bravo", "grp-f"),
      ("bravo", ""),
    ] as [(String, String?)])
  func refusedDropSendsNothingAndLeavesTheCard(session: String, target: String?) async {
    let model = model()
    let before = group(model, session)
    var moved = true
    var after: String??

    let first = await firstSent(model) {
      moved = model.moveToGroup([session], target)
      after = group(model, session)
      return model.moveToGroup(["zulu"], "grp-flags")
    }

    #expect(!moved)
    #expect(after == before)
    #expect(first?.args == ["sessions": ["zulu"], "group": "grp-flags"])
  }

  // MARK: Several ids

  /// Runs `action` with a `send` that records requests and returns what `action` returned with every request it
  /// sent. A `group-account` request follows `action`. Requests reach sbd one at a time in order, so the
  /// requests before it are exactly the ones that `action` sent.
  func requests(_ model: BoardModel, _ action: () -> Bool) async
    -> (moved: Bool, sent: [(op: String, args: [String: JSON])])
  {
    let sent = SentRequests()
    model.send = { op, args in
      sent.append(op, args)
      return .null
    }
    let moved = action()
    model.setGroupAccount("grp-empty", nil)
    await sent.wait(for: "group-account")
    return (moved, Array(sent.value.prefix { $0.op != "group-account" }))
  }

  /// The `group-move` arguments that move `sessions` to `group`, or to Ungrouped when `group` is nil.
  static func moveArgs(_ sessions: [String], _ group: String?) -> [String: JSON] {
    var args: [String: JSON] = ["sessions": .array(sessions.map { .string($0) })]
    if let group { args["group"] = .string(group) } else { args["ungrouped"] = true }
    return args
  }

  struct Move: Sendable, CustomTestStringConvertible {
    var ids: [String]
    var group: String?
    /// The ids that the request names, in the order of `ids`.
    var moves: [String]
    var testDescription: String { "\(ids) to \(group ?? "Ungrouped")" }
  }

  nonisolated static let moves = [
    Move(ids: ["bravo", "zulu", "echo"], group: "grp-flags", moves: ["bravo", "zulu", "echo"]),
    // The card already in the lane, a group chat, the Manager, text that names no session, an empty line, and a
    // session's name stay. The follow-up moves.
    Move(
      ids: ["alpha", "bravo", "chat-flags", "manager", "echo", "https://example.com", "", "Checkout", "delt"],
      group: "grp-flags", moves: ["bravo", "echo"]),
    // A payload can repeat an id.
    Move(ids: ["bravo", "zulu", "bravo"], group: "grp-billing", moves: ["bravo", "zulu"]),
    // To Ungrouped, an ungrouped card and a card whose group sbd removed stay.
    Move(ids: ["alpha", "bravo", "charlie"], group: nil, moves: ["alpha"]),
    Move(ids: ["alpha", "delta"], group: nil, moves: ["alpha", "delta"]),
  ]

  @Test(arguments: moves)
  func aMoveOfSeveralIDsSendsOneRequestWithTheMovableIDs(_ move: Move) async {
    let model = model()

    let result = await requests(model) { model.moveToGroup(move.ids, move.group) }

    #expect(result.moved)
    #expect(result.sent.map(\.op) == ["group-move"])
    #expect(result.sent.first?.args == Self.moveArgs(move.moves, move.group))
  }

  /// Only the moved cards change lanes before sbd answers.
  @Test(arguments: moves)
  func aMoveOfSeveralIDsShowsOnlyTheMovableCardsInTheNewLane(_ move: Move) async {
    let model = model()
    let before = Dictionary(uniqueKeysWithValues: model.board.map { ($0.id, $0.group) })
    var after: [String: String?] = [:]

    _ = await requests(model) {
      let moved = model.moveToGroup(move.ids, move.group)
      after = Dictionary(uniqueKeysWithValues: model.board.map { ($0.id, $0.group) })
      return moved
    }

    let expected = before.merging(move.moves.map { ($0, move.group) }) { _, new in new }
    #expect(after == expected)
  }

  /// `moveToGroup` sends these ids. The Move menu's `laneGroups` check must agree with them.
  @Test(arguments: moves)
  func movableIDsListsTheIDsThatTheMoveSends(_ move: Move) {
    #expect(model().movableIDs(move.ids, to: move.group) == move.moves)
  }

  @Test(
    arguments: [
      // Every id is filtered out.
      (["alpha", "chat-flags", "manager", "", "delt", "Checkout"], "grp-flags"),
      (["bravo", "zulu", "charlie"], nil),
      // A group that sbd didn't list.
      (["bravo", "zulu"], "gone"),
      (["bravo", "zulu"], "Flags"),
      (["bravo", "zulu"], "grp-f"),
      (["bravo", "zulu"], ""),
      // Nothing to move.
      ([], "grp-flags"),
      ([], nil),
    ] as [([String], String?)])
  func aMoveWithNothingMovableReturnsFalseAndSendsNothing(ids: [String], target: String?) async {
    let model = model()
    let before = model.board.map(\.group)
    var after: [String?] = []

    let result = await requests(model) {
      let moved = model.moveToGroup(ids, target)
      after = model.board.map(\.group)
      return moved
    }

    #expect(!result.moved)
    #expect(result.sent.isEmpty)
    #expect(after == before)
  }

  // MARK: Dragging a Board selection

  /// The model with the Board showing `selection`, and the grid that BoardView draws from the group lanes.
  func board(selecting selection: Set<String>) -> BoardModel {
    let model = model()
    model.show(.board)
    model.boardGrid = model.boardLayout(lanes: .group).grid
    model.multiSelection = selection
    return model
  }

  /// What `LaneDrop` does with the strings that a drop delivers: one move with the ids of every payload.
  func dropOnLane(_ model: BoardModel, _ payloads: [String], _ group: String?) -> Bool {
    model.dropBoardCards(payloads, on: group)
  }

  /// What the Move menu of card `id` does.
  func moveFromMenu(_ model: BoardModel, _ id: String, _ group: String?) -> Bool {
    model.moveToGroup(model.boardActionIDs(for: id), group)
  }

  @Test func aDragOfTwoSelectedCardsSendsOneMoveWithBoth() async throws {
    let model = board(selecting: ["bravo", "zulu"])
    let payload = BoardDrag.payload(model.boardActionIDs(for: "bravo"))

    let result = await requests(model) { dropOnLane(model, [payload], "grp-flags") }

    #expect(result.sent.map(\.op) == ["group-move"])
    let sent = result.sent.first?.args["sessions"]?.array?.compactMap(\.string)
    let sessions = try #require(sent)
    #expect(Set(sessions) == ["bravo", "zulu"])
    #expect(sessions.count == 2)
  }

  /// Another app's drag can carry any text. None of these lines is the id of a work session on the Board.
  @Test func aDropOfAnotherAppsTextMovesNothing() async {
    let model = board(selecting: [])
    let payloads = ["https://example.com\nhello world\n\nCheckout\n", "delt\r\nmanager", ""]

    let result = await requests(model) { dropOnLane(model, payloads, "grp-flags") }

    #expect(!result.moved)
    #expect(result.sent.isEmpty)
  }

  @Test(
    arguments: [
      (["bravo", "zulu"], "bravo", "grp-flags"),
      // A card outside the selection moves alone.
      (["bravo", "zulu"], "delta", "grp-flags"),
      // A selection with a card already in the target lane.
      (["alpha", "bravo", "delta"], "delta", "grp-flags"),
      (["alpha", "bravo", "delta"], "alpha", nil),
    ] as [(Set<String>, String, String?)])
  func theMoveMenuAndALaneDropSendTheSameRequest(selection: Set<String>, card: String, target: String?) async throws {
    let menuModel = board(selecting: selection)
    let dropModel = board(selecting: selection)
    let payload = BoardDrag.payload(dropModel.boardActionIDs(for: card))

    let menu = await requests(menuModel) { moveFromMenu(menuModel, card, target) }
    let drop = await requests(dropModel) { dropOnLane(dropModel, [payload], target) }

    try #require(!menu.sent.isEmpty)
    #expect(drop.sent.map(\.op) == menu.sent.map(\.op))
    #expect(drop.sent.map(\.args) == menu.sent.map(\.args))
  }
}
