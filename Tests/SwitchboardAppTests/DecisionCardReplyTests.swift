import Foundation
import Testing

@testable import SwitchboardApp
@testable import SwitchboardCore

private let shortReply = "The flaky test is unrelated. Do you want me to rerun CI?"
private let longReply = String(repeating: "a", count: Triage.wholeReplyCharacters + 1)
private let decision = PendingDecision(
  number: 1, header: "Name", question: "Hub or Switchboard?",
  options: [PendingDecision.Option(label: "Hub"), PendingDecision.Option(label: "Switchboard", recommended: true)])

/// The callout that sbd's `addReplyAsk` puts first on a rule item whose reply asks something.
private let askCallout = Callout(kind: .decision, title: Triage.replyAskPrefix + "Do you want me to rerun CI?")

private func item(
  _ source: TriageSource, summary: String = "What the model said", callouts: [Callout] = [],
  decisions: [PendingDecision] = []
) -> TriageItem {
  TriageItem(
    title: "Fix Depot CI on #136843", kind: .info, summary: summary, callouts: callouts, decisions: decisions,
    source: source)
}

private func session(lastReply: String?) -> SessionSummary {
  var s = needsItem("s1")
  s.lastReply = lastReply
  return s
}

/// What the Summary shows of the reply when the transcript read gave `reply`, or nothing was read.
private func summaryReply(
  _ item: TriageItem, lastReply: String?, reply: String? = nil, listOpen: Bool = false
) -> DecisionCard.SummaryReply {
  DecisionCard.summaryReply(
    item: item, session: session(lastReply: lastReply), reply: reply ?? lastReply, listOpen: listOpen)
}

// MARK: Each ReplyPresentation (Decision 9)

@Suite struct DecisionCardSummaryReply {
  @Test(arguments: [TriageSource.summary, .fallback])
  func aShortReplyReplacesTheModelsSummary(_ source: TriageSource) {
    #expect(summaryReply(item(source), lastReply: shortReply) == .replacesSummary(shortReply))
  }

  @Test func aShortReplyThatARuleItemAsksAboutShowsUnderTheRulesSummary() {
    let rule = item(.rule, callouts: [askCallout])

    #expect(summaryReply(rule, lastReply: shortReply) == .expanded(shortReply))
  }

  @Test(arguments: [TriageSource.summary, .fallback])
  func aLongReplyShowsBehindAButton(_ source: TriageSource) {
    #expect(summaryReply(item(source), lastReply: longReply) == .collapsed(longReply))
  }

  @Test func aLongReplyThatARuleItemAsksAboutShowsBehindAButton() {
    let rule = item(.rule, callouts: [askCallout])

    #expect(summaryReply(rule, lastReply: longReply) == .collapsed(longReply))
  }

  /// The session wrote its card on purpose, so a short reply never replaces it.
  @Test func aCardThatTheSessionWroteKeepsItsSummaryAndOffersTheReply() {
    #expect(summaryReply(item(.session), lastReply: shortReply) == .collapsed(shortReply))
  }

  @Test func anItemWithDecisionsOffersTheReplyBehindAButton() {
    let decided = item(.summary, decisions: [decision])

    #expect(summaryReply(decided, lastReply: shortReply) == .collapsed(shortReply))
  }

  @Test func anOpenDecisionListOffersTheReplyBehindAButton() {
    #expect(summaryReply(item(.summary), lastReply: shortReply, listOpen: true) == .collapsed(shortReply))
  }

  @Test(arguments: [TriageSource.card, .report])
  func aCardOrAReportShowsNoReply(_ source: TriageSource) {
    #expect(summaryReply(item(source), lastReply: shortReply) == DecisionCard.SummaryReply.none)
  }

  /// The reply stays in Details.
  @Test func aRuleItemWhoseReplyAsksNothingShowsNoReply() {
    #expect(summaryReply(item(.rule), lastReply: shortReply) == DecisionCard.SummaryReply.none)
  }

  @Test(arguments: [nil, "", "  \n\t "] as [String?])
  func anEmptyOrMissingReplyShowsNothing(_ lastReply: String?) {
    #expect(summaryReply(item(.summary), lastReply: lastReply) == DecisionCard.SummaryReply.none)
  }
}

