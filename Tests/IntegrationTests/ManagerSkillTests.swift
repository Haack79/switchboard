import Foundation
import SwitchboardCore
import Testing

/// A usage reading whose weekly limit is spent until 2099.
private let spentReading =
  #"{"limits":[{"kind":"weekly_all","percent":100,"resets_at":"2099-01-01T00:00:00+00:00"}]}"#

/// sbd finds the skills that a Manager conversation's or the operator's account can load, labels each one `work` or
/// `safe` through `claude -p --model haiku`, and caches the label in `skill-labels.json` by a hash of the file.
/// `sb manager skills --json` answers an array of rows `{name, origin, path?, label?, by?, reason?, error?, pending}`.
///
/// sbd scans an account at its own start, at a manager-kind SessionStart, on `relabel`, and on a manager-kind
/// prompt or Skill call at most once a minute. So each test writes its skill files before one of those. The stub answers a classification by the markers in the skill's
/// text, and it logs one line per call with the skill's name to `skill-classify-calls.log`. A test that expects no
/// new call writes a new skill before the refresh and waits for that skill's label, which shows that the refresh ran.
@Suite(.blocking(timeLimit: .seconds(180))) struct ManagerSkillTests: ManagerSkillSuite {
  // MARK: Labels

  @Test func userSkillComesOutWorkByHaiku() throws {
    let sbd = try instance()
    try writeSkill(sbd.account("A"), "go")

    let c = try newConversation(sbd)

    #expect(c.account == sbd.account("A"))
    let go = try waitForLabel(sbd, "go", "work")
    #expect(go["by"]?.string == "haiku")
    #expect(go["origin"]?.string == "user")
    #expect(go["path"]?.string == "\(sbd.account("A"))/skills/go/SKILL.md")
    #expect(go["reason"]?.string == "It runs a pipeline.")
    #expect(go["pending"]?.bool == false)
    #expect(calls(sbd) == ["go"])
  }

  @Test func classificationRunUsesHaikuAndTheSkillAsData() throws {
    let sbd = try instance()
    try writeSkill(sbd.account("A"), "go")

    try newConversation(sbd)

    try waitForLabel(sbd, "go", "work")
    #expect(value("--model", try classifyArguments(sbd)) == "haiku")
    let input = try String(contentsOfFile: "\(sbd.home.path)/skill-classify-input.txt", encoding: .utf8)
    #expect(input.contains("<skill-name>go</skill-name>"), "\(input)")
    #expect(input.contains("<skill-file>\n---\nname: go\n"), "\(input)")
    #expect(input.contains("Run the pipeline."), "\(input)")
  }

  @Test func labelSafeSkillComesOutSafe() throws {
    let sbd = try instance()
    try writeSkill(sbd.account("A"), "notes", "Append to the notes file. LABEL-SAFE")

    try newConversation(sbd)

    let notes = try waitForLabel(sbd, "notes", "safe")
    #expect(notes["by"]?.string == "haiku")
    #expect(notes["reason"]?.string == "It reads notes.")
  }

  @Test func cwdSkillOfTheManagerFolderIsLabeled() throws {
    let sbd = try instance()
    try writeSkill("\(sbd.home.managerFolder)/.claude", "deploy")

    try newConversation(sbd)

    let deploy = try waitForLabel(sbd, "deploy", "work")
    #expect(deploy["origin"]?.string == "project")
  }

  @Test func listingOnlyBundledSkillIsLabeledFromItsDescription() throws {
    let sbd = try instance()
    try FileManager.default.copyItem(
      atPath: SlashCommandTests.fixtures.appendingPathComponent("manager-launches.jsonl").path,
      toPath: "\(sbd.home.path)/skill-listing.jsonl")
    let c = try newConversation(sbd)
    // The stub writes the listing into the transcript before the first prompt.
    try sbd.sb("send", c.id, "hello")
    try sbd.waitFor(c.id, "the reply to hello", timeout: 30) { $0.lastReply == "Done: hello" }

    try sbd.sb("manager", "skills", "relabel")

    let review = try waitForLabel(sbd, "code-review", "work")
    #expect(review["origin"]?.string == "listing")
    #expect(review["path"]?.string == nil)
  }

  @Test func plainOutputPrintsTheLabelNameOriginAndWhy() throws {
    let sbd = try instance()
    try writeSkill(sbd.account("A"), "go")
    try writeSkill(sbd.account("A"), "flaky", "FAIL-SKILL")
    try newConversation(sbd)
    try waitForLabel(sbd, "go", "work")
    try waitForError(sbd, "flaky")

    let lines = try sbd.sb("manager", "skills").split(separator: "\n").map(String.init)

    #expect(lines.contains("work  go  user  haiku: It runs a pipeline."), "\(lines)")
    #expect(lines.contains { $0.hasPrefix("-  flaky  user  ") }, "\(lines)")
  }

  // MARK: Config overrides

  @Test func configOverridesShowByConfigAndNeverReachTheClassifier() throws {
    let sbd = try instance(config: ["managerSkills": ["work": ["code-review", "memo"], "safe": ["/go"]]])
    try writeSkill(sbd.account("A"), "go")
    try writeSkill(sbd.account("A"), "memo", "Append to the notes file. LABEL-SAFE")
    try writeSkill(sbd.account("A"), "other")

    try newConversation(sbd)

    try waitForLabel(sbd, "other", "work")
    let rows = try skills(sbd)
    #expect(row("go", rows)?["label"]?.string == "safe")
    #expect(row("go", rows)?["by"]?.string == "config")
    #expect(row("memo", rows)?["label"]?.string == "work")
    #expect(row("memo", rows)?["by"]?.string == "config")
    #expect(row("code-review", rows)?["label"]?.string == "work")
    #expect(row("code-review", rows)?["origin"]?.string == "config")
    #expect(calls(sbd) == ["other"])
  }

  // MARK: Cost

  /// The edited file has a new cache key. Its run fails, so a `work` label that carried over from the old key by name
  /// would show here.
  @Test func editedFileIsClassifiedAgainWithoutItsOldLabel() throws {
    let sbd = try instance()
    try writeSkill(sbd.account("A"), "go")
    try newConversation(sbd)
    try waitForLabel(sbd, "go", "work")
    try writeSkill(sbd.account("A"), "go", "Run the pipeline. FAIL-SKILL")

    sbd.stopSbd()
    try sbd.startSbd()

    let go = try waitForError(sbd, "go")
    #expect(go["label"]?.string == nil)
    #expect(calls(sbd, "go") == 2)
  }

  @Test func restartWithUnchangedFilesMakesNoNewCall() throws {
    let sbd = try instance()
    try writeSkill(sbd.account("A"), "go")
    try newConversation(sbd)
    try waitForLabel(sbd, "go", "work")
    try writeSkill(sbd.account("A"), "other")

    sbd.stopSbd()
    try sbd.startSbd()

    try waitForLabel(sbd, "other", "work")
    #expect(calls(sbd, "go") == 1)
    #expect(try waitForLabel(sbd, "go", "work")["by"]?.string == "haiku")
  }

  @Test func secondConversationWithUnchangedFilesMakesNoNewCall() throws {
    let sbd = try instance()
    try writeSkill(sbd.account("A"), "go")
    try newConversation(sbd)
    try waitForLabel(sbd, "go", "work")
    try writeSkill(sbd.account("A"), "other")

    try newConversation(sbd)

    try waitForLabel(sbd, "other", "work")
    #expect(calls(sbd, "go") == 1)
  }

  @Test func noSkillsMeansNoClassificationRun() throws {
    let sbd = try instance()
    let c = try newConversation(sbd)
    try sbd.sb("send", c.id, "hello")
    try sbd.waitFor(c.id, "the reply to hello", timeout: 30) { $0.lastReply == "Done: hello" }

    try stays("no classification call") { calls(sbd).isEmpty }

    #expect(try skills(sbd).isEmpty)
  }

  @Test func workSessionAloneStartsNoClassificationRun() throws {
    let sbd = try instance()
    try writeSkill(sbd.account("A"), "go")
    let s = try sbd.new(prompt: "hello")
    try sbd.waitFor(s.id, "the reply to hello", timeout: 30) { $0.lastReply == "Done: hello" }

    try stays("no classification call") { calls(sbd).isEmpty }

    #expect(try skills(sbd).isEmpty)
  }

  @Test func operatorsAccountIsLabeled() throws {
    let sbd = try instance()
    try writeSkill(sbd.account("A"), "go")

    let op = try decode(SessionSummary.self, sbd.sb("operator", "--json"))
    try sbd.waitFor(op.id, "the operator's claude") { $0.live }

    try waitForLabel(sbd, "go", "work")
    #expect(calls(sbd) == ["go"])
  }

  @Test func sameFileInTwoAccountsSharesOneLabel() throws {
    let sbd = try Instance(accounts: ["A", "B"], inheriting: .unset)
    try sbd.sb("account", "use", "A")
    try writeSkill(sbd.account("A"), "shared")
    try writeSkill(sbd.account("B"), "shared")
    try writeSkill(sbd.account("A"), "a-only")
    try writeSkill(sbd.account("B"), "b-only", "Append to the notes file. LABEL-SAFE")
    let onA = try newConversation(sbd)
    try waitForLabel(sbd, "a-only", "work", conversation: onA.id)
    try waitForLabel(sbd, "shared", "work", conversation: onA.id)
    try sbd.sb("account", "use", "B", "--new-only")

    let onB = try newConversation(sbd)

    #expect(onB.account == sbd.account("B"))
    try waitForLabel(sbd, "b-only", "safe", conversation: onB.id)
    try waitForLabel(sbd, "shared", "work", conversation: onB.id)
    #expect(calls(sbd, "shared") == 1)
    #expect(Set(try skills(sbd, onA.id).compactMap { $0["name"]?.string }) == ["shared", "a-only"])
    #expect(Set(try skills(sbd, onB.id).compactMap { $0["name"]?.string }) == ["shared", "b-only"])

    // The run uses the account of the conversation that loads the skill, not the account that new sessions use.
    try sbd.sb("account", "use", "A", "--new-only")
    try sbd.sb("manager", "skills", "relabel", "b-only")
    try sbd.waitFor("a second run of b-only", timeout: 30) { calls(sbd, "b-only") == 2 }
    let account = try String(contentsOfFile: "\(sbd.home.path)/skill-classify-account", encoding: .utf8)
    #expect(account == sbd.account("B"))
  }

  // MARK: Failures and backoff

  @Test func failedRunShowsAnErrorAndIsNotRetriedRightAway() throws {
    let sbd = try instance()
    try writeSkill(sbd.account("A"), "flaky", "FAIL-SKILL")
    try newConversation(sbd)
    let flaky = try waitForError(sbd, "flaky")
    #expect(flaky["label"]?.string == nil)
    try writeSkill(sbd.account("A"), "other")

    try newConversation(sbd)

    try waitForLabel(sbd, "other", "work")
    #expect(calls(sbd, "flaky") == 1)
  }

  @Test func failedRunIsRetriedFifteenMinutesLater() throws {
    let sbd = try instance(idleStopSeconds: 3600)
    try writeSkill(sbd.account("A"), "flaky", "FAIL-SKILL")
    try newConversation(sbd)
    try waitForError(sbd, "flaky")

    try sbd.advanceClock(15 * 60_000 + 1000)
    try newConversation(sbd)

    try sbd.waitFor("a second run of flaky", timeout: 30) { calls(sbd, "flaky") == 2 }
  }

  @Test func relabelOfOneNameMakesExactlyOneNewCall() throws {
    let sbd = try instance()
    try writeSkill(sbd.account("A"), "go")
    try writeSkill(sbd.account("A"), "notes", "Append to the notes file. LABEL-SAFE")
    try newConversation(sbd)
    try waitForLabel(sbd, "go", "work")
    try waitForLabel(sbd, "notes", "safe")

    let answer = try #require(JSON.parse(try sbd.sb("manager", "skills", "relabel", "go", "--json"))?.array)

    #expect(row("go", answer)?["pending"]?.bool == true)
    try sbd.waitFor("a second run of go", timeout: 30) { calls(sbd, "go") == 2 }
    try waitForLabel(sbd, "go", "work")
    #expect(calls(sbd, "notes") == 1)
  }

  /// `relabel` scans the folders before it matches the names, so it finds a skill written after the Manager started.
  @Test func relabelOfASkillWrittenAfterTheManagerStartedLabelsIt() throws {
    let sbd = try instance()
    try writeSkill(sbd.account("A"), "go")
    try newConversation(sbd)
    try waitForLabel(sbd, "go", "work")
    try writeSkill(sbd.account("A"), "late")

    let answer = try #require(JSON.parse(try sbd.sb("manager", "skills", "relabel", "late", "--json"))?.array)

    #expect(row("late", answer) != nil)
    try waitForLabel(sbd, "late", "work")
    #expect(calls(sbd, "late") == 1)
    #expect(calls(sbd, "go") == 1)
  }

  @Test func relabelWithoutNamesQueuesEverySkill() throws {
    let sbd = try instance()
    try writeSkill(sbd.account("A"), "go")
    try writeSkill(sbd.account("A"), "notes", "Append to the notes file. LABEL-SAFE")
    try newConversation(sbd)
    try waitForLabel(sbd, "go", "work")
    try waitForLabel(sbd, "notes", "safe")

    try sbd.sb("manager", "skills", "relabel")

    try sbd.waitFor("a second run of each skill", timeout: 30) {
      calls(sbd, "go") == 2 && calls(sbd, "notes") == 2
    }
  }

  @Test func relabelOfAnUnknownNameIsRefused() throws {
    let sbd = try instance()
    try writeSkill(sbd.account("A"), "go")
    try newConversation(sbd)
    try waitForLabel(sbd, "go", "work")

    let result = try sbd.run("manager", "skills", "relabel", "nope")

    #expect(result.status != 0)
    #expect(result.stderr.contains("no skill named nope"), "\(result.stderr)")
    #expect(calls(sbd, "go") == 1)
  }

  /// The run reads the file again and saves the label under the hash of the text it read. A file edited while its
  /// run waits gets a label for its new text, so a later scan of that text makes no new call.
  @Test func fileEditedWhileItsRunWaitsIsLabeledForItsNewText() throws {
    let sbd = try instance(config: ["managerSkills": ["timeoutSeconds": 10]])
    try writeSkill(sbd.account("A"), "a-slow", "SLOW-SKILL")
    try writeSkill(sbd.account("A"), "go")
    try newConversation(sbd)
    try sbd.waitFor("the slow run", timeout: 30) { calls(sbd) == ["a-slow"] }

    try writeSkill(sbd.account("A"), "go", "Run the new pipeline.")

    try sbd.waitFor("go's label", timeout: 30) { try cachedWorkLabels(sbd) == 1 }
    let input = try String(contentsOfFile: "\(sbd.home.path)/skill-classify-input.txt", encoding: .utf8)
    #expect(input.contains("Run the new pipeline."), "\(input)")
    try newConversation(sbd)
    try waitForLabel(sbd, "go", "work")
    #expect(calls(sbd, "go") == 1)
  }

  @Test func relabelRetriesAFailureAtOnce() throws {
    let sbd = try instance()
    try writeSkill(sbd.account("A"), "flaky", "FAIL-SKILL")
    try newConversation(sbd)
    try waitForError(sbd, "flaky")

    try sbd.sb("manager", "skills", "relabel", "flaky")

    try sbd.waitFor("a second run of flaky", timeout: 30) { calls(sbd, "flaky") == 2 }
  }

  // MARK: Guard: no loop back into sbd

  @Test func classificationRunGetsNoSessionIdAndNoSettings() throws {
    let sbd = try instance()
    try writeSkill(sbd.account("A"), "go")

    try newConversation(sbd)

    try waitForLabel(sbd, "go", "work")
    let args = try classifyArguments(sbd)
    #expect(!args.contains("--settings"), "\(args)")
    #expect(value("--setting-sources", args) == "", "\(args)")
    #expect(value("--tools", args) == "", "\(args)")
    #expect(args.contains("--strict-mcp-config"), "\(args)")
    #expect(args.contains("--no-session-persistence"), "\(args)")
    #expect(args.contains("--disable-slash-commands"), "\(args)")
    #expect(try String(contentsOfFile: "\(sbd.home.path)/skill-classify-session", encoding: .utf8) == "unset")
  }

  // MARK: Guard: fail-open

  /// A run that fails, answers a label other than work or safe, or times out leaves the skill without a label.
  @Test(arguments: ["FAIL-SKILL", "BAD-SKILL", "SLOW-SKILL"])
  func failedRunLeavesNoLabel(_ marker: String) throws {
    let sbd = try instance(config: ["managerSkills": ["timeoutSeconds": 2]])
    try writeSkill(sbd.account("A"), "go", "Run the pipeline. \(marker)")

    try newConversation(sbd)

    let go = try waitForError(sbd, "go")
    #expect(go["label"]?.string == nil)
    #expect(calls(sbd, "go") == 1)
    #expect(try cachedWorkLabels(sbd) == 0)
  }

  @Test func signedOutAccountLeavesNoLabelWithoutARun() throws {
    let fake = try FakeUsage()
    let sbd = try Instance.withUsage(fake)
    _ = try sbd.usage()
    #expect(try sbd.usage(of: "A").signedOut == true)
    try writeSkill(sbd.account("A"), "go")

    try newConversation(sbd)

    let go = try waitForError(sbd, "go")
    #expect(go["label"]?.string == nil)
    #expect(calls(sbd).isEmpty)
    #expect(try cachedWorkLabels(sbd) == 0)
  }

  @Test func spentQuotaLeavesNoLabelWithoutARun() throws {
    let fake = try FakeUsage()
    fake.reply(spentReading)
    let sbd = try Instance.withUsage(fake)
    try sbd.signIn("A", token: "token-a")
    _ = try sbd.usage()
    #expect(try sbd.usage(of: "A").budget().isSpent)
    try writeSkill(sbd.account("A"), "go")

    try newConversation(sbd)

    let go = try waitForError(sbd, "go")
    #expect(go["label"]?.string == nil)
    #expect(calls(sbd).isEmpty)
    #expect(try cachedWorkLabels(sbd) == 0)
  }

  /// `skillJobs` runs one classification at a time, so while one run hangs, the other skill waits unlabeled.
  @Test func skillQueuedBehindARunningClassificationIsPendingWithoutALabel() throws {
    let sbd = try instance()
    try writeSkill(sbd.account("A"), "slow-a", "SLOW-SKILL")
    try writeSkill(sbd.account("A"), "slow-b", "SLOW-SKILL")

    try newConversation(sbd)

    try sbd.waitFor("the first run", timeout: 30) { calls(sbd).count == 1 }
    let queued = calls(sbd)[0] == "slow-a" ? "slow-b" : "slow-a"
    try stays("one run at a time") { calls(sbd).count == 1 }
    let waiting = try #require(row(queued, try skills(sbd)))
    #expect(waiting["pending"]?.bool == true)
    #expect(waiting["label"]?.string == nil)
    #expect(try cachedWorkLabels(sbd) == 0)
  }

  @Test func corruptCacheFileReadsAsEmptyAndIsReplaced() throws {
    let sbd = try Instance(accounts: ["A"], inheriting: .unset, startingSbd: false)
    try #"{"1/haiku/x": {"label": "work""#.write(
      toFile: "\(sbd.home.path)/skill-labels.json", atomically: true, encoding: .utf8)
    try sbd.startSbd()
    try sbd.sb("account", "use", "A")
    try writeSkill(sbd.account("A"), "go")
    try writeSkill(sbd.account("A"), "flaky", "FAIL-SKILL")

    try newConversation(sbd)

    try waitForLabel(sbd, "go", "work")
    #expect(try waitForError(sbd, "flaky")["label"]?.string == nil)
    let saved = try sbd.waitFor(
      "the saved label of go", fetch: { try cachedLabels(sbd) }, until: { $0.count == 1 })
    #expect(saved.values.first?["label"]?.string == "work")
  }
}
