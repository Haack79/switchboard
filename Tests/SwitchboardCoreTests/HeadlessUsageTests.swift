import Foundation
import Testing

@testable import SwitchboardCore

/// The envelope that `claude -p --output-format json --model haiku` printed on 2026-11-18, without its session id.
/// Real output ends in a newline.
private let capturedEnvelope = """
  {"type":"result","subtype":"success","is_error":false,"duration_api_ms":2047,"result":"{\\"a\\":\\"ok\\"}",\
  "structured_output":{"a":"ok"},"usage":{"input_tokens":2,"cache_creation_input_tokens":1126,\
  "cache_read_input_tokens":0,"output_tokens":124},"modelUsage":{"claude-haiku-5-5":{"inputTokens":2,\
  "outputTokens":124,"cacheReadInputTokens":0,"cacheCreationInputTokens":1126,"costUSD":0.0002874}}}

  """

/// A `modelUsage` value with the four counts.
private func modelCounts(input: Int, output: Int, cacheRead: Int, cacheWrite: Int) -> JSON {
  [
    "inputTokens": .number(Double(input)), "outputTokens": .number(Double(output)),
    "cacheReadInputTokens": .number(Double(cacheRead)), "cacheCreationInputTokens": .number(Double(cacheWrite)),
  ]
}

/// A top-level `usage` value with the four counts.
private func usageCounts(input: Int, output: Int, cacheRead: Int, cacheWrite: Int) -> JSON {
  [
    "input_tokens": .number(Double(input)), "output_tokens": .number(Double(output)),
    "cache_read_input_tokens": .number(Double(cacheRead)), "cache_creation_input_tokens": .number(Double(cacheWrite)),
  ]
}

