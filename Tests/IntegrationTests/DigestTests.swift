import Foundation
import SwitchboardCore
import Testing

/// A Manager or a group chat gets no message when a child changes. It gets a
/// digest of its children with the next prompt, through the UserPromptSubmit
/// hook, and it follows a child through a wait.
@Suite(.blocking(timeLimit: .seconds(120))) struct DigestTests {
  enum Parent: CaseIterable { case manager, chat }

  func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T { try JSONCoding.decode(type, from: text) }

  /// A Manager or a group chat whose first turn has ended.
  func parent(_ sbd: Instance, _ kind: Parent) throws -> SessionSummary {
    let opened: SessionSummary
    switch kind {
    case .manager:
      opened = try decode(SessionSummary.self, sbd.sb("manager", "--json"))
    case .chat:
      _ = try sbd.sb("group", "add", "--json", "Flags")
      opened = try decode(SessionSummary.self, sbd.sb("chat", "Flags", "--json"))
    }
    try sbd.waitFor(opened.id, "the stub") { $0.live }
    return try prompt(sbd, opened, "hello")
  }

  /// Sends the session a message and waits for the reply.
  @discardableResult
  func prompt(_ sbd: Instance, _ s: SessionSummary, _ text: String) throws -> SessionSummary {
    try sbd.sb("send", s.id, text)
    return try sbd.waitFor(s.id, "the reply to \(text)", timeout: 30) { $0.lastReply == "Done: \(text)" }
  }

  /// Starts a session from inside `parent`, as a command that Claude runs there would.
  func child(_ sbd: Instance, of parent: SessionSummary, name: String, prompt: String) throws -> SessionSummary {
    try decode(
      SessionSummary.self,
      sbd.sb(
        "new", "--json", "--name", name, "--prompt", prompt, sbd.work,
        env: ["SB_SESSION_ID": parent.id, "CLAUDECODE": "1"]))
  }

  /// Sends the child two more prompts, so it moves from Needs you to Working and back twice.
  func flip(_ sbd: Instance, _ kid: SessionSummary) throws {
    for text in ["two", "three"] {
      try sbd.sb("send", kid.id, text)
      try sbd.waitFor(kid.id, "the reply to \(text)") { $0.lastReply == "Done: \(text)" && $0.state == .needsYou }
    }
  }

  /// The additionalContext of each UserPromptSubmit answer that the parent's claude got, oldest first.
  func contexts(_ sbd: Instance, _ s: SessionSummary) -> [String] {
    sbd.hookOutputs(s.claudeSessionId).compactMap { $0["hookSpecificOutput"]?["additionalContext"]?.string }
  }

  @Test(arguments: Parent.allCases) func aChildThatNeedsYouSendsTheParentNothing(_ kind: Parent) throws {
    let sbd = try Instance()
    let p = try parent(sbd, kind)
    let kid = try child(sbd, of: p, name: "kid", prompt: "one")
    try sbd.waitForReply(kid)
    // Five ticks, each of which would send a notice.
    Thread.sleep(forTimeInterval: 1)
    #expect(try sbd.sbdMessages(p.id).isEmpty)
    #expect(try sbd.get(p.id).lastReply == "Done: hello")
  }

  @Test(arguments: Parent.allCases) func theNextPromptGetsTheChildsLineOnceAfterThreeFlips(_ kind: Parent) throws {
    let sbd = try Instance()
    let p = try parent(sbd, kind)
    let kid = try child(sbd, of: p, name: "kid", prompt: "one")
    try sbd.waitFor(kid.id, "the first reply") { $0.lastReply == "Done: one" && $0.state == .needsYou }
    try flip(sbd, kid)
    let before = contexts(sbd, p).count

    try prompt(sbd, p, "what changed")

    let given = contexts(sbd, p).dropFirst(before)
    #expect(given.count == 1)
    let text = try #require(given.first)
    let line =
      "- kid (\(kid.id)): needs you in its own Inbox item (switchboard://session/\(kid.id)): read its last reply and decide what's next"
    #expect(text.components(separatedBy: line).count == 2, "\(text)")
    #expect(text.hasPrefix("Switchboard: what changed since your last turn."))
    #expect(try sbd.events(p.id).filter { $0.kind == "digest" }.last?.data["text"]?.string == text)
    #expect(try sbd.sbdMessages(p.id).isEmpty)

    // Nothing changed since that prompt, so the next one gets nothing.
    try prompt(sbd, p, "anything else")
    #expect(contexts(sbd, p).count == before + 1)
  }

  @Test func aRestartedSbdDoesNotRepeatWhatTheParentHeard() throws {
    let sbd = try Instance()
    let p = try parent(sbd, .manager)
    let kid = try child(sbd, of: p, name: "kid", prompt: "one")
    try sbd.waitForReply(kid)
    try prompt(sbd, p, "what changed")
    #expect(contexts(sbd, p).last?.contains("kid (\(kid.id))") == true)
    let heard = contexts(sbd, p).count

    try sbd.restart(setting: "tickSeconds", to: 0.2)
    try prompt(sbd, p, "again")

    #expect(contexts(sbd, p).count == heard)
  }

  // Issue #158.
  @Test func aManagerHearsOfAChildsPROnlyOnce() throws {
    let github = try FakeGitHub()
    defer { withExtendedLifetime(github) {} }
    let sbd = try Instance.withGitHub(github)
    let p = try parent(sbd, .manager)
    let kid = try sbd.session(
      in: ReadyForReviewTests.charts, branch: ReadyForReviewTests.branch, folder: "charts", parent: p.id, name: "kid")
    try sbd.poll()
    try sbd.waitFor(kid.id, "PR #18303") { $0.pr?.number == 18303 }
    try prompt(sbd, p, "first")
    try #require(contexts(sbd, p).last?.contains("opened PR #18303") == true, "\(contexts(sbd, p))")

    try sbd.git(kid.cwd, "checkout", "-q", "-b", "haacked/no-pr-yet")
    try sbd.poll()
    try sbd.waitFor(kid.id, "no PR") { $0.pr == nil }
    try prompt(sbd, p, "second")

    try sbd.git(kid.cwd, "checkout", "-q", ReadyForReviewTests.branch)
    try sbd.poll()
    try sbd.waitFor(kid.id, "PR #18303 again") { $0.pr?.number == 18303 }
    let before = contexts(sbd, p).count
    try prompt(sbd, p, "third")

    let given = contexts(sbd, p).dropFirst(before).joined()
    #expect(given.contains("#18303 is ready to merge"), "\(given)")
    #expect(!given.contains("opened PR #18303"), "\(given)")
  }

  @Test func theDigestStaysOutOfTheChatLog() throws {
    let sbd = try Instance()
    let p = try parent(sbd, .chat)
    let kid = try child(sbd, of: p, name: "kid", prompt: "one")
    try sbd.waitForReply(kid)
    try prompt(sbd, p, "what changed")
    #expect(contexts(sbd, p).contains { $0.contains("kid (\(kid.id))") })

    let log = try decode([ChatMessage].self, sbd.sb("chat", "Flags", "--log", "--json"))

    #expect(log.map(\.text) == ["hello", "Done: hello", "what changed", "Done: what changed"])
  }

  /// Claude Code keeps each digest in the conversation's context. A change in the counts alone sends no digest.
  @Test(arguments: Parent.allCases) func aChangeInTheCountsAloneSendsNoDigest(_ kind: Parent) throws {
    let sbd = try Instance()
    let p = try parent(sbd, kind)
    let other = try sbd.new(prompt: "hello", name: "other")
    if kind == .chat { _ = try sbd.sb("group", "move", other.id, "--to", "Flags") }
    try sbd.waitForReply(other)
    let given = contexts(sbd, p).count
    let digests = try sbd.events(p.id, kind: "digest").count

    try prompt(sbd, p, "what changed")

    #expect(contexts(sbd, p).count == given, "\(contexts(sbd, p))")
    #expect(try sbd.events(p.id, kind: "digest").count == digests)
  }

  @Test func theDigestCountsTheOtherSessionsThatNeedYou() throws {
    let sbd = try Instance()
    let p = try parent(sbd, .manager)
    let other = try sbd.new(prompt: "hello", name: "other")
    try sbd.waitForReply(other)
    let kid = try child(sbd, of: p, name: "kid", prompt: "one")
    try sbd.waitForReply(kid)

    try prompt(sbd, p, "what changed")

    let text = try #require(contexts(sbd, p).last)
    #expect(text.contains("kid (\(kid.id))"), "\(text)")
    #expect(text.hasSuffix("Other sessions: 1 in Needs you, 0 in Ready to merge."), "\(text)")
  }

  @Test func aChatCountsOnlyTheSessionsInItsGroup() throws {
    let sbd = try Instance()
    let p = try parent(sbd, .chat)
    let inFlags = try sbd.new(prompt: "hello", name: "inflags")
    let inDocs = try sbd.new(prompt: "hello", name: "indocs")
    _ = try sbd.sb("group", "move", inFlags.id, "--to", "Flags")
    _ = try sbd.sb("group", "add", "--json", "Docs", inDocs.id)
    let kid = try child(sbd, of: p, name: "kid", prompt: "one")
    for s in [inFlags, inDocs, kid] { try sbd.waitForReply(s) }

    try prompt(sbd, p, "what changed")

    let text = try #require(contexts(sbd, p).last)
    #expect(text.hasSuffix("Other sessions: 1 in Needs you, 0 in Ready to merge."), "\(text)")
  }

  @Test func aWorkSessionGetsNoDigest() throws {
    let sbd = try Instance()
    let p = try sbd.new(prompt: "hello", name: "p")
    try sbd.waitFor(p.id, "the reply") { $0.lastReply == "Done: hello" }
    let kid = try child(sbd, of: p, name: "kid", prompt: "one")
    try sbd.waitFor(p.id, "the notice") { $0.lastReply?.contains("(\(kid.id)) needs you") == true }

    try prompt(sbd, p, "what changed")

    #expect(contexts(sbd, p).isEmpty)
    #expect(try sbd.events(p.id).filter { $0.kind == "digest" }.isEmpty)
  }

  @Test func aSessionWaitOnAChildResumesTheManagerOnce() throws {
    let sbd = try Instance()
    let p = try parent(sbd, .manager)
    let kid = try child(sbd, of: p, name: "kid", prompt: "slow 2")
    try sbd.waitFor(kid.id, "the kid's turn") { $0.state == .working }
    try sbd.sb("wait", p.id, "--kind", "session", "--target", "kid", "--state", "needs_you")

    let resumed = try sbd.waitFor(p.id, "the resumed turn", timeout: 30) {
      $0.lastReply == "Done: Switchboard: kid to reach Needs you: it did."
    }
    #expect(resumed.waits.isEmpty)
    try flip(sbd, kid)
    Thread.sleep(forTimeInterval: 1)

    #expect(try sbd.sbdMessages(p.id).count == 1)
  }

  @Test func bothGuidesSayToFollowAChildWithAWait() {
    for guide in [Manager.guide, Chat.guide] {
      #expect(guide.contains("the context of a prompt can list what changed since your last turn"))
      #expect(guide.contains("set a `session` wait on it"))
      #expect(!guide.contains("tell you themselves"))
    }
    #expect(Manager.guide.contains("Your waits go to the operator"))
    #expect(!Manager.guide.contains("resumes you once"))
  }
}

