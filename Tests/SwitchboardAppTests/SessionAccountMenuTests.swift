import AppKit
import SwitchboardCore
import Testing

@testable import SwitchboardApp

/// The "Move to Account" entries of a session, the group lock that disables
/// them, and the confirmation that a move asks for. The entries mirror sbd's
/// refusals in `account-move`, so each shape that sbd treats differently has a test.
@MainActor
@Suite struct SessionAccountMenuTests {
  nonisolated static let work = "/Users/me/.claude-work"
  nonisolated static let personal = "/Users/me/.claude-personal"
  nonisolated static let max = "/Users/me/.claude-max"

  nonisolated static let accounts = [
    AccountInfo(name: "work", folder: work, active: true, sessions: 2),
    AccountInfo(name: "personal", folder: personal, active: false, sessions: 1),
    AccountInfo(name: "max", folder: max, active: false, sessions: 0),
  ]

  /// A work session on `account`, stopped, in `group` when one is given.
  func session(
    _ id: String = "a", group: String? = nil, account: String? = SessionAccountMenuTests.personal, live: Bool = false
  ) -> SessionSummary {
    var s = SessionSummary(
      id: id, name: id, cwd: "/tmp/\(id)", repo: nil, branch: nil, claudeSessionId: id, state: .waiting, reason: "",
      since: 0, lastActivity: 0, live: live, claudePid: live ? 4242 : nil, attached: false, lastReply: nil, waits: [],
      notes: [])
    s.group = group
    s.account = account
    return s
  }

  /// A Manager conversation on `personal` in the Manager folder.
  func conversation(_ id: String = "m", mcp: [String]? = [], live: Bool = false) -> SessionSummary {
    var s = session(id, live: live)
    s.cwd = "/Users/me/.switchboard/manager"
    s.kind = .manager
    s.manager = true
    s.mcp = mcp
    return s
  }

  func theOperator(live: Bool = false) -> SessionSummary {
    var s = session("op", live: live)
    s.name = "Operator"
    s.cwd = "/Users/me/.switchboard/manager"
    s.kind = .operator
    s.mcp = []
    return s
  }

  /// The chat of group g1.
  func chat(mcp: [String]? = nil) -> SessionSummary {
    var s = session("chat")
    s.kind = .chat
    s.chat = "g1"
    s.mcp = mcp
    return s
  }

  /// Group g1, Flags, whose sessions run under `account` when it is set, and group g2, Docs, with no account.
  func groups(account: String? = nil) -> [GroupSummary] {
    [
      GroupSummary(SessionGroup(id: "g1", name: "Flags", created: 0, account: account), sessions: []),
      GroupSummary(SessionGroup(id: "g2", name: "Docs", created: 0), sessions: []),
    ]
  }

  func entries(
    _ s: SessionSummary, accounts: [AccountInfo] = SessionAccountMenuTests.accounts, usage: [AccountUsage] = [],
    groups: [GroupSummary]? = nil
  ) -> [SessionAccountEntry] {
    SessionAccountMenu.entries(for: s, accounts: accounts, usage: usage, groups: groups ?? self.groups())
  }

  func enabled(_ entries: [SessionAccountEntry]) -> [String] { entries.filter { !$0.disabled }.map(\.folder) }

  // MARK: Entries

  /// Each title reads as the toolbar's account label: the name, the 5-hour
  /// percent when the reading has one, and the highest weekly percent.
  @Test func theEntriesListEveryAccountInOrderWithTheToolbarsLabels() {
    let usage = [
      AccountUsage(
        name: "work", folder: Self.work,
        limits: [
          UsageLimit(kind: "session", label: "Session (5h)", percent: 66),
          UsageLimit(kind: "weekly_all", label: "Week (all models)", percent: 82),
        ]),
      AccountUsage(
        name: "max", folder: Self.max, limits: [UsageLimit(kind: "weekly_all", label: "Week (all models)", percent: 8)]
      ),
    ]

    let list = entries(session(), usage: usage)

    #expect(list.map(\.folder) == [Self.work, Self.personal, Self.max])
    #expect(list.map(\.title) == ["work · 5h 66% · wk 82%", "personal", "max · wk 8%"])
  }

