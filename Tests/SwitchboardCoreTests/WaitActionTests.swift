import Foundation
import Testing

@testable import SwitchboardCore

/// Wait actions (#410, Stage 1): `then` takes `merge`, `rm-worktree`, `rm`, and `report`. `makeWait` stores the
/// action in `Wait.action` with `then: .resume`, and refuses every shape that Decision 5 does not allow.
@Suite struct WaitActionTests {
  /// One `then` value that arms an action, and the action that it stores.
  struct Action: Sendable, CustomTestStringConvertible {
    let then: String
    let kind: WaitAction.Kind
    /// Text that the refusal of a shape that the action does not take must hold, because it names the allowed shape.
    let hints: [String]
    var testDescription: String { then }
  }

  static let merge = Action(then: "merge", kind: .merge, hints: ["ready_to_merge"])
  static let rmWorktree = Action(then: "rm-worktree", kind: .rmWorktree, hints: ["done", "merge"])
  static let rm = Action(then: "rm", kind: .rm, hints: ["done"])
  static let report = Action(then: "report", kind: .report, hints: ["manual"])
  static let actions = [merge, rmWorktree, rm, report]

  /// A request for a wait of `kind` that arms the action, with a note, so that `report` has its text.
  /// `state` applies to a session wait only, and nil leaves the default, done.
  static func request(
    _ action: Action, _ kind: Wait.Kind, state: AttentionState? = nil, target: String? = nil,
    note: String? = "tell the user"
  ) -> WaitRequest {
    var r = minimalRequest(kind)
    r.then = action.then
    if kind == .session { r.state = state?.rawValue }
    if let target { r.target = target }
    r.note = note
    return r
  }

  /// Decision 5, written out: whether `action` may go on a wait of `kind`. `state` is the session wait's state
  /// after the default. `target` says whether the request names a PR.
  static func allowed(_ action: WaitAction.Kind, _ kind: Wait.Kind, _ state: AttentionState, target: Bool) -> Bool {
    switch action {
    case .merge: kind == .session && state == .readyToMerge
    case .rmWorktree: (kind == .session && state == .done) || (kind == .merge && target)
    case .rm: kind == .session && state == .done
    case .report: kind != .manual
    }
  }
}

// MARK: Which waits take which action (Decision 5)

extension WaitActionTests {
  /// A session wait that arms an action, with the state that the request gives, or nil for the default.
  struct SessionShape: Sendable, CustomTestStringConvertible {
    let action: Action
    let state: AttentionState?
    var testDescription: String { "\(action.then) on --state \(state?.rawValue ?? "(default)")" }
    var allowed: Bool { WaitActionTests.allowed(action.kind, .session, state ?? .done, target: true) }
  }

  /// A wait of another kind that arms an action, with or without a PR target.
  struct KindShape: Sendable, CustomTestStringConvertible {
    let action: Action
    let kind: Wait.Kind
    let target: String?
    var testDescription: String { "\(action.then) on --kind \(kind.rawValue)\(target.map { " --target \($0)" } ?? "")" }
    var allowed: Bool { WaitActionTests.allowed(action.kind, kind, .done, target: target != nil) }
  }

  static let sessionShapes = actions.flatMap { a in
    (([nil] as [AttentionState?]) + AttentionState.allCases.map { Optional($0) }).map {
      SessionShape(action: a, state: $0)
    }
  }
  static let kindShapes = actions.flatMap { a in
    Wait.Kind.allCases.filter { $0 != .session }.flatMap { kind -> [KindShape] in
      let targets: [String?] = prKinds.contains(kind) ? [nil, "PostHog/posthog#1204"] : [nil]
      return targets.map { KindShape(action: a, kind: kind, target: $0) }
    }
  }

  @Suite struct Shapes {
    @Test(arguments: WaitActionTests.sessionShapes.filter(\.allowed))
    func aSessionWaitInTheActionsStateStoresTheAction(_ shape: SessionShape) throws {
      let wait = try buildWait(WaitActionTests.request(shape.action, .session, state: shape.state))

      #expect(wait.action?.kind == shape.action.kind)
    }