/// Decision 46: the Operator's turns come from schedules and waits that carry their own status, so its prompts get
/// no per-turn digest. A Manager conversation's prompts still get one. The Operator's start digest stays, and the
/// count taken before the prompt leaves it out.
extension DigestTests {
  enum Holder: CaseIterable { case theOperator, conversation }

  /// The Operator takes its prompts through `sb operator`. A conversation takes them through `sb send`.
  func promptHolder(_ sbd: Instance, _ holder: Holder, _ s: SessionSummary, _ text: String) throws {
    switch holder {
    case .theOperator:
      try sbd.sb("operator", text)
      try sbd.waitFor(s.id, "the reply to \(text)", timeout: 30) { $0.lastReply == "Done: \(text)" }
    case .conversation:
      try prompt(sbd, s, text)
    }
  }

  @Test(arguments: Holder.allCases) func onlyAManagerConversationsPromptGetsTheDigest(_ holder: Holder) throws {
    let sbd = try Instance()
    let p =
      holder == .theOperator
      ? try OperatorTests().idleOperator(sbd) : try ManagerConversationsTests().idleConversation(sbd)
    let kid = try child(sbd, of: p, name: "kid", prompt: "one")
    let kidParent = try sbd.get(kid.id).parent
    try #require(kidParent == p.id, "the kid's parent is \(String(describing: kidParent))")
    try sbd.waitFor(kid.id, "the first reply") { $0.lastReply == "Done: one" && $0.state == .needsYou }
    try flip(sbd, kid)
    let before = contexts(sbd, p).count

    try promptHolder(sbd, holder, p, "what changed")

    let given = contexts(sbd, p).dropFirst(before).joined(separator: "\n")
    // The start digest is a `digest` event too, so only a per-turn digest's text counts.
    let digests = try sbd.events(p.id).filter {
      $0.kind == "digest" && $0.data["text"]?.string?.hasPrefix("Switchboard: what changed") == true
    }
    switch holder {
    case .theOperator:
      #expect(!given.contains("kid (\(kid.id))"), "\(given)")
      #expect(!given.contains("Switchboard: what changed since your last turn."), "\(given)")
      #expect(digests.isEmpty, "\(digests)")
    case .conversation:
      #expect(given.contains("kid (\(kid.id))"), "\(given)")
      #expect(digests.count == 1, "\(digests)")
    }
  }
}