  @Test func theTitlesMatchTheAccountMenuLabels() {
    let usage = [
      AccountUsage(name: "max", folder: Self.max, limits: [UsageLimit(kind: "weekly_all", label: "Week", percent: 8)])
    ]

    let list = entries(session(), usage: usage)

    #expect(list.map(\.title) == AccountMenu.rows(accounts: Self.accounts, usage: usage).map { AccountMenu.label($0) })
  }

  @Test func theCurrentAccountIsCheckedAndDisabled() {
    let list = entries(session(account: Self.personal))

    #expect(list.filter(\.checked).map(\.folder) == [Self.personal])
    #expect(list.first { $0.folder == Self.personal }?.disabled == true)
    #expect(enabled(list) == [Self.work, Self.max])
  }

  /// Folders compare as `ClaudeAccount` values, as sbd's `notMovable` compares them.
  @Test(arguments: ["/Users/me/.claude-personal/", "/Users/me/./.claude-personal", "/Users/me//.claude-personal"])
  func theCurrentAccountMatchesAFolderWrittenAnotherWay(_ folder: String) {
    let list = entries(session(account: folder))

    #expect(list.filter(\.checked).map(\.folder) == [Self.personal])
    #expect(enabled(list) == [Self.work, Self.max])
  }

  /// A record from an older sbd has no account, and the app can't name sbd's own account.
  @Test func aSessionWithoutAnAccountChecksNothing() {
    let list = entries(session(account: nil))

    #expect(list.filter(\.checked).isEmpty)
    #expect(enabled(list) == [Self.work, Self.personal, Self.max])
  }

  @Test func aSignedOutAccountIsDisabledAndItsHelpNamesTheLogin() {
    let login = "not signed in. Run CLAUDE_CONFIG_DIR=/Users/me/.claude-max claude /login"
    let usage = [AccountUsage(name: "max", folder: Self.max, error: login, signedOut: true)]

    let list = entries(session(), usage: usage)

    let entry = list.first { $0.folder == Self.max }
    #expect(entry?.disabled == true)
    #expect(entry?.title == "max (not signed in)")
    #expect(entry?.help == login)
    #expect(entry?.checked == false)
  }

  /// sbd moves a session to an account it has not read yet, so the entry stays enabled.
  @Test func anAccountWithoutAReadingIsEnabled() {
    let list = entries(session(), usage: [])

    #expect(enabled(list) == [Self.work, Self.max])
  }

  /// A failed read with `signedOut` unset does not mean the account has no login.
  @Test func anAccountWhoseReadFailedIsEnabled() {
    let usage = [AccountUsage(name: "max", folder: Self.max, error: "timed out")]

    let list = entries(session(), usage: usage)

    #expect(enabled(list) == [Self.work, Self.max])
  }

  // MARK: The group lock

  @Test func aGroupWithAnAccountDisablesEveryOtherAccount() {
    let s = session(group: "g1", account: Self.personal)

    let list = entries(s, groups: groups(account: Self.personal))

    #expect(enabled(list).isEmpty)
    #expect(list.filter(\.checked).map(\.folder) == [Self.personal])
  }

  @Test func theLockLineNamesTheGroupAndItsAccount() {
    let s = session(group: "g1", account: Self.personal)

    let lock = SessionAccountMenu.groupLock(for: s, groups: groups(account: Self.personal))

    #expect(lock?.line == "Its group, Flags, runs on personal. Change the group's account instead.")
    #expect(lock?.groupName == "Flags")
    #expect(lock?.accountName == "personal")
  }

  /// sbd allows the move to the group's own account, so that entry stays enabled.
  @Test func theGroupsAccountIsEnabledForAMemberOnAnotherAccount() {
    let s = session(group: "g1", account: Self.work)

    let list = entries(s, groups: groups(account: Self.personal))

    #expect(enabled(list) == [Self.personal])
    #expect(list.filter(\.checked).map(\.folder) == [Self.work])
  }

  /// sbd's `moveRefusal` compares the target with the group's folder whether
  /// or not sbd still lists it, so every listed account is refused.
  @Test func aGroupAccountThatSbdNoLongerListsDisablesEveryAccount() {
    let s = session(group: "g1", account: Self.work)
    let gone = "/Users/me/.claude-old"

    let list = entries(s, groups: groups(account: gone))
    let lock = SessionAccountMenu.groupLock(for: s, groups: groups(account: gone))

    #expect(enabled(list).isEmpty)
    #expect(lock?.line == "Its group, Flags, runs on old. Change the group's account instead.")
  }