    @Test(arguments: WaitActionTests.sessionShapes.filter { !$0.allowed })
    func aSessionWaitInAnotherStateIsRefused(_ shape: SessionShape) {
      #expect(throws: APIError.self) {
        try buildWait(WaitActionTests.request(shape.action, .session, state: shape.state))
      }
    }

    @Test(arguments: WaitActionTests.kindShapes.filter(\.allowed))
    func aWaitOfAKindThatTheActionTakesStoresTheAction(_ shape: KindShape) throws {
      let wait = try buildWait(WaitActionTests.request(shape.action, shape.kind, target: shape.target))

      #expect(wait.action?.kind == shape.action.kind)
    }

    @Test(arguments: WaitActionTests.kindShapes.filter { !$0.allowed })
    func aWaitOfAKindThatTheActionDoesNotTakeIsRefused(_ shape: KindShape) {
      #expect(throws: APIError.self) {
        try buildWait(WaitActionTests.request(shape.action, shape.kind, target: shape.target))
      }
    }

    /// The refusal names the shape that the action takes.
    @Test(arguments: WaitActionTests.sessionShapes.filter { !$0.allowed })
    func theRefusalNamesTheAllowedShape(_ shape: SessionShape) throws {
      let error = #expect(throws: APIError.self) {
        try buildWait(WaitActionTests.request(shape.action, .session, state: shape.state))
      }

      let text = try #require(error).description
      for hint in shape.action.hints { #expect(text.contains(hint), "\(text)") }
    }

    @Test(arguments: WaitActionTests.kindShapes.filter { !$0.allowed })
    func theRefusalOfAnotherKindNamesTheAllowedShape(_ shape: KindShape) throws {
      let error = #expect(throws: APIError.self) {
        try buildWait(WaitActionTests.request(shape.action, shape.kind, target: shape.target))
      }

      let text = try #require(error).description
      for hint in shape.action.hints { #expect(text.contains(hint), "\(text)") }
    }

    /// Decision 3: the stored `then` stays resume, so an older sbd and `applyWait` still decode it.
    @Test(arguments: WaitActionTests.sessionShapes.filter(\.allowed))
    func anActionWaitOnASessionResumes(_ shape: SessionShape) throws {
      let wait = try buildWait(WaitActionTests.request(shape.action, .session, state: shape.state))

      #expect(wait.then == .resume)
    }

    @Test(arguments: WaitActionTests.kindShapes.filter(\.allowed))
    func anActionWaitOfAnotherKindResumes(_ shape: KindShape) throws {
      let wait = try buildWait(WaitActionTests.request(shape.action, shape.kind, target: shape.target))

      #expect(wait.then == .resume)
    }

    /// A request with no kind is a manual wait, which takes no action.
    @Test(arguments: WaitActionTests.actions)
    func aRequestWithNoKindIsRefused(_ action: Action) {
      let r = WaitRequest(note: "tell the user", then: action.then)

      #expect(throws: APIError.self) { try buildWait(r) }
    }

    /// The subject of a merge wait is the session with that open PR, which only `setWait` can find. `makeWait`
    /// keeps the PR and leaves the subject for it.
    @Test func rmWorktreeOnAMergeWaitKeepsThePRAndLeavesTheSubjectUnset() throws {
      let wait = try buildWait(
        WaitActionTests.request(WaitActionTests.rmWorktree, .merge, target: "PostHog/posthog#1204"))

      #expect(wait.pr == posthog1204)
      #expect(wait.subject == nil)
    }

    @Test func aMergeActionKeepsTheTargetSession() throws {
      let wait = try buildWait(WaitActionTests.request(WaitActionTests.merge, .session, state: .readyToMerge))

      #expect(wait.session == flagCache)
    }

    /// Decision 3: the stored enum keeps exactly its three values.
    @Test(arguments: ["merge", "rm-worktree", "rm", "report"])
    func theStoredThenHasNoActionValue(_ then: String) {
      #expect(Wait.Then(rawValue: then) == nil)
    }

    @Test func theActionKindsAreTheThenValues() {
      #expect(WaitAction.Kind.allCases.map(\.rawValue) == ["merge", "rm-worktree", "rm", "report"])
    }

    /// The error for an unknown `then` lists every value that it takes.
    @Test(arguments: ["later", "caller-ish", "merge-now"])
    func anUnknownThenListsEveryValue(_ then: String) throws {
      let error = #expect(throws: APIError.self) { try buildWait(WaitRequest(kind: "ci", then: then)) }

      let text = try #require(error).description
      for value in ["resume", "notify", "merge", "rm-worktree", "rm", "report"] {
        #expect(text.contains(value), "\(text)")
      }
    }

    /// One action per wait: `then` holds one value.
    @Test(arguments: ["merge,rm-worktree", "merge rm", "report|rm"])
    func twoActionsInOneThenAreRefused(_ then: String) {
      #expect(throws: APIError.self) {
        try buildWait(WaitRequest(kind: "session", target: "flag-cache", state: "done", note: "x", then: then))
      }
    }
  }
}

