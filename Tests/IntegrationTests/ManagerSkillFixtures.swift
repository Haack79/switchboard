import Foundation
import SwitchboardCore
import Testing

/// The helpers of the suites that test the Manager's work-skill labels and gate.
protocol ManagerSkillSuite {}

extension ManagerSkillSuite {
  func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T { try JSONCoding.decode(type, from: text) }

  /// A sbd with one account A, which new sessions use, so a test can write A's skills before any session starts.
  func instance(config extra: [String: JSON] = [:], idleStopSeconds: Int = 600) throws -> Instance {
    let sbd = try Instance(idleStopSeconds: idleStopSeconds, accounts: ["A"], inheriting: .unset, config: extra)
    try sbd.sb("account", "use", "A")
    return sbd
  }

  /// Writes `<account>/skills/<name>/SKILL.md`. The stub reads its markers from `body`.
  func writeSkill(_ account: String, _ name: String, _ body: String = "Run the pipeline.") throws {
    let folder = "\(account)/skills/\(name)"
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    try "---\nname: \(name)\ndescription: The \(name) skill.\n---\n\(body)\n".write(
      toFile: "\(folder)/SKILL.md", atomically: true, encoding: .utf8)
  }

  /// Starts a Manager conversation and waits until its claude runs, which sends SessionStart.
  @discardableResult
  func newConversation(_ sbd: Instance) throws -> SessionSummary {
    let c = try decode(SessionSummary.self, sbd.sb("manager", "new", "--json"))
    return try sbd.waitFor(c.id, "the Manager's stub") { $0.live }
  }

  /// The rows of `sb manager skills [<conv>] --json`.
  func skills(_ sbd: Instance, _ conversation: String? = nil) throws -> [JSON] {
    try #require(JSON.parse(try sbd.sb(["manager", "skills"] + (conversation.map { [$0] } ?? []) + ["--json"]))?.array)
  }

  func row(_ name: String, _ rows: [JSON]) -> JSON? { rows.first { $0["name"]?.string == name } }

  /// The rows of `sb slash <session> --json` by name.
  func slashRows(_ sbd: Instance, _ session: String) throws -> [String: JSON] {
    let answer = try #require(JSON.parse(try sbd.sb("slash", session, "--json")))
    let rows = try #require(answer["commands"]?.array, "\(answer.text)")
    return Dictionary(rows.compactMap { r in r["name"]?.string.map { ($0, r) } }, uniquingKeysWith: { a, _ in a })
  }

  /// Waits until the skill's row matches and returns it.
  @discardableResult
  func waitForRow(
    _ sbd: Instance, _ name: String, _ what: String, conversation: String? = nil, timeout: Double = 30,
    _ match: (JSON) -> Bool
  ) throws -> JSON {
    try sbd.waitFor(
      "\(name): \(what)", timeout: timeout, fetch: { row(name, try skills(sbd, conversation)) }, until: match)
  }

  @discardableResult
  func waitForLabel(_ sbd: Instance, _ name: String, _ label: String, conversation: String? = nil) throws -> JSON {
    try waitForRow(sbd, name, "label \(label)", conversation: conversation) { $0["label"]?.string == label }
  }

  /// Waits until the skill's row shows a failure and no longer waits for a run.
  @discardableResult
  func waitForError(_ sbd: Instance, _ name: String) throws -> JSON {
    try waitForRow(sbd, name, "an error") { $0["error"]?.string != nil && $0["pending"]?.bool != true }
  }

  /// The skill names of the stub's classification calls, oldest first.
  func calls(_ sbd: Instance) -> [String] {
    let text = (try? String(contentsOfFile: "\(sbd.home.path)/skill-classify-calls.log", encoding: .utf8)) ?? ""
    return text.split(separator: "\n").map(String.init)
  }

  func calls(_ sbd: Instance, _ name: String) -> Int { calls(sbd).filter { $0 == name }.count }

  /// The arguments of the last classification call. `--tools ""` and `--setting-sources ""` are empty arguments,
  /// so empty fields count.
  func classifyArguments(_ sbd: Instance) throws -> [String] {
    let text = try String(contentsOfFile: "\(sbd.home.path)/skill-classify-args", encoding: .utf8)
    return text.split(separator: "\0", omittingEmptySubsequences: false).dropLast().map(String.init)
  }

  /// The value that follows the flag in the arguments, or nil.
  func value(_ flag: String, _ args: [String]) -> String? {
    args.firstIndex(of: flag).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
  }

  /// The labels in `skill-labels.json` by cache key, or none when the file is missing.
  func cachedLabels(_ sbd: Instance) throws -> [String: JSON] {
    guard let text = try? String(contentsOfFile: "\(sbd.home.path)/skill-labels.json", encoding: .utf8) else {
      return [:]
    }
    return try #require(JSON.parse(text)?.object, "skill-labels.json: \(text)")
  }

  func cachedWorkLabels(_ sbd: Instance) throws -> Int {
    try cachedLabels(sbd).values.filter { $0["label"]?.string == "work" }.count
  }