/// An envelope with the fields, and `modelUsage` written with its keys in the order given.
private func envelope(isError: Bool = false, usage: JSON? = nil, modelUsage: [(String, JSON)] = []) -> String {
  var text = #"{"type":"result","subtype":"success","is_error":\#(isError),"result":"{\"a\":\"ok\"}""#
  if let usage { text += #","usage":\#(usage.text)"# }
  if !modelUsage.isEmpty {
    text +=
      #","modelUsage":{"# + modelUsage.map { "\(JSON.string($0.0).text):\($0.1.text)" }.joined(separator: ",") + "}"
  }
  return text + "}\n"
}

/// `Headless.reply`: the answer text, the model, and the token counts of one `claude -p` envelope.
@Suite struct HeadlessReplyTests {
  @Test func theCapturedEnvelopeGivesItsModel() {
    let reply = Headless.reply(capturedEnvelope)

    #expect(reply.model == "claude-haiku-5-5")
  }

  @Test func theCapturedEnvelopeGivesItsTokens() {
    let reply = Headless.reply(capturedEnvelope)

    #expect(reply.usage == HeadlessUsage(input: 2, output: 124, cacheRead: 0, cacheWrite: 1126))
  }

  /// The callers pass `output` to their existing `parse`, which reads the whole envelope.
  @Test func theOutputIsTheWholeEnvelopeUnchanged() {
    let reply = Headless.reply(capturedEnvelope)

    #expect(reply.output == capturedEnvelope)
  }

  @Test func oneModelUsageKeyGivesItsCountsOverTheTopLevelUsage() {
    let text = envelope(
      usage: usageCounts(input: 1, output: 1, cacheRead: 1, cacheWrite: 1),
      modelUsage: [("claude-haiku-5-5", modelCounts(input: 7, output: 11, cacheRead: 13, cacheWrite: 17))])

    let reply = Headless.reply(text)

    #expect(reply.model == "claude-haiku-5-5")
    #expect(reply.usage == HeadlessUsage(input: 7, output: 11, cacheRead: 13, cacheWrite: 17))
  }

  /// The keys come in reverse order, so a model that kept the envelope's order would read "sonnet+haiku".
  @Test func twoModelUsageKeysGiveTheSortedKeysJoinedWithAPlus() {
    let text = envelope(
      usage: usageCounts(input: 1, output: 1, cacheRead: 1, cacheWrite: 1),
      modelUsage: [
        ("claude-sonnet-5-5", modelCounts(input: 10, output: 20, cacheRead: 30, cacheWrite: 40)),
        ("claude-haiku-5-5", modelCounts(input: 1, output: 2, cacheRead: 3, cacheWrite: 4)),
      ])

    let reply = Headless.reply(text)

    #expect(reply.model == "claude-haiku-5-5+claude-sonnet-5-5")
  }

  /// The top-level `usage` differs from the sum, so a reply that read it would fail.
  @Test func twoModelUsageKeysGiveTheSumOfTheirTokens() {
    let text = envelope(
      usage: usageCounts(input: 1, output: 1, cacheRead: 1, cacheWrite: 1),
      modelUsage: [
        ("claude-sonnet-5-5", modelCounts(input: 10, output: 20, cacheRead: 30, cacheWrite: 40)),
        ("claude-haiku-5-5", modelCounts(input: 1, output: 2, cacheRead: 3, cacheWrite: 4)),
      ])

    let reply = Headless.reply(text)

    #expect(reply.usage == HeadlessUsage(input: 11, output: 22, cacheRead: 33, cacheWrite: 44))
  }

  @Test func noModelUsageGivesTheTokensOfTheTopLevelUsageAndNoModel() {
    let text = envelope(usage: usageCounts(input: 5, output: 6, cacheRead: 8, cacheWrite: 9))

    let reply = Headless.reply(text)

    #expect(reply.usage == HeadlessUsage(input: 5, output: 6, cacheRead: 8, cacheWrite: 9))
    #expect(reply.model == nil)
  }

  /// The two blocks of the captured envelope hold the same counts, so either block alone gives the same usage.
  @Test func theCapturedEnvelopeGivesTheSameTokensWithoutItsModelUsage() throws {
    var object = try #require(JSON.parse(capturedEnvelope)?.object)
    object["modelUsage"] = nil
    let usageOnly = JSON.object(object).text

    #expect(Headless.reply(usageOnly).usage == Headless.reply(capturedEnvelope).usage)
  }

  /// A call that failed after it ran still spent tokens.
  @Test(arguments: [
    envelope(isError: true, usage: usageCounts(input: 3, output: 0, cacheRead: 50, cacheWrite: 0)),
    envelope(
      isError: true, usage: usageCounts(input: 3, output: 0, cacheRead: 50, cacheWrite: 0),
      modelUsage: [("claude-haiku-5-5", modelCounts(input: 3, output: 0, cacheRead: 50, cacheWrite: 0))]),
  ])
  func anErrorEnvelopeStillGivesItsTokens(_ text: String) {
    let reply = Headless.reply(text)

    #expect(reply.usage == HeadlessUsage(input: 3, output: 0, cacheRead: 50, cacheWrite: 0))
  }

  @Test(arguments: ["", "claude crashed {", "Error: not logged in\n", "{\"usage\":"])
  func outputThatIsNotJSONGivesNoUsageAndNoModel(_ text: String) {
    let reply = Headless.reply(text)

    #expect(reply.usage == nil)
    #expect(reply.model == nil)
  }

  @Test(arguments: ["", "claude crashed {", "Error: not logged in\n", "{\"usage\":"])
  func outputThatIsNotJSONIsKeptVerbatim(_ text: String) {
    let reply = Headless.reply(text)

    #expect(reply.output == text)
  }
}

/// The `headless_calls` table: one row for each `claude -p` call that sbd launched.
@Suite struct HeadlessCallStoreTests {
  static let full = HeadlessCall(
    t: 1_000, kind: "triage", session: "s1", model: "haiku",
    usage: HeadlessUsage(input: 100, output: 20, cacheRead: 300, cacheWrite: 40))
  static let failed = HeadlessCall(t: 2_000, kind: "quickAsk", error: "claude exited with status 1: ask failed")

  @Test func appendReturnsTheCallWithAnId() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let store = try Store(path: "\(dir)/sb.db")

    let stored = try store.append(headlessCall: Self.full)

    #expect(stored.id != nil)
  }

  @Test func appendedCallsReadBackAfterTheStoreReopens() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    var stored: [HeadlessCall] = []
    do {
      let store = try Store(path: "\(dir)/sb.db")
      stored.append(try store.append(headlessCall: Self.full))
      stored.append(try store.append(headlessCall: Self.failed))
    }

    let calls = try Store(path: "\(dir)/sb.db").headlessCalls()

    #expect(calls == stored)
  }

  @Test func storedFieldsMatchWhatWasAppendedApartFromTheId() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let store = try Store(path: "\(dir)/sb.db")
    _ = try store.append(headlessCall: Self.full)
    _ = try store.append(headlessCall: Self.failed)

    let calls = try store.headlessCalls().map { call -> HeadlessCall in
      var call = call
      call.id = nil
      return call
    }

    #expect(calls == [Self.full, Self.failed])
  }

  /// A row with zero tokens is a call that spent none, and a row with no usage is a call with no envelope.
  @Test(arguments: [HeadlessUsage(input: 0, output: 0, cacheRead: 0, cacheWrite: 0), nil])
  func zeroTokensAndNoUsageReadBackAsTheyWereWritten(_ usage: HeadlessUsage?) throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let store = try Store(path: "\(dir)/sb.db")
    _ = try store.append(headlessCall: HeadlessCall(t: 1_000, kind: "planUpdate", usage: usage))

    let calls = try store.headlessCalls()

    #expect(calls.map(\.usage) == [usage])
  }

  @Test func aNewStoreHasNoHeadlessCalls() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let store = try Store(path: "\(dir)/sb.db")

    #expect(try store.headlessCalls().isEmpty)
  }

  /// The ids are 1, 2, and 3, far below every `t`, so a filter on the id instead of the time returns all three.
  @Test func sinceReturnsOnlyTheCallsAtOrAfterThatTimeOldestFirst() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let store = try Store(path: "\(dir)/sb.db")
    for t: Int64 in [1_000, 2_000, 3_000] { _ = try store.append(headlessCall: HeadlessCall(t: t, kind: "triage")) }

    let calls = try store.headlessCalls(since: 2_000)

    #expect(calls.map(\.t) == [2_000, 3_000])
  }

  @Test func deletingTheSessionKeepsItsCalls() throws {
    let dir = try tempFolder()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let store = try Store(path: "\(dir)/sb.db")
    let s = Session(id: "s1", name: "one", cwd: "/tmp/a", branch: "main", claudeSessionId: "u1", created: 5)
    try store.save(s)
    _ = try store.append(headlessCall: Self.full)
    _ = try store.append(headlessCall: HeadlessCall(t: 1_500, kind: "mergeBrief", session: "s1", model: "haiku"))

    try store.delete(session: SessionRemoval(id: s.id, name: s.name))

    #expect(try store.headlessCalls().map(\.kind) == ["triage", "mergeBrief"])
  }
}