  /// A chat's group is in `chat`, not `group`, as in sbd's `accountGroup(of:)`.
  @Test func aGroupChatGetsTheLock() {
    let lock = SessionAccountMenu.groupLock(for: chat(), groups: groups(account: Self.work))
    let list = entries(chat(), groups: groups(account: Self.work))

    #expect(lock?.groupName == "Flags")
    #expect(enabled(list) == [Self.work])
  }

  @Test func aGroupWithoutAnAccountGivesNoLock() {
    let s = session(group: "g2")

    #expect(SessionAccountMenu.groupLock(for: s, groups: groups(account: Self.work)) == nil)
    #expect(enabled(entries(s, groups: groups(account: Self.work))) == [Self.work, Self.max])
  }

  @Test func aSessionWithoutAGroupGetsNoLock() {
    let s = session(group: nil)

    #expect(SessionAccountMenu.groupLock(for: s, groups: groups(account: Self.work)) == nil)
    #expect(enabled(entries(s, groups: groups(account: Self.work))) == [Self.work, Self.max])
  }

  @Test func aManagerConversationAndTheOperatorGetNoLock() {
    for s in [conversation(), theOperator()] {
      #expect(SessionAccountMenu.groupLock(for: s, groups: groups(account: Self.work)) == nil, "\(s.kind)")
      #expect(enabled(entries(s, groups: groups(account: Self.work))) == [Self.work, Self.max], "\(s.kind)")
    }
  }

  // MARK: Visibility

  @Test func theSubmenuShowsForAStartedLocalSessionWithAnotherAccount() {
    for s in [session(), conversation(), theOperator(), chat()] {
      #expect(SessionAccountMenu.shows(s, accountCount: 2), "\(s.kind)")
    }
  }

  @Test func theSubmenuHidesForAHostSession() {
    var s = session()
    s.host = "devbox"

    #expect(!SessionAccountMenu.shows(s, accountCount: 2))
  }

  @Test func theSubmenuHidesForAnUnstartedSession() {
    var s = session()
    s.cwd = ""
    s.state = .notStarted

    #expect(!SessionAccountMenu.shows(s, accountCount: 2))
  }

  @Test(arguments: [0, 1]) func theSubmenuHidesWithoutAnotherAccount(_ count: Int) {
    #expect(!SessionAccountMenu.shows(session(), accountCount: count))
  }

  // MARK: The confirmation

  static let memoryLine =
    "Claude Code keeps the Manager folder's memory in each account, so m may read different memory on work."
  static let connectorLine =
    "Claude.ai connectors, such as Slack, belong to each account's claude.ai login. A connector that only personal has won't be there."
  static let restartLine = "It restarts on the new account with its next message."
  /// The start of `AccountMove.consequences`, which the message carries after its own lines.
  static let consequencesStart = "A moved session resumes its conversation under the new account"

  func plan(_ id: String, mcpDropped: [String: [String]]? = nil) -> AccountMove {
    AccountMove(account: Self.work, moved: [id], blocked: [], mcpDropped: mcpDropped)
  }

  func decide(_ s: SessionSummary, plan: AccountMove? = nil) -> SessionAccountMove.Decision {
    SessionAccountMove.decide(session: s, target: Self.work, plan: plan ?? self.plan(s.id))
  }

  /// The confirmation that `decision` holds, or nil with an issue recorded.
  func confirmation(_ decision: SessionAccountMove.Decision) -> SessionAccountMove? {
    guard case .confirm(let move) = decision else {
      Issue.record("expected a confirmation, got \(decision)")
      return nil
    }
    return move
  }

  @Test func aBlockedPlanRefusesWithSbdsReason() {
    let reason = "its group Flags runs its sessions under the account personal. Move it out of the group"
    let blocked = AccountMove(account: Self.work, blocked: [.init(session: "a", name: "a", reason: reason)])

    let decision = decide(session(), plan: blocked)

    guard case .refuse(let message) = decision else {
      Issue.record("expected a refusal, got \(decision)")
      return
    }
    #expect(message == "Can't move a to work: \(reason)")
  }

  /// A refusal comes before the Stop and Move dialog, so a blocked move never stops claude.
  @Test func aBlockedPlanRefusesARunningSession() {
    let blocked = AccountMove(account: Self.work, blocked: [.init(session: "a", name: "a", reason: "it is starting")])

    let decision = decide(session(live: true), plan: blocked)

    guard case .refuse = decision else {
      Issue.record("expected a refusal, got \(decision)")
      return
    }
  }