// MARK: report and needsYou (Decision 4)

extension WaitActionTests {
  @Suite struct Report {
    /// The report's text is the note, so report needs one.
    @Test(arguments: [nil, "", "  \n\t "] as [String?])
    func reportWithoutANoteIsRefused(_ note: String?) {
      #expect(throws: APIError.self) {
        try buildWait(WaitActionTests.request(WaitActionTests.report, .session, state: .done, note: note))
      }
    }

    @Test func reportKeepsTheTrimmedNoteAsItsText() throws {
      let wait = try buildWait(
        WaitActionTests.request(WaitActionTests.report, .date, note: "  tell the user to run bin/update \n"))

      #expect(wait.note == "tell the user to run bin/update")
    }

    @Test func reportWithNeedsYouStoresTheFlag() throws {
      var r = WaitActionTests.request(WaitActionTests.report, .session, state: .done)
      r.needsYou = true

      let wait = try buildWait(r)

      #expect(wait.action?.needsYou == true)
    }

    @Test func reportWithoutNeedsYouIsAnInfoReport() throws {
      let wait = try buildWait(WaitActionTests.request(WaitActionTests.report, .session, state: .done))

      #expect(wait.action?.needsYou != true)
    }

    @Test(arguments: [WaitActionTests.merge, WaitActionTests.rmWorktree, WaitActionTests.rm])
    func needsYouOnAnotherActionIsRefused(_ action: Action) {
      let state: AttentionState = action.kind == .merge ? .readyToMerge : .done
      var r = WaitActionTests.request(action, .session, state: state)
      r.needsYou = true

      #expect(throws: APIError.self) { try buildWait(r) }
    }

    /// needsYou belongs to a report, so a wait with no action refuses it too.
    @Test(arguments: [nil, "resume", "notify"] as [String?])
    func needsYouOnAWaitWithNoActionIsRefused(_ then: String?) {
      var r = WaitRequest(kind: "session", target: "flag-cache", state: "done", note: "x", then: then)
      r.needsYou = true

      #expect(throws: APIError.self) { try buildWait(r) }
    }
  }
}

// MARK: handsOff for action waits (Decision 7)

extension WaitActionTests {
  /// A request for an action wait that a conversation sends, by `by`.
  static func conversationRequest(_ action: Action, by: Author) -> WaitRequest {
    let state: AttentionState = action.kind == .merge ? .readyToMerge : .done
    var r = request(action, .session, state: state)
    r.by = by.rawValue
    return r
  }

  @Suite struct Handoff {
    @Test(arguments: WaitActionTests.actions, [Author.claude, .you])
    func anActionWaitFromAConversationHandsOff(_ action: Action, _ by: Author) throws {
      #expect(try handsOffRequest(WaitActionTests.conversationRequest(action, by: by)))
    }

    @Test(arguments: WaitActionTests.actions, [Author.claude, .you])
    func hereKeepsAnActionWaitOnTheConversation(_ action: Action, _ by: Author) throws {
      #expect(try !handsOffRequest(WaitActionTests.conversationRequest(action, by: by), here: true))
    }

    @Test(arguments: WaitActionTests.actions, [SessionKind.work, .chat, .operator])
    func anActionWaitNamedOnASessionThatIsNotAConversationStays(_ action: Action, _ kind: SessionKind) throws {
      #expect(try !handsOffRequest(WaitActionTests.conversationRequest(action, by: .claude), named: kindSession(kind)))
    }