/// Milliseconds since the epoch of an ISO 8601 time.
private func epochMs(_ iso: String) -> Int64 {
  Int64(ISO8601DateFormatter().date(from: iso)!.timeIntervalSince1970 * 1000)
}

private func usage(_ input: Int, _ output: Int, _ cacheRead: Int, _ cacheWrite: Int) -> HeadlessUsage {
  HeadlessUsage(input: input, output: output, cacheRead: cacheRead, cacheWrite: cacheWrite)
}

/// `HeadlessUsageReport.build`: the calls summed by local day and kind.
@Suite struct HeadlessUsageReportTests {
  /// Two days and two kinds, written later day first and `triage` before `quickAsk`, so the report must sort them.
  static let calls = [
    HeadlessCall(
      t: epochMs("2026-11-18T15:00:00Z"), kind: "triage", session: "s1", model: "haiku", usage: usage(1, 2, 3, 4)),
    HeadlessCall(t: epochMs("2026-11-18T16:00:00Z"), kind: "quickAsk", model: "sonnet", usage: usage(100, 20, 300, 40)),
    HeadlessCall(
      t: epochMs("2026-11-17T15:00:00Z"), kind: "triage", session: "s1", model: "sonnet", usage: usage(1, 1, 1, 1)),
    HeadlessCall(
      t: epochMs("2026-11-17T16:00:00Z"), kind: "triage", session: "s2", model: "haiku", usage: usage(10, 10, 10, 10)),
    HeadlessCall(
      t: epochMs("2026-11-17T17:00:00Z"), kind: "triage", session: "s2", model: nil, usage: usage(5, 0, 0, 0)),
    HeadlessCall(
      t: epochMs("2026-11-17T18:00:00Z"), kind: "triage", session: "s1", model: "haiku", usage: usage(2, 2, 2, 2)),
    HeadlessCall(t: epochMs("2026-11-17T19:00:00Z"), kind: "triage", session: "s1", error: "timed out after 60 s"),
    HeadlessCall(
      t: epochMs("2026-11-17T20:00:00Z"), kind: "quickAsk", error: "claude exited with status 1: ask failed"),
  ]