  /// Checks the condition every 0.2 s for the seconds, and fails at the first check that is false.
  func stays(_ what: String, for seconds: Double = 2, _ condition: () throws -> Bool) throws {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      try #require(try condition(), "\(what)")
      usleep(200_000)
    }
  }

  // MARK: The gate

  /// A Manager conversation on account A whose first turn has ended, with the user skill `go` labeled `work`.
  @discardableResult
  func workGoConversation(_ sbd: Instance) throws -> SessionSummary {
    try writeSkill(sbd.account("A"), "go")
    let c = try newConversation(sbd)
    try waitForLabel(sbd, "go", "work")
    return try prompt(sbd, c, "hello")
  }

  /// Sends the session a message and waits for the reply `Done: <text>`.
  @discardableResult
  func prompt(_ sbd: Instance, _ s: SessionSummary, _ text: String, timeout: Double = 30) throws -> SessionSummary {
    try sbd.sb("send", s.id, text)
    return try sbd.waitFor(s.id, "the reply to \(text)", timeout: timeout) { $0.lastReply == "Done: \(text)" }
  }

  /// Waits until the session has `count` events of the kind, and returns them.
  @discardableResult
  func waitForEvents(_ sbd: Instance, _ id: String, _ kind: String, count: Int = 1, timeout: Double = 30) throws
    -> [Event]
  {
    try sbd.waitFor("\(count) \(kind) of \(id)", timeout: timeout, fetch: { try sbd.events(id, kind: kind) }) {
      $0.count >= count
    }
  }

  /// The UserPromptSubmit answers whose decision is block that the stub got for the session, oldest first.
  func blocks(_ sbd: Instance, _ s: SessionSummary) -> [JSON] {
    sbd.hookOutputs(s.claudeSessionId).filter { $0["decision"]?.string == "block" }
  }

  /// The PreToolUse answers that denied a call, oldest first.
  func denials(_ sbd: Instance, _ s: SessionSummary) -> [JSON] {
    sbd.hookOutputs(s.claudeSessionId).filter {
      $0["hookSpecificOutput"]?["permissionDecision"]?.string == "deny"
    }
  }

  /// The `sent` events that hold the text.
  func sent(_ sbd: Instance, _ id: String, _ text: String) throws -> [Event] {
    try sbd.events(id, kind: "sent").filter { $0.data["text"]?.string == text }
  }

  /// Sends a hook payload of the session's claude to sbd's own socket, as `sb hook` does, and returns sbd's
  /// answer: what the hook prints. It throws when sbd refuses the request.
  @discardableResult
  func hook(_ sbd: Instance, _ s: SessionSummary, _ payload: [String: JSON]) throws -> JSON {
    var fields = payload
    fields["session_id"] = .string(s.claudeSessionId)
    fields["permission_mode"] = "default"
    fields["cwd"] = .string(s.cwd)
    let line = Instance.hookLine(session: .string(s.id), payload: .object(fields), id: nil)
    let answer = try #require(try sbd.sendLine(line, to: sbd.home.socket), "no answer to \(line)")
    try #require(answer["ok"] == true, "sbd refused the hook: \(answer.text)")
    return answer["result"] ?? [:]
  }

  /// A UserPromptSubmit of the text, sent straight to sbd.
  @discardableResult
  func hookPrompt(_ sbd: Instance, _ s: SessionSummary, _ text: String) throws -> JSON {
    try hook(sbd, s, ["hook_event_name": "UserPromptSubmit", "prompt": .string(text)])
  }

  /// A PreToolUse of the Skill tool for the name, sent straight to sbd. `agent` makes it a subagent's call.
  @discardableResult
  func hookSkillCall(_ sbd: Instance, _ s: SessionSummary, _ name: String, agent: String? = nil) throws -> JSON {
    var payload: [String: JSON] = [
      "hook_event_name": "PreToolUse", "tool_name": "Skill", "tool_input": ["skill": .string(name)],
      "tool_use_id": .string("s-\(UUID().uuidString)"),
    ]
    if let agent { payload["agent_id"] = .string(agent) }
    return try hook(sbd, s, payload)
  }

  /// Whether a UserPromptSubmit answer blocks the prompt.
  func isBlock(_ answer: JSON) -> Bool { answer["decision"]?.string == "block" }

  /// Whether a PreToolUse answer denies the call.
  func isDeny(_ answer: JSON) -> Bool { answer["hookSpecificOutput"]?["permissionDecision"]?.string == "deny" }

  /// Writes the transcript listing that the stub appends before the first prompt of each launch. Each item is a
  /// name and its description, or a name alone.
  func writeListing(_ sbd: Instance, _ items: [(name: String, description: String?)]) throws {
    let content = items.map { "- \($0.name)" + ($0.description.map { ": \($0)" } ?? "") }.joined(separator: "\n")
    let line: JSON = [
      "type": "attachment", "isSidechain": false,
      "attachment": [
        "type": "skill_listing", "isInitial": true, "names": .array(items.map { .string($0.name) }),
        "content": .string(content + "\n"),
      ],
    ]
    try (line.text + "\n").write(toFile: "\(sbd.home.path)/skill-listing.jsonl", atomically: true, encoding: .utf8)
  }
}