// MARK: The Summary and Details read one reply (Risk 6)

@MainActor
@Suite struct DecisionCardReplyParity {
  /// sbd's callout and the app's choice both read the hook's text, so the transcript's length never changes it.
  @Test func theHookTextDecidesShortEvenWhenTheTranscriptTextIsLong() {
    let hook = String(repeating: "h", count: Triage.wholeReplyCharacters)
    let transcript = String(repeating: "t", count: Triage.wholeReplyCharacters + 1)

    #expect(summaryReply(item(.summary), lastReply: hook, reply: transcript) == .replacesSummary(transcript))
  }

  @Test func theHookTextDecidesLongEvenWhenTheTranscriptTextIsShort() {
    let hook = String(repeating: "h", count: Triage.wholeReplyCharacters + 1)
    let transcript = String(repeating: "t", count: Triage.wholeReplyCharacters)

    #expect(summaryReply(item(.summary), lastReply: hook, reply: transcript) == .collapsed(transcript))
  }

  @Test(arguments: [(Triage.wholeReplyLines, true), (Triage.wholeReplyLines + 1, false)])
  func theHookTextsLineCountDecidesShort(_ lines: Int, _ short: Bool) {
    let hook = (1...lines).map { "line \($0)" }.joined(separator: "\n")
    let transcript = (1...(short ? lines + 5 : 2)).map { "step \($0)" }.joined(separator: "\n")

    let expected: DecisionCard.SummaryReply = short ? .replacesSummary(transcript) : .collapsed(transcript)
    #expect(summaryReply(item(.summary), lastReply: hook, reply: transcript) == expected)
  }

  @Test func anEmptyHookTextShowsNoReplyEvenWithTranscriptText() {
    #expect(summaryReply(item(.summary), lastReply: "  \n", reply: shortReply) == DecisionCard.SummaryReply.none)
  }

  @Test func withoutATranscriptReadTheSummaryShowsTheHookText() {
    let shown = DecisionCard.summaryReply(
      item: item(.summary), session: session(lastReply: shortReply), reply: nil, listOpen: false)

    #expect(shown == .replacesSummary(shortReply))
  }

  /// A read for an earlier reply must not put old text in the Summary or in Details.
  @Test func theSummaryAndDetailsShowTheNewReplyWhenTheReadIsForAnEarlierOne() {
    let model = offlineModel()
    model.replies["s1"] = (hook: "Ship it?", text: "Done. Ship it?")
    let current = session(lastReply: "Fix it?!")

    let reply = model.reply(for: current)
    let summary = DecisionCard.summaryReply(item: item(.summary), session: current, reply: reply, listOpen: false)

    #expect(summary == .replacesSummary("Fix it?!"))
    #expect(CardDetails.lastReply(context: nil, reply: reply) == "Fix it?!")
  }

  @Test func theSummaryAndDetailsShowTheTranscriptTextOfTheCurrentReply() {
    let model = offlineModel()
    model.replies["s1"] = (hook: "Ship it?", text: "Done. Ship it?")
    let current = session(lastReply: "Ship it?")

    let reply = model.reply(for: current)
    let summary = DecisionCard.summaryReply(item: item(.summary), session: current, reply: reply, listOpen: false)

    #expect(summary == .replacesSummary("Done. Ship it?"))
    #expect(CardDetails.lastReply(context: nil, reply: reply) == "Done. Ship it?")
  }
}

// MARK: "No summary yet" under a reply that replaces the summary

@Suite struct DecisionCardMissingSummaryReply {
  private let empty = TriageItem(title: "Read its last reply", kind: .info, summary: "", source: .fallback)

  /// The Summary shows the reply, so the Action must not say that there is no summary.
  @Test func aReplyThatReplacesTheSummaryHidesTheMissingSummaryLine() {
    #expect(!DecisionCard.showsMissingSummary(empty, reply: .replacesSummary(shortReply)))
  }

  @Test(arguments: [DecisionCard.SummaryReply.none, .collapsed(longReply)])
  func aReplyThatDoesNotReplaceTheSummaryKeepsTheLine(_ reply: DecisionCard.SummaryReply) {
    #expect(DecisionCard.showsMissingSummary(empty, reply: reply))
  }
}
