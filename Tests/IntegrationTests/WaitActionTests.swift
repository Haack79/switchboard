import Foundation
import SwitchboardCore
import Testing

/// Wait actions: `sb wait --then merge|rm-worktree|rm|report` and MCP `set_wait` store a checked, authorized action
/// on the wait. sbd decides who may arm one from the client's process ancestry. Tests that need a caller inside a
/// session run sb from that session's Claude pane, as a tool call of the stub. A command that the test runner starts
/// runs outside every pane, which counts as the user. FollowThroughTests covers what sbd does when an action wait
/// resolves.
@Suite(.blocking(timeLimit: .seconds(120))) struct WaitActionTests {
  let handoff = OperatorHandoffTests()
  let operatorHelpers = OperatorTests()

  static let charts = MergeTests.charts
  /// The name of the session on #18303's branch, which the merge waits target.
  static let target = "fix-cache"
  static let note = "merge per the rule"
  /// The start of sbd's refusal for a caller that may not arm an action.
  static let refusal = "only a Manager conversation, the Operator, or you can arm"
  static let mergeRefusal = "only a Manager conversation, the Operator, or you can arm merge"

  /// A private sbd whose poller asks `github`, with Fixtures/gh-merge-stub as its gh, so `ghMerges` shows any merge.
  /// `mergeRepos` is `operator.mergeRepos` in config.json, or nil to leave the key out.
  func instance(_ github: FakeGitHub, mergeRepos: [String]? = [charts]) throws -> Instance {
    try Instance.withMergeStub(github, mergeRepos: mergeRepos)
  }

  /// A session on #18303's branch whose PR the poller has read. #18303 still needs a review, so the session is not
  /// Ready to merge and a merge wait on it stays open.
  func notReadyTarget(_ github: FakeGitHub, _ sbd: Instance) throws -> SessionSummary {
    github.change(MergeTests.number) {
      $0["reviewDecision"] = "REVIEW_REQUIRED"
      $0["latestOpinionatedReviews"] = ["nodes": []]
    }
    let s = try sbd.session(in: Self.charts, branch: MergeTests.branch, name: Self.target)
    try sbd.poll()
    let read = try sbd.waitFor(s.id, "the poller's read of #18303") { $0.pr?.number == MergeTests.number }
    try #require(read.state != .readyToMerge)
    return read
  }

  /// A session on #18303's branch that is Ready to merge.
  func readyTarget(_ sbd: Instance) throws -> SessionSummary {
    let s = try sbd.session(in: Self.charts, branch: MergeTests.branch, name: Self.target)
    try sbd.poll()
    return try sbd.waitFor(s.id, "Ready to merge") { $0.state == .readyToMerge }
  }

  func conversation(_ sbd: Instance) throws -> SessionSummary { try handoff.conversation(sbd) }

  func theOperator(_ sbd: Instance) throws -> SessionSummary { try handoff.theOperator(sbd) }

  /// The arguments of a merge wait on `s`.
  func mergeArgs(_ s: SessionSummary) -> [String] {
    ["--kind", "session", "--target", s.id, "--state", "ready_to_merge", "--then", "merge"]
  }

  /// Whether no session holds a wait.
  func noWaits(_ sbd: Instance) throws -> Bool {
    try sbd.client.sessions().allSatisfy { $0.waits.isEmpty }
  }

  /// The session that `sb --json` printed.
  func parse(_ r: CommandResult) throws -> JSON {
    try #require(JSON.parse(r.stdout), Comment(rawValue: "stdout: \(r.stdout)\nstderr: \(r.stderr)"))
  }

  /// The last wait of a session as JSON, which is the wait that the command set, because sbd appends it.
  func lastWait(_ session: JSON) throws -> JSON {
    try #require(session["waits"]?.array?.last, Comment(rawValue: session.text))
  }

  /// The operator's last wait.
  func operatorsLastWait(_ sbd: Instance) throws -> Wait {
    try #require(try theOperator(sbd).waits.last)
  }

  /// Expects `r` to be refused as an arm by a caller that may not arm, with no wait stored.
  func expectRefused(_ r: CommandResult, _ sbd: Instance, sourceLocation: SourceLocation = #_sourceLocation) throws {
    #expect(r.status != 0, Comment(rawValue: r.stdout), sourceLocation: sourceLocation)
    #expect(r.stderr.contains(Self.refusal), Comment(rawValue: r.stderr), sourceLocation: sourceLocation)
    #expect(try noWaits(sbd), sourceLocation: sourceLocation)
  }

  /// The environment assignments for a command in a pane: CLAUDECODE as Claude Code sets it, then `env`.
  func paneEnv(_ env: [String: String]) -> [String] {
    ["CLAUDECODE": "1"].merging(env) { $1 }.sorted { $0.key < $1.key }.map { "\($0.key)=\(shellQuote($0.value))" }
  }

  // MARK: Running sb inside a pane

  /// Runs the script that `writeScript` wrote as a tool call of `owner`'s claude, so the script descends from the
  /// owner's Claude pane, and returns its result. A tick first installs a snapshot that holds the pane's pid.
  func runInPane(_ sbd: Instance, of owner: SessionSummary, _ name: String) throws -> CommandResult {
    try sbd.waitFor(owner.id, "claude's pid") { $0.claudePid != nil }
    try sbd.advanceClock(1)
    if owner.kind == .operator {
      try sbd.sb("operator", "run \(name)")
    } else {
      try sbd.sb("send", owner.id, "run \(name)")
    }
    return try sbd.scriptResult(name)
  }

  /// Runs sb with `args` in `owner`'s Claude pane, with CLAUDECODE set as Claude Code sets it. The pane sets
  /// SB_SESSION_ID to the owner's id. `env` overrides it, as an injected command could.
  func sbInPane(
    _ sbd: Instance, of owner: SessionSummary, _ args: [String], env: [String: String] = [:], name: String = "arm"
  ) throws -> CommandResult {
    let command = paneEnv(env) + [shellQuote("\(Instance.bin)/sb")] + args.map(shellQuote)
    try sbd.writeScript(name, command.joined(separator: " "))
    return try runInPane(sbd, of: owner, name)
  }

  /// Calls the MCP tool `set_wait` through an `sb mcp-server` that runs in `owner`'s Claude pane.
  func setWaitInPane(
    _ sbd: Instance, of owner: SessionSummary, _ arguments: [String: JSON], env: [String: String] = [:],
    name: String = "mcp-arm"
  ) throws -> ToolResult {
    try toolInPane(sbd, of: owner, "set_wait", arguments, env: env, name: name)
  }

  /// Calls the MCP tool through an `sb mcp-server` that runs in `owner`'s Claude pane, as the owner's claude starts
  /// it. `MCPClient` starts its server below the test runner, outside every pane, so it can't stand for a session's
  /// server here. The script pipes three JSON-RPC lines to the server, which answers each in order and exits at the
  /// end of its input. `env` overrides the pane's variables.
  func toolInPane(
    _ sbd: Instance, of owner: SessionSummary, _ tool: String, _ arguments: [String: JSON],
    env: [String: String] = [:], name: String
  ) throws -> ToolResult {
    let lines: [JSON] = [
      [
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": [
          "protocolVersion": "2025-06-18", "capabilities": [:],
          "clientInfo": ["name": "switchboard-tests", "version": "0"],
        ],
      ],
      ["jsonrpc": "2.0", "method": "notifications/initialized"],
      [
        "jsonrpc": "2.0", "id": 2, "method": "tools/call",
        "params": ["name": .string(tool), "arguments": .object(arguments)],
      ],
    ]
    let input = "printf '%s\\n' " + lines.map { shellQuote($0.text) }.joined(separator: " ")
    let server = (paneEnv(env) + [shellQuote("\(Instance.bin)/sb"), "mcp-server"]).joined(separator: " ")
    try sbd.writeScript(name, "\(input) | \(server)")
    let r = try runInPane(sbd, of: owner, name)
    let replies = r.stdout.split(separator: "\n").compactMap { JSON.parse(String($0)) }
    let reply = try #require(
      replies.first { $0["id"]?.int == 2 }, Comment(rawValue: "stdout: \(r.stdout)\nstderr: \(r.stderr)"))
    let result = try #require(reply["result"], Comment(rawValue: reply.text))
    return ToolResult(isError: result["isError"]?.bool ?? false, content: result["content"]?.array ?? [])
  }

  static func setWaitMerge(_ s: SessionSummary) -> [String: JSON] {
    ["kind": "session", "target": .string(s.id), "state": "ready_to_merge", "then": "merge", "note": .string(note)]
  }

  // MARK: Who may arm

  @Test func aConversationArmsMergeAndTheOperatorHoldsItWithHandedFrom() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let s = try notReadyTarget(github, sbd)
    let c = try conversation(sbd)

    let r = try sbInPane(sbd, of: c, ["wait", "--json"] + mergeArgs(s))

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    let op = try theOperator(sbd)
    #expect(try parse(r)["id"]?.string == op.id)
    #expect(op.waits.count == 1, "\(op.waits)")
    let wait = try operatorsLastWait(sbd)
    #expect(wait.action?.kind == .merge, "\(wait)")
    #expect(wait.then == .resume, "\(wait)")
    #expect(wait.session?.id == s.id, "\(wait)")
    #expect(wait.handedFrom?.id == c.id, "\(wait)")
    #expect(try sbd.get(c.id).waits.isEmpty)
  }

  @Test func theOperatorArmsMergeAndHoldsItItself() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let s = try notReadyTarget(github, sbd)
    let op = try operatorHelpers.idleOperator(sbd)

    let r = try sbInPane(sbd, of: op, ["wait", "--json"] + mergeArgs(s))

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    let wait = try #require(try sbd.get(op.id).waits.last)
    #expect(wait.action?.kind == .merge, "\(wait)")
    #expect(wait.handedFrom == nil, "\(wait)")
  }

  /// The user's terminal: no CLAUDECODE, no SB_SESSION_ID, and no session's pane above sb.
  @Test func theUserArmsMergeFromATerminal() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let s = try notReadyTarget(github, sbd)
    let c = try conversation(sbd)

    let r = try sbd.run(["wait", "--json", c.id] + mergeArgs(s))

    #expect(r.status == 0, Comment(rawValue: r.stderr))
    let wait = try operatorsLastWait(sbd)
    #expect(wait.action?.kind == .merge, "\(wait)")
    #expect(wait.by == .you, "\(wait)")
    #expect(wait.handedFrom?.id == c.id, "\(wait)")
  }

  /// A work session's Claude may not arm any action, for itself or for another session.
  @Test(arguments: [
    ["--state", "ready_to_merge", "--then", "merge"], ["--state", "done", "--then", "rm-worktree"],
    ["--state", "done", "--then", "rm"], ["--state", "needs_you", "--then", "report", "--note", "tell the user"],
  ])
  func aWorkSessionCannotArmAnAction(_ shape: [String]) throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let s = try notReadyTarget(github, sbd)
    let worker = try sbd.idleSession(name: "worker")

    let r = try sbInPane(sbd, of: worker, ["wait", "--json", "--kind", "session", "--target", s.id] + shape)

    try expectRefused(r, sbd)
  }

  @Test func theWorkSessionRefusalNamesMerge() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let s = try notReadyTarget(github, sbd)
    let worker = try sbd.idleSession(name: "worker")

    let r = try sbInPane(sbd, of: worker, ["wait", "--json"] + mergeArgs(s))

    #expect(r.stderr.contains(Self.mergeRefusal), Comment(rawValue: r.stderr))
  }

  /// `callerArg` reads SB_SESSION_ID, which a work session can set to a conversation's id. Only the ancestry counts.
  @Test func aWorkSessionThatSetsAConversationsIdCannotArmMerge() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let s = try notReadyTarget(github, sbd)
    let c = try conversation(sbd)
    let worker = try sbd.idleSession(name: "worker")

    let r = try sbInPane(sbd, of: worker, ["wait", "--json"] + mergeArgs(s), env: ["SB_SESSION_ID": c.id])

    try expectRefused(r, sbd)
  }

  /// The same spoof, naming the conversation as the waiter in place of SB_SESSION_ID. The wait would go to the
  /// Operator, and sbd refuses it before it creates the Operator.
  @Test func aWorkSessionThatNamesAConversationCannotArmMerge() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let s = try notReadyTarget(github, sbd)
    let c = try conversation(sbd)
    let worker = try sbd.idleSession(name: "worker")
    try #require(try handoff.operators(sbd).isEmpty)

    let r = try sbInPane(sbd, of: worker, ["wait", "--json", c.id] + mergeArgs(s))

    try expectRefused(r, sbd)
    #expect(try handoff.operators(sbd).isEmpty)
  }

  /// The session whose PR would merge asks for its own merge, with a conversation as the waiter, so makeWait's
  /// check that a session can't wait on itself does not apply. The caller check or the rule that a session never
  /// arms a merge on itself must refuse it.
  @Test func aSessionCannotArmMergeOnItself() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let s = try notReadyTarget(github, sbd)
    let c = try conversation(sbd)

    let r = try sbInPane(sbd, of: s, ["wait", "--json", c.id] + mergeArgs(s))

    #expect(r.status != 0, Comment(rawValue: r.stdout))
    #expect(r.stderr.contains(Self.refusal) || r.stderr.contains("itself"), Comment(rawValue: r.stderr))
    #expect(try noWaits(sbd))
  }

  /// Outside every pane, a caller that names a work session, or no session sbd has, is refused too.
  @Test(arguments: [true, false])
  func aCallerThatIsNotAConversationCannotArmFromOutsideEveryPane(_ namesWorker: Bool) throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let s = try notReadyTarget(github, sbd)
    let c = try conversation(sbd)
    let worker = try sbd.idleSession(name: "worker")

    let r = try sbd.run(
      ["wait", c.id] + mergeArgs(s), env: ["SB_SESSION_ID": namesWorker ? worker.id : "zzzzz"])

    try expectRefused(r, sbd)
  }

  /// A session that runs `tmux new-session` starts sb below sbd's tmux server, outside every pane, and without
  /// SB_SESSION_ID, so neither the pane nor the caller names the session.
  @Test func aWindowThatASessionOpenedCannotArmAnAction() throws {
    let sbd = try Instance()
    let kid = try sbd.idleSession(name: "kid")
    let c = try conversation(sbd)
    let terminals = try sbd.client.terminals(kid.id)
    let args = ["wait", c.id, "--kind", "session", "--target", kid.id, "--state", "done", "--then", "rm"]
    try sbd.writeScript(
      "opened-arm", ([shellQuote("\(Instance.bin)/sb")] + args.map(shellQuote)).joined(separator: " "))

    let opened = try runCommand(
      terminals.tmux,
      [
        "-S", terminals.socket, "new-session", "-d", "-s", "opened-by-a-session", "-e", "SB_HOME=\(sbd.home.path)",
        "sh \"$SB_HOME/opened-arm.sh\"",
      ])
    try #require(opened.status == 0, "\(opened.stderr)")
    let r = try sbd.scriptResult("opened-arm")

    try expectRefused(r, sbd)
    #expect(r.stderr.contains("tmux server"), Comment(rawValue: r.stderr))
  }

  /// Actions run only on this Mac, so sbd refuses one on a session on a host, even from the user.
  @Test func anActionOnASessionOnAHostIsRefused() throws {
    let sbd = try Instance.remote()
    let mini = try sbd.startOnHost()
    let c = try conversation(sbd)

    let r = try sbd.run(["wait", c.id, "--kind", "session", "--target", mini.id, "--state", "done", "--then", "rm"])

    #expect(r.status != 0, Comment(rawValue: r.stdout))
    #expect(r.stderr.contains("runs on mini"), Comment(rawValue: r.stderr))
    #expect(try noWaits(sbd))
  }

  // MARK: What merge needs at set time

  /// sbd merges only in the repositories that `operator.mergeRepos` lists. The default lists none.
  @Test(arguments: [nil, [], ["PostHog/posthog"]] as [[String]?])
  func mergeInAnUnlistedRepositoryIsRefusedNamingTheKey(_ mergeRepos: [String]?) throws {
    let github = try FakeGitHub()
    let sbd = try instance(github, mergeRepos: mergeRepos)
    let s = try notReadyTarget(github, sbd)
    let c = try conversation(sbd)

    try #require(try handoff.operators(sbd).isEmpty)

    let r = try sbd.run(["wait", "--json", c.id] + mergeArgs(s))

    #expect(r.status != 0, Comment(rawValue: r.stdout))
    #expect(r.stderr.contains("operator.mergeRepos"), Comment(rawValue: r.stderr))
    #expect(try noWaits(sbd))
    #expect(try handoff.operators(sbd).isEmpty)
  }

  /// The allowlist matches the repository with any case, as `Dependencies.sameRepo` does.
  @Test func mergeReposMatchesTheRepositoryWithAnyCase() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github, mergeRepos: [Self.charts.lowercased()])
    let s = try notReadyTarget(github, sbd)
    let c = try conversation(sbd)

    let r = try sbd.run(["wait", "--json", c.id] + mergeArgs(s))

    #expect(r.status == 0, Comment(rawValue: r.stderr))
  }

  /// The session is in an allowed repository on a branch with no PR, so only the PR check can refuse.
  @Test func mergeOnASessionWithNoPRIsRefused() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let s = try sbd.session(in: Self.charts, branch: "haacked/no-pr-yet", name: "no-pr")
    try sbd.poll()
    let c = try conversation(sbd)

    let r = try sbd.run(["wait", "--json", c.id] + mergeArgs(s))

    #expect(r.status != 0, Comment(rawValue: r.stdout))
    #expect(r.stderr.contains("has no PR yet"), Comment(rawValue: r.stderr))
    #expect(try noWaits(sbd))
  }

  // MARK: The wire and the CLI

  @Test func anArmedActionShowsInSbWaitSbGetAndTheWaitEvent() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let s = try notReadyTarget(github, sbd)
    let c = try conversation(sbd)

    let printed = try #require(JSON.parse(try sbd.sb(["wait", "--json", c.id] + mergeArgs(s))))

    let op = try theOperator(sbd)
    #expect(try lastWait(printed)["action"]?["kind"]?.string == "merge", Comment(rawValue: printed.text))
    let stored = try lastWait(try sbd.getJSON(op.id))
    #expect(stored["action"]?["kind"]?.string == "merge", Comment(rawValue: stored.text))
    let id = try #require(op.waits.last?.id)
    let event = try #require(try handoff.waitEvent(sbd, op.id, "wait", wait: id))
    #expect(event.data["wait"]?["action"]?["kind"]?.string == "merge", Comment(rawValue: event.data.text))
  }

  @Test func theCLISaysSbdMergesAndListsTheAction() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let s = try notReadyTarget(github, sbd)
    let c = try conversation(sbd)

    let printed = try sbd.sb(["wait", c.id] + mergeArgs(s))

    #expect(printed.contains("sbd merges this when it's ready"), Comment(rawValue: printed))
    let op = try theOperator(sbd)
    let listed = try sbd.sb("get", op.id)
    #expect(listed.contains("then merge"), Comment(rawValue: listed))
  }

  @Test func needsYouOnAReportShowsInTheStoredAction() throws {
    let sbd = try Instance()
    let kid = try sbd.idleSession(name: "kid")
    let c = try conversation(sbd)

    let printed = try #require(
      JSON.parse(
        try sbd.sb(
          "wait", "--json", c.id, "--kind", "session", "--target", kid.id, "--state", "done", "--then", "report",
          "--note", "tell the user to run bin/update", "--needs-you")))

    let action = try lastWait(printed)["action"]
    #expect(action?["kind"]?.string == "report", Comment(rawValue: printed.text))
    #expect(action?["needsYou"]?.bool == true, Comment(rawValue: printed.text))
  }

  @Test func needsYouOnAMergeIsRefused() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let s = try notReadyTarget(github, sbd)
    let c = try conversation(sbd)

    let r = try sbd.run(["wait", "--json", c.id] + mergeArgs(s) + ["--needs-you"])

    #expect(r.status != 0, Comment(rawValue: r.stdout))
    #expect(r.stderr.contains("report"), Comment(rawValue: r.stderr))
    #expect(try noWaits(sbd))
  }

  // MARK: MCP set_wait

  @Test func setWaitFromAConversationArmsMergeOnTheOperator() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let s = try notReadyTarget(github, sbd)
    let c = try conversation(sbd)

    let result = try setWaitInPane(sbd, of: c, Self.setWaitMerge(s))

    #expect(!result.isError, Comment(rawValue: result.text))
    let op = try theOperator(sbd)
    let answer = try #require(result.json, Comment(rawValue: result.text))
    #expect(answer["id"]?.string == op.id, Comment(rawValue: answer.text))
    let wait = try operatorsLastWait(sbd)
    #expect(wait.action?.kind == .merge, "\(wait)")
    #expect(wait.by == .claude, "\(wait)")
    #expect(wait.handedFrom?.id == c.id, "\(wait)")
  }

  /// The work session's own server, naming a conversation as the waiter, and one started with SB_SESSION_ID set to
  /// the conversation's id.
  @Test(arguments: [false, true])
  func setWaitFromAWorkSessionsMCPServerCannotArmMerge(_ claimsConversation: Bool) throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let s = try notReadyTarget(github, sbd)
    let c = try conversation(sbd)
    let worker = try sbd.idleSession(name: "worker")
    var args = Self.setWaitMerge(s)
    if !claimsConversation { args["session"] = .string(c.id) }

    let result = try setWaitInPane(
      sbd, of: worker, args, env: claimsConversation ? ["SB_SESSION_ID": c.id] : [:])

    #expect(result.isError, Comment(rawValue: result.text))
    #expect(result.text.contains(Self.refusal), Comment(rawValue: result.text))
    #expect(try noWaits(sbd))
  }

  @Test func setWaitTakesNeedsYouOnAReport() throws {
    let sbd = try Instance()
    let kid = try sbd.idleSession(name: "kid")
    let c = try conversation(sbd)
    let mcp = try MCPClient(sbd)

    let result = try mcp.call(
      "set_wait",
      [
        "session": .string(c.id), "kind": "session", "target": .string(kid.id), "state": "done", "then": "report",
        "note": "tell the user to run bin/update", "needsYou": true,
      ])

    #expect(!result.isError, Comment(rawValue: result.text))
    let action = try lastWait(try #require(result.json, Comment(rawValue: result.text)))["action"]
    #expect(action?["kind"]?.string == "report", Comment(rawValue: result.text))
    #expect(action?["needsYou"]?.bool == true, Comment(rawValue: result.text))
  }

  @Test func setWaitsSchemaListsTheActionsAndTakesNeedsYou() throws {
    let sbd = try Instance()
    let mcp = try MCPClient(sbd)

    let tool = try #require(try mcp.tools().first { $0["name"]?.string == "set_wait" })

    let properties = try #require(tool["inputSchema"]?["properties"]?.object)
    #expect(properties["needsYou"]?["type"]?.string == "boolean")
    let then = properties["then"]?["description"]?.string ?? ""
    for value in ["merge", "rm-worktree", "rm", "report"] { #expect(then.contains(value), Comment(rawValue: then)) }
  }

  // MARK: rm-worktree on a merge wait

  /// The subject is the session with that open PR when the wait is set. rm-worktree needs no allowlist.
  @Test func rmWorktreeOnAMergeWaitStoresTheSessionWithThatOpenPR() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github, mergeRepos: nil)
    let s = try notReadyTarget(github, sbd)
    let c = try conversation(sbd)

    let printed = try #require(
      JSON.parse(
        try sbd.sb(
          "wait", "--json", c.id, "--kind", "merge", "--target", "\(Self.charts)#\(MergeTests.number)", "--then",
          "rm-worktree")))

    let op = try theOperator(sbd)
    let wait = try operatorsLastWait(sbd)
    #expect(wait.action?.kind == .rmWorktree, "\(wait)")
    #expect(wait.subject?.id == s.id, "\(wait)")
    #expect(wait.subject?.name == s.name, "\(wait)")
    #expect(try lastWait(printed)["subject"]?["id"]?.string == s.id, Comment(rawValue: printed.text))
    let id = try #require(op.waits.last?.id)
    let event = try #require(try handoff.waitEvent(sbd, op.id, "wait", wait: id))
    #expect(event.data["wait"]?["subject"]?["id"]?.string == s.id, Comment(rawValue: event.data.text))
  }

  @Test func rmWorktreeOnAMergeWaitWithNoSessionOnThatPRIsRefused() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    _ = try notReadyTarget(github, sbd)
    let c = try conversation(sbd)

    let r = try sbd.run([
      "wait", "--json", c.id, "--kind", "merge", "--target", "\(Self.charts)#99999", "--then", "rm-worktree",
    ])

    #expect(r.status != 0, Comment(rawValue: r.stdout))
    #expect(r.stderr.contains("#99999"), Comment(rawValue: r.stderr))
    #expect(try noWaits(sbd))
  }

  /// `sessionByPR` matches only open PRs, so a session whose PR already merged is no subject.
  @Test func rmWorktreeOnAMergeWaitWhosePRMergedIsRefused() throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    github.change(MergeTests.number) {
      $0["state"] = "MERGED"
      $0["mergedAt"] = "2026-10-26T00:00:00Z"
    }
    let s = try sbd.session(in: Self.charts, branch: MergeTests.branch, name: Self.target)
    try sbd.poll()
    try sbd.waitFor(s.id, "the poller's read of the merged PR") { $0.pr?.number == MergeTests.number }
    let c = try conversation(sbd)

    let r = try sbd.run([
      "wait", "--json", c.id, "--kind", "merge", "--target", "\(Self.charts)#\(MergeTests.number)", "--then",
      "rm-worktree",
    ])

    #expect(r.status != 0, Comment(rawValue: r.stdout))
    #expect(r.stderr.contains("#\(MergeTests.number)"), Comment(rawValue: r.stderr))
    #expect(try noWaits(sbd))
  }

  // MARK: A card's wait option

  /// A card with a send option and a wait option on `target`, with `then` when it is set.
  static func cardWaitingOn(_ target: SessionSummary, then: String? = nil) -> String {
    var wait: [String: JSON] = ["kind": "session", "target": .string(target.id), "state": "done"]
    if let then { wait["then"] = .string(then) }
    return JSON.object([
      "summary": "It finished.",
      "options": [
        ["label": "Go on", "action": "send"], ["label": "Wait for kid", "action": "wait", "wait": .object(wait)],
      ],
    ]).text
  }

  /// `choose` sets a card's wait from inside sbd, where `armAction` can't see who wrote the card. So the work session
  /// writes the card in its own pane, the option is dropped, and the user's click has nothing to arm.
  @Test func aWorkSessionsCardCannotOfferAWaitThatArmsAnAction() throws {
    let sbd = try Instance()
    let kid = try sbd.idleSession(name: "kid")
    let worker = try sbd.idleSession(name: "worker")
    try sbd.writeCard("c1", Self.cardWaitingOn(kid, then: "rm"))
    try sbd.writeScript(
      "card", "CLAUDECODE=1 \(shellQuote("\(Instance.bin)/sb")) summary set <\"$SB_HOME/c1.json\"")

    let written = try runInPane(sbd, of: worker, "card")

    #expect(written.status == 0, Comment(rawValue: written.stderr))
    #expect(written.stdout.contains("can't take then rm"), Comment(rawValue: written.stdout))
    let item = try #require(
      try sbd.waitFor(worker.id, "the worker's card") { $0.triage?.source == .session }.triage)
    #expect(item.options.map(\.label) == ["Go on"])
    let r = try sbd.run(["choose", worker.id, "Wait for kid"])
    #expect(r.status != 0, Comment(rawValue: r.stdout))
    #expect(try noWaits(sbd))
  }

  /// A card that sbd stored before the check in `TriageCard.clean` still can't arm an action through `sb choose`.
  /// The test plants such a card in the store while sbd is stopped. `rm` needs no PR and no allowlist, so only the
  /// check in `choose` refuses it.
  @Test func aStoredCardsWaitOptionThatArmsAnActionCannotArmIt() throws {
    let sbd = try Instance()
    let kid = try sbd.idleSession(name: "kid")
    try sbd.writeCard("c1", Self.cardWaitingOn(kid))
    let worker = try sbd.new(prompt: "card c1", name: "worker")
    try sbd.waitFor(worker.id, "the worker's card") { $0.triage?.options.contains { $0.action == .wait } == true }
    let stored = try #require(try sbd.events(worker.id).last { $0.kind == Triage.sessionEvent })
    var card = try JSONCoding.convert(stored.data, to: TriageSummary.self)
    let index = try #require(card.options.firstIndex { $0.action == .wait })
    card.options[index].wait?.then = "rm"
    sbd.stopSbd()
    try Store(path: sbd.home.database).append(
      Event(session: worker.id, t: stored.t + 1, kind: Triage.sessionEvent, data: try JSON(encoding: card)))
    try sbd.startSbd()
    try sbd.waitFor(worker.id, "the planted card") {
      $0.triage?.options.contains { $0.wait?.then == "rm" } == true
    }

    let r = try sbd.run(["choose", worker.id, "Wait for kid"])

    #expect(r.status != 0, Comment(rawValue: r.stdout))
    #expect(r.stderr.contains("can't take then rm"), Comment(rawValue: r.stderr))
    #expect(try noWaits(sbd))
    #expect(try sbd.client.sessions().map(\.id).contains(kid.id))
  }

  /// Only the operator approves a merge, so a merge wait that would stay on another session is refused.
  @Test(arguments: [true, false])
  func aMergeWaitThatWouldNotLandOnTheOperatorIsRefused(_ here: Bool) throws {
    let github = try FakeGitHub()
    let sbd = try instance(github)
    let s = try notReadyTarget(github, sbd)
    let holder = here ? try conversation(sbd) : try sbd.idleSession(name: "worker")

    let r = try sbd.run(["wait", "--json", holder.id] + mergeArgs(s) + (here ? ["--here"] : []))

    #expect(r.status != 0, Comment(rawValue: r.stdout))
    #expect(r.stderr.contains("only the operator approves the merge"), Comment(rawValue: r.stderr))
    #expect(try sbd.get(holder.id).waits.isEmpty)
    #expect(try handoff.operators(sbd).isEmpty)
  }
}