    /// A merge wait on a PR with its repository reads nothing of the conversation.
    @Test(arguments: [Author.claude, .you])
    func rmWorktreeOnAQualifiedMergeWaitHandsOff(_ by: Author) throws {
      var r = WaitActionTests.request(WaitActionTests.rmWorktree, .merge, target: "PostHog/posthog#1204")
      r.by = by.rawValue

      #expect(try handsOffRequest(r))
    }

    @Test func aDateReportFromAConversationHandsOff() throws {
      var r = WaitActionTests.request(WaitActionTests.report, .date)
      r.by = Author.you.rawValue

      #expect(try handsOffRequest(r))
    }

    /// A wait with no action that the user sets on a conversation still stays, as before Stage 1.
    @Test func aPlainWaitThatTheUserSetStillStays() throws {
      var r = byClaude(.session)
      r.by = Author.you.rawValue

      #expect(try !handsOffRequest(r))
    }
  }
}

// MARK: Stored rows and the wire (Hard to reverse 3)

extension WaitActionTests {
  static func storedWait(action: WaitAction?, status: ActionStatus? = nil, subject: Wait.SessionTarget? = nil) -> Wait {
    var w = Wait(
      id: "w3", kind: .session, session: flagCache, state: .readyToMerge, note: "merge per the rule", by: .claude,
      created: 1_700_000_000_000, then: .resume, recheck: 1_700_086_400_000)
    w.handedFrom = cacheFix
    w.action = action
    w.actionStatus = status
    w.subject = subject
    return w
  }

  static func roundTrip(_ wait: Wait) throws -> Wait {
    try JSONCoding.decode(Wait.self, from: try JSONCoding.encode(wait))
  }

  static let storedActions: [WaitAction] = [
    WaitAction(kind: .merge), WaitAction(kind: .rmWorktree), WaitAction(kind: .rm), WaitAction(kind: .report),
    WaitAction(kind: .report, needsYou: true),
  ]

  @Suite struct Wire {
    @Test(arguments: WaitActionTests.storedActions)
    func anActionRoundTripsThroughJSON(_ action: WaitAction) throws {
      let wait = WaitActionTests.storedWait(action: action)

      #expect(try WaitActionTests.roundTrip(wait) == wait)
    }

    @Test(arguments: ActionStatus.allCases)
    func eachActionStatusRoundTripsThroughJSON(_ status: ActionStatus) throws {
      let wait = WaitActionTests.storedWait(action: WaitAction(kind: .merge), status: status)

      #expect(try WaitActionTests.roundTrip(wait).actionStatus == status)
    }

    @Test func aSubjectRoundTripsThroughJSON() throws {
      var wait = WaitActionTests.storedWait(action: WaitAction(kind: .rmWorktree), subject: flagCache)
      wait.kind = .merge
      wait.session = nil
      wait.state = nil
      wait.pr = posthog1204

      #expect(try WaitActionTests.roundTrip(wait) == wait)
    }

    /// The JSON names that `sb get --json`, `sb wait --json`, and the `wait` event carry.
    @Test(
      arguments: zip(["merge", "rm-worktree", "rm", "report"], [WaitAction.Kind.merge, .rmWorktree, .rm, .report]))
    func theActionEncodesItsKindAsTheThenValue(_ name: String, _ kind: WaitAction.Kind) throws {
      let json = try JSON(encoding: WaitActionTests.storedWait(action: WaitAction(kind: kind)))

      #expect(json["action"]?["kind"]?.string == name, "\(json.text)")
    }

    @Test func theSubjectEncodesAsIdAndName() throws {
      let json = try JSON(
        encoding: WaitActionTests.storedWait(action: WaitAction(kind: .rmWorktree), subject: flagCache))

      #expect(json["subject"]?["id"]?.string == "k3x9p", "\(json.text)")
      #expect(json["subject"]?["name"]?.string == "flag-cache", "\(json.text)")
    }

    /// A wait with no action writes none of the new keys, so the row and the events stay as an older sbd wrote them.
    @Test func aWaitWithNoActionWritesNoNewKey() throws {
      let json = try JSON(encoding: WaitActionTests.storedWait(action: nil))

      let keys = Set(json.object?.keys.map { $0 } ?? [])
      #expect(keys.isDisjoint(with: ["action", "actionStatus", "subject"]), "\(json.text)")
    }