  func report() -> HeadlessUsageReport { HeadlessUsageReport.build(Self.calls, since: nil, timeZone: utc) }

  func row(_ day: String, _ kind: String) throws -> HeadlessUsageReport.Row {
    try #require(report().rows.first { $0.day == day && $0.kind == kind })
  }

  @Test func rowsAreOnePerDayAndKindSortedByDayThenKind() {
    let rows = report().rows

    #expect(
      rows.map { "\($0.day) \($0.kind)" } == [
        "2026-11-17 quickAsk", "2026-11-17 triage", "2026-11-18 quickAsk", "2026-11-18 triage",
      ])
  }

  @Test func callsCountEveryRowOfTheDayAndKind() throws {
    #expect(try row("2026-11-17", "triage").calls == 5)
    #expect(try row("2026-11-18", "triage").calls == 1)
  }

  @Test func errorsCountTheRowsWithAnError() throws {
    #expect(try row("2026-11-17", "triage").errors == 1)
    #expect(try row("2026-11-18", "triage").errors == 0)
  }

  /// A failed call with no usage adds nothing to the sums.
  @Test func usageSumsTheTokensAndCountsNoUsageAsZero() throws {
    #expect(try row("2026-11-17", "triage").usage == usage(18, 13, 13, 13))
  }

  @Test func aDayAndKindWithOnlyAFailedCallHasZeroTokens() throws {
    let r = try row("2026-11-17", "quickAsk")

    #expect(r.calls == 1)
    #expect(r.errors == 1)
    #expect(r.usage == usage(0, 0, 0, 0))
  }

  @Test func modelsAreDistinctSortedAndLeaveOutNil() throws {
    #expect(try row("2026-11-17", "triage").models == ["haiku", "sonnet"])
  }

  @Test func aDayAndKindWithNoModelListsNone() throws {
    #expect(try row("2026-11-17", "quickAsk").models == [])
  }

  @Test func noCallsGiveNoRows() {
    #expect(HeadlessUsageReport.build([], since: nil, timeZone: utc).rows.isEmpty)
  }

  /// 03:00 UTC on 2026-11-18 is 19:00 on 2026-11-17 in Los Angeles. A report that ignored the time zone would give
  /// the same day in both.
  @Test func theDayIsTheDateInTheTimeZone() {
    let calls = [HeadlessCall(t: epochMs("2026-11-18T03:00:00Z"), kind: "triage", usage: usage(1, 1, 1, 1))]

    let inUTC = HeadlessUsageReport.build(calls, since: nil, timeZone: utc).rows.map(\.day)
    let inLosAngeles = HeadlessUsageReport.build(calls, since: nil, timeZone: losAngeles).rows.map(\.day)

    #expect(inUTC == ["2026-11-18"])
    #expect(inLosAngeles == ["2026-11-17"])
  }

  /// 07:30 and 08:30 UTC fall on one day in UTC, but on either side of midnight in Los Angeles, which is 8 hours
  /// behind UTC in November.
  /// The counts are 64-bit, so a total past 2^31 prints whole.
  @Test func theTablePrintsCountsPastThirtyTwoBits() {
    let big = HeadlessUsage(input: 1, output: 2, cacheRead: 2_147_483_648, cacheWrite: 3)
    let report = HeadlessUsageReport.build(
      [HeadlessCall(t: epochMs("2026-11-18T12:00:00Z"), kind: "triage", model: "haiku", usage: big)], since: nil,
      timeZone: utc)

    let lines = report.table

    #expect(lines.count == 2)
    #expect(lines[1].contains(" 2147483648"), "\(lines[1])")
    #expect(lines[1].hasPrefix("2026-11-18  triage      "))
    #expect(lines[1].hasSuffix("  haiku"))
  }

  @Test func callsOnEitherSideOfLocalMidnightGoOnTwoDays() {
    let calls = [
      HeadlessCall(t: epochMs("2026-11-18T07:30:00Z"), kind: "triage", usage: usage(1, 0, 0, 0)),
      HeadlessCall(t: epochMs("2026-11-18T08:30:00Z"), kind: "triage", usage: usage(2, 0, 0, 0)),
    ]

    let rows = HeadlessUsageReport.build(calls, since: nil, timeZone: losAngeles).rows

    #expect(rows.map(\.day) == ["2026-11-17", "2026-11-18"])
    #expect(rows.map(\.usage.input) == [1, 2])
  }
}