  @Test func aPlanThatBlocksAnotherSessionDoesNotRefuse() {
    let other = AccountMove(
      account: Self.work, moved: ["a"], blocked: [.init(session: "b", name: "b", reason: "it is starting")])

    let decision = decide(session(), plan: other)

    #expect(decision == .move)
  }

  @Test func aRunningWorkSessionConfirmsAStopAndMove() {
    let move = confirmation(decide(session(live: true)))

    #expect(move?.title == "Stop a and move it to work?")
    #expect(move?.message.hasPrefix(Self.restartLine) == true)
    #expect(move?.message.contains(Self.consequencesStart) == true)
    #expect(move?.button == "Stop and Move")
    #expect(move?.stop == true)
    #expect(move?.session == "a")
  }

  /// A work session has `mcp == nil`, and the Manager lines are only for a session whose kind is not work.
  @Test func aRunningWorkSessionsMessageHasNoManagerLines() {
    let move = confirmation(decide(session(live: true)))

    #expect(move?.message.contains("memory") == false)
    #expect(move?.message.contains("connectors") == false)
    #expect(move?.message.contains("MCP server named") == false)
  }

  @Test func anIdleWorkSessionMovesWithoutStop() {
    let decision = decide(session())

    #expect(decision == .move)
  }

  @Test func anIdleManagerConversationConfirmsAMoveWithoutStop() {
    let move = confirmation(decide(conversation(mcp: [])))

    #expect(move?.title == "Move m to work?")
    #expect(move?.button == "Move")
    #expect(move?.stop == false)
    #expect(move?.message.contains(Self.memoryLine) == true)
    #expect(move?.message.contains(Self.consequencesStart) == true)
  }

  /// A conversation with an `mcp` list runs under `--strict-mcp-config`, which loads no claude.ai connectors.
  @Test func theConnectorLineShowsOnlyForAConversationWithEveryServer() {
    let full = confirmation(decide(conversation(mcp: nil)))
    let listed = confirmation(decide(conversation(mcp: ["notes"])))
    let none = confirmation(decide(conversation(mcp: [])))

    #expect(full?.message.contains(Self.connectorLine) == true)
    #expect(listed?.message.contains("connectors") == false)
    #expect(none?.message.contains("connectors") == false)
  }

  @Test func theDroppedServersFromTheDryRunMakeTheMCPLine() {
    let s = conversation(mcp: ["grafana", "notes", "posthog-db"])

    let move = confirmation(decide(s, plan: plan("m", mcpDropped: ["m": ["grafana", "notes"]])))

    #expect(
      move?.message.contains("work has no MCP server named grafana and notes, so m starts without them.") == true)
  }

  @Test func aConversationWithNoDroppedServerHasNoMCPLine() {
    let move = confirmation(decide(conversation(mcp: ["notes"]), plan: plan("m", mcpDropped: nil)))

    #expect(move?.message.contains("MCP server named") == false)
  }

  @Test func aRunningManagerConversationConfirmsAStopAndMoveWithItsLines() {
    let move = confirmation(decide(conversation(mcp: nil, live: true)))

    #expect(move?.title == "Stop m and move it to work?")
    #expect(move?.button == "Stop and Move")
    #expect(move?.stop == true)
    #expect(move?.message.hasPrefix(Self.restartLine) == true)
    #expect(move?.message.contains(Self.memoryLine) == true)
    #expect(move?.message.contains(Self.connectorLine) == true)
  }

  @Test func theOperatorGetsTheMemoryLine() {
    let move = confirmation(decide(theOperator()))

    #expect(move?.title == "Move Operator to work?")
    #expect(move?.stop == false)
    #expect(
      move?.message.contains(
        "Claude Code keeps the Manager folder's memory in each account, so Operator may read different memory on work.")
        == true)
  }

  /// A chat runs in its group's folder, not the Manager folder.
  @Test func aChatConfirmsWithoutTheMemoryLine() {
    let full = confirmation(decide(chat(mcp: nil)))
    let listed = confirmation(decide(chat(mcp: [])))

    #expect(full?.title == "Move chat to work?")
    #expect(full?.stop == false)
    #expect(full?.message.contains("memory") == false)
    #expect(full?.message.contains(Self.connectorLine) == true)
    #expect(listed?.message.contains("connectors") == false)
  }
}