    /// A row that an sbd from before Stage 1 stored.
    @Test func aStoredRowWithoutAnActionDecodesUnchanged() throws {
      let row = #"""
        {"id":"w3","kind":"session","session":{"id":"k3x9p","name":"flag-cache"},"state":"ready_to_merge",
         "note":"merge per the rule","by":"claude","created":1700000000000,"then":"resume","recheck":1700086400000,
         "handedFrom":{"id":"c1","name":"Plan the cache fix"}}
        """#

      let wait = try JSONCoding.decode(Wait.self, from: row)

      #expect(wait == WaitActionTests.storedWait(action: nil))
    }

    @Test func aStoredRowWithoutAnActionHasNoActionStatusOrSubject() throws {
      let row = #"{"id":"w1","kind":"ci","by":"you","created":0,"then":"resume"}"#

      let wait = try JSONCoding.decode(Wait.self, from: row)

      #expect(wait.action == nil)
      #expect(wait.actionStatus == nil)
      #expect(wait.subject == nil)
    }

    /// A session row that holds an action wait decodes with the action, so `sb get --json` and the app read it.
    @Test func aSessionWithAnActionWaitRoundTrips() throws {
      var s = kindSession(.operator)
      s.waits = [WaitActionTests.storedWait(action: WaitAction(kind: .merge), status: ActionStatus.allCases.first)]

      let decoded = try JSONCoding.decode(Session.self, from: try JSONCoding.encode(s))

      #expect(decoded.waits == s.waits)
    }
  }
}

// MARK: OperatorSettings (Home.swift Config, key operator)

extension WaitActionTests {
  @Suite struct Settings {
    @Test func configWithoutOperatorMergesNowhere() throws {
      let c = try JSONCoding.decode(Config.self, from: "{}")

      #expect(c.`operator`.mergeRepos.isEmpty)
    }

    @Test func configWithoutOperatorUsesTheDefaultHoldTimes() throws {
      let c = try JSONCoding.decode(Config.self, from: "{}")

      #expect(c.`operator`.holdRetrySeconds == 120)
      #expect(c.`operator`.holdLimitSeconds == 21600)
    }

    @Test func configWithoutOperatorJudgesWithSonnet() throws {
      let c = try JSONCoding.decode(Config.self, from: "{}")

      #expect(c.`operator`.judgeModel == "sonnet")
    }

    @Test func theDefaultSettingsMatchAnEmptyOperatorObject() throws {
      let c = try JSONCoding.decode(Config.self, from: #"{"operator": {}}"#)

      #expect(c.`operator` == OperatorSettings())
    }

    @Test func configReadsEveryOperatorSetting() throws {
      let c = try JSONCoding.decode(
        Config.self,
        from: #"""
          {"operator": {"mergeRepos": ["haacked/switchboard", "PostHog/charts"], "holdRetrySeconds": 30,
           "holdLimitSeconds": 600, "judgeModel": "haiku"}}
          """#)

      #expect(c.`operator`.mergeRepos == ["haacked/switchboard", "PostHog/charts"])
      #expect(c.`operator`.holdRetrySeconds == 30)
      #expect(c.`operator`.holdLimitSeconds == 600)
      #expect(c.`operator`.judgeModel == "haiku")
    }

    @Test func aPartialOperatorKeepsTheOtherDefaults() throws {
      let c = try JSONCoding.decode(Config.self, from: #"{"operator": {"mergeRepos": ["haacked/switchboard"]}}"#)

      #expect(c.`operator`.mergeRepos == ["haacked/switchboard"])
      #expect(c.`operator`.holdRetrySeconds == 120)
      #expect(c.`operator`.holdLimitSeconds == 21600)
      #expect(c.`operator`.judgeModel == "sonnet")
    }

    @Test func theOperatorKeyLeavesTheOtherSettingsAlone() throws {
      let c = try JSONCoding.decode(Config.self, from: #"{"operator": {"mergeRepos": ["a/b"]}, "liveCap": 7}"#)

      #expect(c.liveCap == 7)
    }
  }
}
